#ifndef GPUMux_h
#define GPUMux_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool hasMux;
    char activeGPU[32];       // "IGPU" or "GFX0" or "Unknown"
    bool dgpuPowered;
    int32_t muxPolicy;        // 0, 1, 2
    int32_t igpuUtilPct;
    int32_t igpuUnit0UtilPct;
    int64_t igpuUsedMemBytes;
    int32_t dgpuTempC;
    int32_t dgpuUtilPct;
    int32_t dgpuCoreClockMHz;
    int64_t dgpuUsedVRAMBytes;
    int64_t dgpuFreeVRAMBytes;
} GPUHardwareStatus;

typedef struct {
    int32_t pid;
    char name[128];
    bool onDiscrete;
    bool onIntegrated;
    bool hasDiscreteOpenGLLock;
    bool hasDiscreteFramebuffer;
    int32_t discreteClientCount;
    int32_t integratedClientCount;
} GPUProcessEntry;

// Read current hardware mux & discrete GPU stats from IOKit
GPUHardwareStatus gpu_read_hardware_status(void);

// Collect processes currently holding IOKit GPU user clients.
// Returns count written (up to max_entries).
int gpu_collect_processes(GPUProcessEntry *out_entries, int max_entries);

// Attempt live mux switch via AppleGraphicsControl user client:
// mode: 0 = Integrated Only, 1 = Discrete Only, 2 = Dynamic Switching
// Returns 0 on success, non-zero IOKit kern_return_t otherwise.
int gpu_mux_switch_live(int mode);

#ifdef __cplusplus
}
#endif

#endif /* GPUMux_h */
