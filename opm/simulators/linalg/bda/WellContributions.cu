/*
  Copyright 2020 Equinor ASA

  This file is part of the Open Porous Media project (OPM).

  OPM is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  OPM is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with OPM.  If not, see <http://www.gnu.org/licenses/>.
*/


#include <cstdlib>
#include <cstring>
#include <config.h> // CMake

#ifdef __NVCC__
#include "opm/simulators/linalg/bda/cuda_header.hpp"
#include <cuda_runtime.h>
#endif

#include <opm/common/OpmLog/OpmLog.hpp>
#include <opm/common/ErrorMacros.hpp>
#include "opm/simulators/linalg/bda/WellContributions.hpp"

namespace Opm
{

    // apply WellContributions using y -= C^T * (D^-1 * (B * x))
    __global__ void apply_well_contributions(
        const double * __restrict__ Cnnzs,
        const double * __restrict__ Dnnzs,
        const double * __restrict__ Bnnzs,
        const int * __restrict__ Ccols,
        const int * __restrict__ Bcols,
        const double * __restrict__ x,
        double * __restrict__ y,
        const int dim,
        const int dim_wells,
        const unsigned int * __restrict__ val_pointers
        )
    {
        const int idx_b = blockIdx.x;
        const int idx_t = threadIdx.x;
        const unsigned int val_size = val_pointers[idx_b+1] - val_pointers[idx_b];

        const int vals_per_block = dim * dim_wells;        // 12
        const int num_active_threads = (32/vals_per_block)*vals_per_block; // 24
        const int num_blocks_per_warp = 32/vals_per_block; // 2
        const int lane = idx_t % 32;
        const int c = lane % dim;                           // col in block
        const int r = (lane / dim) % dim_wells;             // row in block

        extern __shared__ double smem[];
        double * __restrict__ z1 = smem;
        double * __restrict__ z2 = z1 + dim_wells;

        if(idx_t < dim_wells){
            z1[idx_t] = 0.0;
        }

        __syncthreads();

        // z1 = B * x
        if(idx_t < num_active_threads){
            // multiply all blocks with x
            double temp = 0.0;
            int b = idx_t / vals_per_block + val_pointers[idx_b];       // block id, val_size indicates number of blocks
            while(b < val_size + val_pointers[idx_b]){
                int colIdx = Bcols[b];
                temp += Bnnzs[b * dim * dim_wells + r * dim + c] * x[colIdx * dim + c];
                b += num_blocks_per_warp;
            }

            // merge all blocks into 1 dim*dim_wells block
            // since NORNE has only 2 parallel blocks, do not use a loop
            temp += __shfl_down_sync(0x00ffffff, temp, dim * dim_wells);

            b = idx_t / vals_per_block + val_pointers[idx_b];

            // merge all (dim) columns of 1 block, results in a single 1*dim_wells vector, which is used to multiply with invD
            if(idx_t < vals_per_block){
                // should be a loop as well, now only works for dim == 3
                if(c == 0 || c == 2){temp += __shfl_down_sync(0x00000B6D, temp, 2);}  // add col 2 to col 0
                if(c == 0 || c == 1){temp += __shfl_down_sync(0x000006DB, temp, 1);}  // add col 1 to col 0
            }

            // write 1*dim_wells vector to gmem, could be replaced with shfl broadcast to remove z1 altogether
            if(c == 0 && idx_t < vals_per_block){
                z1[r] = temp;
            }
        }

        __syncthreads();

        // z2 = D^-1 * B * x = D^-1 * z1
        if(idx_t < dim_wells){
            double temp = 0.0;
            for(int c = 0; c < dim_wells; ++c){
                temp += Dnnzs[idx_b * dim_wells * dim_wells + idx_t * dim_wells + c] * z1[c];
            }
            z2[idx_t] = temp;
        }

        __syncthreads();

        // y -= C^T * D^-1 * B * x
        // use dim * val_size threads, each block is assigned 'dim' threads
        if(idx_t < dim * val_size){
            double temp = 0.0;
            int b = idx_t / dim + val_pointers[idx_b];
            int cc = idx_t % dim;
            int colIdx = Ccols[b];
            for(unsigned int c = 0; c < dim_wells; ++c){
                temp += Cnnzs[b * dim * dim_wells + c * dim + cc] * z2[c];
            }
            y[colIdx * dim + cc] -= temp;
        }

    }


    void WellContributions::alloc(){
        cudaMalloc((void**)&d_Cnnzs, sizeof(double) * num_blocks * dim * dim_wells);
        cudaMalloc((void**)&d_Dnnzs, sizeof(double) * num_wells * dim_wells * dim_wells);
        cudaMalloc((void**)&d_Bnnzs, sizeof(double) * num_blocks * dim * dim_wells);
        cudaMalloc((void**)&d_Ccols, sizeof(int) * num_blocks);
        cudaMalloc((void**)&d_Bcols, sizeof(int) * num_blocks);
        val_pointers = new unsigned int[num_wells + 1];
        cudaMalloc((void**)&d_val_pointers, sizeof(int) * (num_wells + 1));
        cudaCheckLastError("apply_gpu malloc failed");
        allocated = true;
    }

    WellContributions::~WellContributions()
    {
        cudaFree(d_Cnnzs);
        cudaFree(d_Dnnzs);
        cudaFree(d_Bnnzs);
        cudaFree(d_Ccols);
        cudaFree(d_Bcols);
        delete[] val_pointers;
        cudaFree(d_val_pointers);
    }


    // Apply the WellContributions, similar to StandardWell::apply()
    // y -= (C^T *(D^-1*(   B*x)))
    void WellContributions::apply(double *d_x, double *d_y)
    {
        int smem_size = 2 * sizeof(double) * dim_wells;
        apply_well_contributions<<<num_wells, 32, smem_size, stream>>>(d_Cnnzs, d_Dnnzs, d_Bnnzs, d_Ccols, d_Bcols, d_x, d_y, dim, dim_wells, d_val_pointers);
    }


    void WellContributions::addMatrix(MatrixType type, int *colIndices, double *values, unsigned int val_size)
    {
        if (!allocated) {
            OPM_THROW(std::logic_error,"Error cannot add wellcontribution before allocating memory in WellContributions");
        }

        switch (type) {
        case MatrixType::C:
            cudaMemcpy(d_Cnnzs + num_blocks_so_far * dim * dim_wells, values, sizeof(double) * val_size * dim * dim_wells, cudaMemcpyHostToDevice);
            cudaMemcpy(d_Ccols + num_blocks_so_far, colIndices, sizeof(int) * val_size, cudaMemcpyHostToDevice);
            break;
        case MatrixType::D:
            cudaMemcpy(d_Dnnzs + num_wells_so_far * dim_wells * dim_wells, values, sizeof(double) * dim_wells * dim_wells, cudaMemcpyHostToDevice);
            break;
        case MatrixType::B:
            cudaMemcpy(d_Bnnzs + num_blocks_so_far * dim * dim_wells, values, sizeof(double) * val_size * dim * dim_wells, cudaMemcpyHostToDevice);
            cudaMemcpy(d_Bcols + num_blocks_so_far, colIndices, sizeof(int) * val_size, cudaMemcpyHostToDevice);
            val_pointers[num_wells_so_far] = num_blocks_so_far;
            if(num_wells_so_far == num_wells - 1){
                val_pointers[num_wells] = num_blocks;
            }
            cudaMemcpy(d_val_pointers, val_pointers, sizeof(int) * (num_wells+1), cudaMemcpyHostToDevice);
            break;
        default:
            OPM_THROW(std::logic_error,"Error unsupported matrix ID for WellContributions::addMatrix()");
        }
        cudaCheckLastError("WellContributions::addMatrix() failed");
        if (MatrixType::B == type) {
            num_blocks_so_far += val_size;
            num_wells_so_far++;
        }
    }

    void WellContributions::setCudaStream(cudaStream_t stream_)
    {
        this->stream = stream_;
    }

    void WellContributions::setBlockSize(unsigned int dim_, unsigned int dim_wells_)
    {
        dim = dim_;
        dim_wells = dim_wells_;
    }

    void WellContributions::addNumBlocks(unsigned int nnz)
    {
        if (allocated) {
            OPM_THROW(std::logic_error,"Error cannot add more sizes after allocated in WellContributions");
        }
        num_blocks += nnz;
        num_wells++;
    }

} //namespace Opm

