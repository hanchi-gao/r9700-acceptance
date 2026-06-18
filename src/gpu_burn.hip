// src/gpu_burn.hip — minimal FMA compute-stress fallback.
// Used by stress/gpu_hotspot.sh ONLY if cloning/building ROCm/gpu-burn fails.
// Pins one GPU (set by HIP_VISIBLE_DEVICES) at ~100% FMA to drive junction temp.
//
// Build: hipcc --offload-arch=gfx1201 -O3 src/gpu_burn.hip -o build/gpu_burn
// Run:   HIP_VISIBLE_DEVICES=0 ./build/gpu_burn <seconds>
//
// It is intentionally simple: a long fused-multiply-add loop on a large buffer,
// no host<->device transfer in the hot path, so the ALUs stay saturated.

#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <ctime>

#define CK(x) do { hipError_t e=(x); if(e!=hipSuccess){ \
  fprintf(stderr,"HIP error %s at %s:%d\n",hipGetErrorString(e),__FILE__,__LINE__); \
  return 2; } } while(0)

__global__ void fma_burn(float* buf, size_t n, int iters) {
  size_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  float a = buf[i], b = 1.0000001f, c = 0.9999999f;
  #pragma unroll 8
  for (int k = 0; k < iters; ++k) {
    a = a * b + c;
    a = a * c + b;
  }
  buf[i] = a;
}

int main(int argc, char** argv) {
  int seconds = (argc > 1) ? atoi(argv[1]) : 120;
  int dev = 0;
  CK(hipSetDevice(dev));
  hipDeviceProp_t prop; CK(hipGetDeviceProperties(&prop, dev));
  // Size buffer to a healthy fraction of a stream multiprocessor's reach.
  size_t n = (size_t)256 * 1024 * 1024 / sizeof(float); // 256 MB working set
  float* d = nullptr;
  CK(hipMalloc(&d, n * sizeof(float)));
  CK(hipMemset(d, 1, n * sizeof(float)));

  int threads = 256;
  size_t blocks = (n + threads - 1) / threads;
  const int iters = 4096;

  printf("[gpu_burn] device=%s running %ds (working set 256MB)\n", prop.name, seconds);
  fflush(stdout);

  time_t start = time(nullptr);
  unsigned long launches = 0;
  while (time(nullptr) - start < seconds) {
    hipLaunchKernelGGL(fma_burn, dim3(blocks), dim3(threads), 0, 0, d, n, iters);
    CK(hipGetLastError());
    if ((++launches & 0x3F) == 0) { CK(hipDeviceSynchronize()); }
  }
  CK(hipDeviceSynchronize());
  printf("[gpu_burn] done: %lu kernel launches\n", launches);
  CK(hipFree(d));
  return 0;
}
