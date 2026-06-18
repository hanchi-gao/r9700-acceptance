// src/gemm_burn.hip — self-contained rocBLAS GEMM burner.
// GEMM (matrix multiply) is FMA-dense (drives junction temp) AND, by keeping
// many large matrices resident + streaming them, fills VRAM and drives HBM
// bandwidth/memory temp. This replaces the vLLM container for BOTH the hotspot
// and VRAM burn-in stages — no docker, no network needed (rocBLAS ships with
// ROCm). Pin one process per GPU with HIP_VISIBLE_DEVICES.
//
// Build: hipcc --offload-arch=gfx1201 -O3 src/gemm_burn.hip -o build/gemm_burn \
//          -lrocblas
// Run:   HIP_VISIBLE_DEVICES=0 ./build/gemm_burn <seconds> [mem_percent] [N]
//          seconds      : how long to run (default 120)
//          mem_percent  : fraction of FREE VRAM to fill (default 90)
//                         high => VRAM-fill (memory temp); low => compute (junction)
//          N            : square matrix dimension (default 8192)
//
// Exit non-zero on any HIP/rocBLAS error so the caller can judge FAIL.

#include <hip/hip_runtime.h>
#include <rocblas/rocblas.h>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <vector>

#define HK(x) do { hipError_t e=(x); if(e!=hipSuccess){ \
  fprintf(stderr,"[gemm_burn] HIP error %s at %s:%d\n",hipGetErrorString(e),__FILE__,__LINE__); \
  return 2; } } while(0)
#define RK(x) do { rocblas_status s=(x); if(s!=rocblas_status_success){ \
  fprintf(stderr,"[gemm_burn] rocBLAS error %d at %s:%d\n",(int)s,__FILE__,__LINE__); \
  return 3; } } while(0)

__global__ void fillf(float* p, size_t n, float v) {
  size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x;
  if (i < n) p[i] = v;
}

// arg1 = absolute epoch deadline if > 1e9, else seconds-from-now. One shared
// deadline lets all stages stop together; burn-in runs to a deadline, not a
// precise countdown.
static time_t parse_deadline(const char* s) {
  long v = atol(s);
  time_t now = time(nullptr);
  return (v > 1000000000L) ? (time_t)v : now + v;
}

int main(int argc, char** argv) {
  time_t deadline   = (argc > 1) ? parse_deadline(argv[1]) : time(nullptr) + 120;
  int   mem_percent = (argc > 2) ? atoi(argv[2]) : 90;
  int   N           = (argc > 3) ? atoi(argv[3]) : 8192;
  if (mem_percent < 1 || mem_percent > 98) mem_percent = 90;

  int dev = 0;
  HK(hipSetDevice(dev));
  hipDeviceProp_t prop; HK(hipGetDeviceProperties(&prop, dev));
  char bdf[64] = {0}; hipDeviceGetPCIBusId(bdf, sizeof(bdf), dev);

  size_t freeB = 0, totalB = 0;
  HK(hipMemGetInfo(&freeB, &totalB));
  size_t target = (size_t)(freeB * (double)mem_percent / 100.0);

  const size_t elems = (size_t)N * N;
  const size_t matBytes = elems * sizeof(float);
  if (matBytes * 3 > target) {
    fprintf(stderr, "[gemm_burn] N=%d too large for %zu MB target; reduce N\n",
            N, target / (1024*1024));
    return 4;
  }
  // A and B are shared; allocate as many C buffers as fit to fill VRAM.
  size_t nC = (target - 2 * matBytes) / matBytes;
  if (nC < 1) nC = 1;

  float *dA = nullptr, *dB = nullptr;
  HK(hipMalloc(&dA, matBytes));
  HK(hipMalloc(&dB, matBytes));
  // Fill with a normal value (1.0f). A byte-pattern memset yields tiny
  // denormal floats that push FP32 GEMM onto slow paths and starve junction.
  dim3 blk(256), grd((elems + 255) / 256);
  hipLaunchKernelGGL(fillf, grd, blk, 0, 0, dA, elems, 1.0f);
  hipLaunchKernelGGL(fillf, grd, blk, 0, 0, dB, elems, 1.0f);

  std::vector<float*> dC(nC, nullptr);
  for (size_t i = 0; i < nC; ++i) {
    if (hipMalloc(&dC[i], matBytes) != hipSuccess) {  // back off if we overshot
      nC = i; dC.resize(nC); break;
    }
  }
  if (nC < 1) { fprintf(stderr, "[gemm_burn] could not allocate any C buffer\n"); return 4; }
  HK(hipDeviceSynchronize());

  printf("[gemm_burn] device=%s bdf=%s N=%d free=%zuMB target=%zuMB(%d%%) Cbuffers=%zu (~%zuMB resident VRAM)\n",
         prop.name, bdf, N, freeB/(1024*1024), target/(1024*1024), mem_percent,
         nC, (nC + 2) * matBytes / (1024*1024));
  fflush(stdout);

  rocblas_handle handle;
  RK(rocblas_create_handle(&handle));
  const float alpha = 1.0f, beta = 0.0f;

  // Pipeline a batch of GEMMs, then sync, so the timer reflects REAL executed
  // work (rocblas_sgemm is async — without a periodic sync the loop just queues
  // the whole sweep instantly and overshoots the deadline massively). A small
  // batch keeps the GPU saturated while bounding overshoot to well under 1s.
  const size_t BATCH = 4;
  time_t start = time(nullptr);
  unsigned long iters = 0;
  bool stop = false;
  while (!stop) {
    for (size_t i = 0; i < nC && !stop; ++i) {
      RK(rocblas_sgemm(handle, rocblas_operation_none, rocblas_operation_none,
                       N, N, N, &alpha, dA, N, dB, N, &beta, dC[i], N));
      if ((++iters % BATCH) == 0) {
        HK(hipDeviceSynchronize());
        if (time(nullptr) >= deadline) stop = true;
      }
    }
  }
  HK(hipDeviceSynchronize());

  double secs = (double)(time(nullptr) - start);
  double gflops = (2.0 * (double)N * N * N * (double)iters) / (secs > 0 ? secs : 1) / 1e9;
  printf("[gemm_burn] done bdf=%s: %lu GEMMs in %.0fs  ~%.0f GFLOP/s  (VRAM held ~%zuMB)\n",
         bdf, iters, secs, gflops, (nC + 2) * matBytes / (1024*1024));

  rocblas_destroy_handle(handle);
  HK(hipFree(dA)); HK(hipFree(dB));
  for (auto p : dC) (void)hipFree(p);
  return 0;
}
