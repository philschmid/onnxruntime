// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "beam_search_impl.h"
#include "core/providers/cuda/cuda_common.h"
#include "core/providers/cuda/cu_inc/common.cuh"

namespace onnxruntime {
namespace contrib {
namespace cuda {
__global__ void InitKernel(float* beam_scores,
                           int num_beams,
                           int total_elements) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < total_elements) {
    int beam_index = index % num_beams;
    beam_scores[index] = beam_index > 0 ? static_cast<float>(-1e9) : 0.0f;
  }
}

void LaunchInitKernel(
    float* beam_scores,
    int batch_size,
    int num_beams,
    cudaStream_t stream) {
  int total_elements = batch_size * num_beams;
  constexpr int blockSize = 256;
  const int gridSize = (total_elements + blockSize - 1) / blockSize;
  InitKernel<<<gridSize, blockSize, 0, stream>>>(beam_scores, num_beams, total_elements);
}

__global__ void NextTokenKernel(const int64_t* next_token_indices,
                                int32_t* next_indices,
                                int32_t* next_tokens,
                                int vocab_size,
                                int total_elements) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < total_elements) {
    next_indices[index] = next_token_indices[index] / vocab_size;
    next_tokens[index] = next_token_indices[index] % vocab_size;
  }
}

void LaunchNextTokenKernel(const int64_t* next_token_indices,
                           int32_t* next_indices,
                           int32_t* next_tokens,
                           int batch_size,
                           int top_k,
                           int vocab_size,
                           cudaStream_t stream) {
  int total_elements = batch_size * top_k;
  constexpr int blockSize = 256;
  const int gridSize = (total_elements + blockSize - 1) / blockSize;
  NextTokenKernel<<<gridSize, blockSize, 0, stream>>>(next_token_indices, next_indices, next_tokens, vocab_size, total_elements);
}



template <typename T>
__global__ void LogitsProcessKernel(
    T* log_probs,
    const int* vocab_mask,
    const int* prefix_vocab_mask,
    int num_beams,
    int vocab_size,
    int total_elements) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int word_id = index % vocab_size;

  if (index < total_elements) {
    if (vocab_mask != nullptr && vocab_mask[word_id] == 0) {
      log_probs[index] = std::numeric_limits<T>::lowest();
    }

    int batch_id = (index / vocab_size) / num_beams;
    if (prefix_vocab_mask != nullptr && prefix_vocab_mask[batch_id * vocab_size + word_id] == 0) {
      log_probs[index] = std::numeric_limits<T>::lowest();
    }
  }
}

template <typename T>
void LaunchLogitsProcessKernel(
    T* log_probs,
    const int* vocab_mask,
    const int* prefix_vocab_mask,
    int batch_size,
    int num_beams,
    int vocab_size,
    cudaStream_t stream) {
  int total_elements = batch_size * num_beams * vocab_size;
  constexpr int blockSize = 256;
  const int gridSize = (total_elements + blockSize - 1) / blockSize;
  LogitsProcessKernel<T><<<gridSize, blockSize, 0, stream>>>(log_probs, vocab_mask, prefix_vocab_mask, num_beams, vocab_size, total_elements);
}

// Instantiation
template void LaunchLogitsProcessKernel(
    float* log_probs,
    const int* vocab_mask,
    const int* prefix_vocab_mask,
    int batch_size,
    int num_beams,
    int vocab_size,
    cudaStream_t stream);

template void LaunchLogitsProcessKernel(
    half* log_probs,
    const int* vocab_mask,
    const int* prefix_vocab_mask,
    int batch_size,
    int num_beams,
    int vocab_size,
    cudaStream_t stream);

__global__ void AddProbsKernel(float* log_probs,
                               float* cum_log_probs,
                               const int vocab_size,
                               const int total_elements) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  int batch_beam_index = index / vocab_size;

  if (index < total_elements)
    log_probs[index] += cum_log_probs[batch_beam_index];
}

template <typename T>
void LaunchAddProbsKernel(T* log_probs,
                          T* cum_log_probs,
                          const int batch_size,
                          const int num_beams,
                          const int vocab_size,
                          cudaStream_t stream) {
  int total_elements = batch_size * num_beams * vocab_size;
  constexpr int blockSize = 256;
  const int gridSize = (total_elements + blockSize - 1) / blockSize;
  AddProbsKernel<<<gridSize, blockSize, 0, stream>>>(log_probs, cum_log_probs, vocab_size, total_elements);
}

template void LaunchAddProbsKernel(
    float* log_probs,
    float* cum_log_probs,
    const int batch_size,
    const int num_beams,
    const int vocab_size,
    cudaStream_t stream);

template <typename T>
__global__ void UpdateInputsKernel(const T* old_mask_data,
                                   T* mask_data,
                                   int32_t* next_positions,
                                   int batch_beam_size,
                                   int current_length) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < batch_beam_size * current_length) {
    // Update attention mask.
    int i = index / current_length;
    int j = index % current_length;
    mask_data[index] = (j < current_length - 1) ? old_mask_data[i * (current_length - 1) + j] : static_cast<T>(1);

    // Update sequence length (or next positions).
    if (index < batch_beam_size) {
      next_positions[index]++;
    }
  }
}

void LaunchUpdateKernel(const int32_t* old_mask_data,
                        int32_t* mask_data,
                        int32_t* next_positions,
                        int batch_beam_size,
                        int current_length,
                        cudaStream_t stream) {
  assert(current_length > 0);
  int total_elements = batch_beam_size * current_length;
  constexpr int blockSize = 256;
  const int gridSize = (total_elements + blockSize - 1) / blockSize;
  UpdateInputsKernel<int32_t><<<gridSize, blockSize, 0, stream>>>(old_mask_data, mask_data, next_positions, batch_beam_size, current_length);
}

}  // namespace cuda
}  // namespace contrib
}  // namespace onnxruntime