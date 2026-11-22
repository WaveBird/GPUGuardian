#include "GPUMux.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void copy_cfstring(CFStringRef str, char *dst, size_t dst_len) {
    if (!str || CFGetTypeID(str) != CFStringGetTypeID()) {
        dst[0] = '\0';
        return;
    }
    if (!CFStringGetCString(str, dst, (CFIndex)dst_len, kCFStringEncodingUTF8)) {
        dst[0] = '\0';
    }
}

static bool get_int64_from_dict(CFDictionaryRef dict, CFStringRef key, int64_t *out_val) {
    if (!dict || CFGetTypeID(dict) != CFDictionaryGetTypeID()) return false;
    CFTypeRef val = CFDictionaryGetValue(dict, key);
    if (!val || CFGetTypeID(val) != CFNumberGetTypeID()) return false;
    return CFNumberGetValue((CFNumberRef)val, kCFNumberSInt64Type, out_val);
}

GPUHardwareStatus gpu_read_hardware_status(void) {
    GPUHardwareStatus status;
    memset(&status, 0, sizeof(status));
    snprintf(status.activeGPU, sizeof(status.activeGPU), "Unknown");
    status.muxPolicy = -1;
    status.igpuUtilPct = -1;
    status.igpuUnit0UtilPct = -1;
    status.dgpuTempC = -1;
    status.dgpuUtilPct = -1;
    status.dgpuCoreClockMHz = -1;

    // 1. Read AppleMuxControl
    io_service_t mux = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleMuxControl"));
    if (mux != IO_OBJECT_NULL) {
        status.hasMux = true;

        CFTypeRef activeRef = IORegistryEntryCreateCFProperty(mux, CFSTR("ActiveGPU"), kCFAllocatorDefault, 0);
        if (activeRef) {
            copy_cfstring((CFStringRef)activeRef, status.activeGPU, sizeof(status.activeGPU));
            CFRelease(activeRef);
        }

        CFTypeRef poweredRef = IORegistryEntryCreateCFProperty(mux, CFSTR("GPUPowered"), kCFAllocatorDefault, 0);
        if (poweredRef && CFGetTypeID(poweredRef) == CFDataGetTypeID()) {
            const UInt8 *bytes = CFDataGetBytePtr((CFDataRef)poweredRef);
            CFIndex len = CFDataGetLength((CFDataRef)poweredRef);
            uint32_t v = 0;
            for (CFIndex i = 0; i < len && i < 4; i++) {
                v |= ((uint32_t)bytes[i]) << (i * 8);
            }
            status.dgpuPowered = (v != 0);
        }
        if (poweredRef) CFRelease(poweredRef);

        CFTypeRef policyRef = IORegistryEntryCreateCFProperty(mux, CFSTR("policy"), kCFAllocatorDefault, 0);
        if (policyRef && CFGetTypeID(policyRef) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)policyRef, kCFNumberSInt32Type, &status.muxPolicy);
        }
        if (policyRef) CFRelease(policyRef);

        IOObjectRelease(mux);
    }

    // 2. Read both iGPU (Intel) and dGPU (AMD/NVDA) stats from IOGraphicsAccelerator2
    io_iterator_t iter = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOGraphicsAccelerator2"), &iter) == KERN_SUCCESS) {
        io_service_t accel;
        while ((accel = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
            io_name_t className;
            IOObjectGetClass(accel, className);
            bool isDiscrete = (strstr(className, "AMD") != NULL ||
                               strstr(className, "ATI") != NULL ||
                               strstr(className, "NVDA") != NULL ||
                               strstr(className, "GeForce") != NULL);
            bool isIntegrated = (strstr(className, "Intel") != NULL);

            if (isDiscrete) {
                CFTypeRef statsRef = IORegistryEntryCreateCFProperty(accel, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
                if (statsRef && CFGetTypeID(statsRef) == CFDictionaryGetTypeID()) {
                    CFDictionaryRef dict = (CFDictionaryRef)statsRef;
                    int64_t val = 0;
                    if (get_int64_from_dict(dict, CFSTR("Temperature(C)"), &val)) status.dgpuTempC = (int32_t)val;
                    if (get_int64_from_dict(dict, CFSTR("GPU Activity(%)"), &val)) {
                        status.dgpuUtilPct = (int32_t)val;
                    } else if (get_int64_from_dict(dict, CFSTR("Device Utilization %"), &val)) {
                        status.dgpuUtilPct = (int32_t)val;
                    }
                    if (get_int64_from_dict(dict, CFSTR("Core Clock(MHz)"), &val)) status.dgpuCoreClockMHz = (int32_t)val;
                    if (get_int64_from_dict(dict, CFSTR("inUseVidMemoryBytes"), &val)) status.dgpuUsedVRAMBytes = val;
                    if (get_int64_from_dict(dict, CFSTR("vramFreeBytes"), &val)) status.dgpuFreeVRAMBytes = val;
                }
                if (statsRef) CFRelease(statsRef);
            } else if (isIntegrated) {
                CFTypeRef statsRef = IORegistryEntryCreateCFProperty(accel, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
                if (statsRef && CFGetTypeID(statsRef) == CFDictionaryGetTypeID()) {
                    CFDictionaryRef dict = (CFDictionaryRef)statsRef;
                    int64_t val = 0;
                    if (get_int64_from_dict(dict, CFSTR("Device Utilization %"), &val)) {
                        status.igpuUtilPct = (int32_t)val;
                    }
                    if (get_int64_from_dict(dict, CFSTR("Device Unit 0 Utilization %"), &val)) {
                        status.igpuUnit0UtilPct = (int32_t)val;
                    }
                    if (get_int64_from_dict(dict, CFSTR("inUseSysMemoryBytes"), &val)) {
                        status.igpuUsedMemBytes = val;
                    }
                }
                if (statsRef) CFRelease(statsRef);
            }
            IOObjectRelease(accel);
        }
        IOObjectRelease(iter);
    }

    return status;
}

static void record_process_client(
    GPUProcessEntry *entries,
    int *count,
    int max_entries,
    int32_t pid,
    const char *name,
    bool isDiscrete,
    bool isOpenGLLock,
    bool isFramebuffer
) {
    if (pid <= 0) return;
    int idx = -1;
    for (int i = 0; i < *count; i++) {
        if (entries[i].pid == pid) {
            idx = i;
            break;
        }
    }
    if (idx < 0) {
        if (*count >= max_entries) return;
        idx = (*count)++;
        memset(&entries[idx], 0, sizeof(GPUProcessEntry));
        entries[idx].pid = pid;
        snprintf(entries[idx].name, sizeof(entries[idx].name), "%s", name);
    }
    if (isDiscrete) {
        entries[idx].onDiscrete = true;
        entries[idx].discreteClientCount++;
        if (isOpenGLLock) entries[idx].hasDiscreteOpenGLLock = true;
        if (isFramebuffer) entries[idx].hasDiscreteFramebuffer = true;
    } else {
        entries[idx].onIntegrated = true;
        entries[idx].integratedClientCount++;
    }
}

static bool parse_creator_string(const char *str, int32_t *out_pid, char *out_name, size_t out_name_len) {
    // Expected format: "pid 38267, Sublime Text"
    if (!str) return false;
    const char *p = strstr(str, "pid ");
    if (!p) return false;
    p += 4;
    char *endptr = NULL;
    long pid = strtol(p, &endptr, 10);
    if (pid <= 0 || !endptr) return false;
    *out_pid = (int32_t)pid;
    const char *comma = strchr(endptr, ',');
    if (comma) {
        comma++;
        while (*comma == ' ') comma++;
        snprintf(out_name, out_name_len, "%s", comma);
    } else {
        snprintf(out_name, out_name_len, "pid %ld", pid);
    }
    return true;
}

static void scan_children_clients(
    io_registry_entry_t parent,
    bool isDiscrete,
    GPUProcessEntry *entries,
    int *count,
    int max_entries,
    int depth
) {
    if (depth > 4) return;
    io_iterator_t child_iter = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildIterator(parent, kIOServicePlane, &child_iter) != KERN_SUCCESS) {
        return;
    }
    io_registry_entry_t child;
    while ((child = IOIteratorNext(child_iter)) != IO_OBJECT_NULL) {
        io_name_t className;
        IOObjectGetClass(child, className);

        CFTypeRef creatorRef = IORegistryEntryCreateCFProperty(child, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0);
        if (creatorRef) {
            char buf[256];
            copy_cfstring((CFStringRef)creatorRef, buf, sizeof(buf));
            CFRelease(creatorRef);
            int32_t pid = 0;
            char procName[128];
            if (parse_creator_string(buf, &pid, procName, sizeof(procName))) {
                bool isGL = (strstr(className, "GLContext") != NULL);
                bool isFB = (strstr(className, "Framebuffer") != NULL);
                record_process_client(entries, count, max_entries, pid, procName, isDiscrete, isGL, isFB);
            }
        }

        scan_children_clients(child, isDiscrete, entries, count, max_entries, depth + 1);
        IOObjectRelease(child);
    }
    IOObjectRelease(child_iter);
}

int gpu_collect_processes(GPUProcessEntry *out_entries, int max_entries) {
    if (!out_entries || max_entries <= 0) return 0;
    int count = 0;

    // 1. Scan IOGraphicsAccelerator2 (both Intel iGPU and AMD/NVDA dGPU)
    io_iterator_t iter = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOGraphicsAccelerator2"), &iter) == KERN_SUCCESS) {
        io_service_t accel;
        while ((accel = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
            io_name_t className;
            IOObjectGetClass(accel, className);
            bool isDiscrete = (strstr(className, "AMD") != NULL ||
                               strstr(className, "ATI") != NULL ||
                               strstr(className, "NVDA") != NULL ||
                               strstr(className, "GeForce") != NULL);
            scan_children_clients(accel, isDiscrete, out_entries, &count, max_entries, 0);
            IOObjectRelease(accel);
        }
        IOObjectRelease(iter);
    }

    // 2. Scan AMDFramebufferSI / AMDFramebuffer* (framebuffers on discrete GPU)
    io_iterator_t fb_iter = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOFramebuffer"), &fb_iter) == KERN_SUCCESS) {
        io_service_t fb;
        while ((fb = IOIteratorNext(fb_iter)) != IO_OBJECT_NULL) {
            io_name_t className;
            IOObjectGetClass(fb, className);
            if (strstr(className, "AMD") || strstr(className, "ATI")) {
                scan_children_clients(fb, true, out_entries, &count, max_entries, 0);
            }
            IOObjectRelease(fb);
        }
        IOObjectRelease(fb_iter);
    }

    return count;
}

// AppleGraphicsControlClient user client selectors (standard gfxCardStatus / gSwitch mux interface)
enum {
    kGetMuxState = 0,
    kSetMuxState = 1
};

int gpu_mux_switch_live(int mode) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleGraphicsControl"));
    if (service == IO_OBJECT_NULL) {
        return -1;
    }

    io_connect_t connect = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &connect);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || connect == IO_OBJECT_NULL) {
        return (int)kr;
    }

    // Standard AppleGraphicsControl scalar call:
    // selector 1 (SetMuxState): input = [1, feature, value]
    // feature 7 = ForceSwitch / Dynamic, or policy state
    uint64_t scalarI[3] = { 1, 0, 0 };
    if (mode == 0) {
        // Integrated Only: force switch to iGPU (selector 1, arg1=1, arg2=0 -> switch to IGPU; or policy 0)
        scalarI[0] = 1;
        scalarI[1] = 7; // GraphicsSwitch
        scalarI[2] = 0; // 0 = Integrated
    } else if (mode == 1) {
        // Discrete Only
        scalarI[0] = 1;
        scalarI[1] = 7;
        scalarI[2] = 1; // 1 = Discrete
    } else {
        // Dynamic Switching: enable dynamic (policy 2)
        scalarI[0] = 1;
        scalarI[1] = 2; // DynamicSwitching
        scalarI[2] = 1;
    }

    kr = IOConnectCallScalarMethod(connect, kSetMuxState, scalarI, 3, NULL, NULL);
    IOServiceClose(connect);
    return (int)kr;
}
