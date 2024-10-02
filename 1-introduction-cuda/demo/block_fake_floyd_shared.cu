// Copyright 2023 Pierre Talbot

#include "../utility.hpp"
#include <string>

__forceinline__ __device__ int dim2D(int x, int y, int n) {
  return x * n + y;
}

__global__ void floyd_warshall_gpu(int** d, size_t n) {
  for(int kk = 0; kk < n*n; ++kk) { // just to show that shared memory can help... Not useful.
    for(int k = 0; k < n; ++k) {
      for(int i = 0; i < n; ++i) {
        for(int j = threadIdx.x; j < n; j += blockDim.x) {
          if(d[i][j] > d[i][k] + d[k][j]) {
            d[i][j] = d[i][k] + d[k][j];
          }
        }
      }
      __syncthreads();
    }
  }
}

__global__ void floyd_warshall_gpu_shared(int** d, size_t n) {
  // Copy the matrix into the shared memory.
  extern __shared__ int d2[];
  for(int i = 0; i < n; ++i) {
    for(int j = threadIdx.x; j < n; j += blockDim.x) {
      d2[dim2D(i, j, n)] = d[i][j];
    }
  }
  __syncthreads();
  // Compute on the shared memory.
  for(int kk = 0; kk < n*n; ++kk) { // just to show that shared memory can help... Not useful.
    for(int k = 0; k < n; ++k) {
      for(int i = 0; i < n; ++i) {
        for(int j = threadIdx.x; j < n; j += blockDim.x) {
          if(d2[dim2D(i,j,n)] > d2[dim2D(i,k,n)] + d2[dim2D(k,j,n)]) {
            d2[dim2D(i,j,n)] = d2[dim2D(i,k,n)] + d2[dim2D(k,j,n)];
          }
        }
      }
      __syncthreads();
    }
  }
  // Copy the matrix back to the global memory.
  for(int i = 0; i < n; ++i) {
    for(int j = threadIdx.x; j < n; j += blockDim.x) {
      d[i][j] = d2[dim2D(i, j, n)];
    }
  }
}

template <class T>
void floyd_warshall_cpu(std::vector<std::vector<T>>& d) {
  size_t n = d.size();
  for(int kk = 0; kk < n*n; ++kk) { // just to show that shared memory can help... Not useful.
    for(int k = 0; k < n; ++k) {
      for(int i = 0; i < n; ++i) {
        for(int j = 0; j < n; ++j) {
          if(d[i][j] > d[i][k] + d[k][j]) {
            d[i][j] = d[i][k] + d[k][j];
          }
        }
      }
    }
  }
}

int main(int argc, char** argv) {
  if(argc != 3) {
    std::cout << "usage: " << argv[0] << " <matrix size> <threads-per-block>" << std::endl;
    exit(1);
  }
  size_t n = std::stoi(argv[1]);
  size_t threads_per_block = std::stoi(argv[2]);

  // I. Generate a random distance matrix of size N x N.
  std::vector<std::vector<int>> cpu_distances = initialize_distances(n);
  // Note that `std::vector` cannot be used on GPU, hence we transfer it into a simple `int**` array in managed memory.
  int** gpu_distances1 = initialize_gpu_distances(cpu_distances);
  int** gpu_distances2 = initialize_gpu_distances(cpu_distances);

  // II. Running Floyd Warshall on CPU.
  long cpu_ms = benchmark_one_ms([&]{
    floyd_warshall_cpu(cpu_distances);
  });
  std::cout << "CPU: " << cpu_ms << " ms" << std::endl;

  // III. Running Floyd Warshall on GPU (single block of size `threads_per_block`).

  /** Maximal capacity of the shared memory. */
  cudaDeviceProp deviceProp;
  cudaGetDeviceProperties(&deviceProp, 0);
  size_t shared_mem_capacity = deviceProp.sharedMemPerBlock;
  size_t matrix_size = n * n * sizeof(int);
  if(shared_mem_capacity < matrix_size) {
    std::cerr << "matrix too large to be in shared memory." << std::endl;
    exit(1);
  }

  long gpu_ms = benchmark_one_ms([&]{
    floyd_warshall_gpu<<<1, threads_per_block>>>(gpu_distances1, n);
    CUDIE(cudaDeviceSynchronize());
  });
  std::cout << "GPU: " << gpu_ms << " ms" << std::endl;

  long gpu_shared_ms = benchmark_one_ms([&]{
    floyd_warshall_gpu_shared<<<1, threads_per_block, matrix_size>>>(gpu_distances2, n);
    CUDIE(cudaDeviceSynchronize());
  });
  std::cout << "GPU: " << gpu_shared_ms << " ms" << std::endl;

  // IV. Verifying both give the same result and deallocating.
  check_equal_matrix(cpu_distances, gpu_distances2);
  deallocate_gpu_distances(gpu_distances1, n);
  deallocate_gpu_distances(gpu_distances2, n);
  return 0;
}
