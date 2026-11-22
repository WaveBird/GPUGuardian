import Cocoa
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Returns true only while a process with this PID still exists.
/// Used to drop stale IOKit user-client records left behind by exited processes.
@inline(__always)
func gpu_pid_is_alive(_ pid: Int32) -> Bool {
    if pid <= 1 { return false }
    return kill(pid, 0) == 0 || errno == EPERM
}

enum GPUMode: Int32 {
    case integratedOnly = 0
    case discreteOnly = 1
    case dynamicSwitching = 2

    var title: String {
        switch self {
        case .integratedOnly: return "仅核显 (Integrated)"
        case .discreteOnly: return "仅独显 (Discrete)"
        case .dynamicSwitching: return "自动切换 (Dynamic)"
        }
    }
}

struct GPUProcessInfo {
    let pid: Int32
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage
    let onDiscrete: Bool
    let onIntegrated: Bool
    let hasDiscreteOpenGLLock: Bool
    let hasDiscreteFramebuffer: Bool
    let discreteClientCount: Int32
    let integratedClientCount: Int32
    let isProtected: Bool
    let dgpuPoweredNow: Bool
    /// CPU usage as a percentage of all logical cores; nil when unavailable.
    let cpuPercent: Double?
    /// Resident memory in bytes; nil when unavailable (e.g. root-owned processes).
    let memoryBytes: UInt64?

    var cpuText: String {
        guard let p = cpuPercent else { return "—" }
        return String(format: "%.1f%%", p)
    }

    var memoryText: String {
        guard let b = memoryBytes else { return "—" }
        if b >= 1024 * 1024 * 1024 {
            return String(format: "%.1f GB", Double(b) / (1024.0 * 1024.0 * 1024.0))
        }
        return String(format: "%.0f MB", Double(b) / (1024.0 * 1024.0))
    }

    var isActivelyUsingDiscrete: Bool {
        if hasDiscreteOpenGLLock || hasDiscreteFramebuffer {
            return true
        }
        return onDiscrete && dgpuPoweredNow
    }

    var gpuPriority: Int {
        if hasDiscreteOpenGLLock { return 0 }
        if hasDiscreteFramebuffer { return 1 }
        if isActivelyUsingDiscrete { return 2 }
        return 3
    }

    var gpuBadgeText: String {
        if hasDiscreteOpenGLLock {
            return "🔥 独显锁 (OpenGL)"
        } else if hasDiscreteFramebuffer {
            return "🔥 独显 (帧缓冲)"
        } else if isActivelyUsingDiscrete && onIntegrated {
            return "⚡ 独显 + 核显"
        } else if isActivelyUsingDiscrete {
            return "⚡ 独显"
        } else if onDiscrete {
            return "🌿 核显 (dGPU句柄休眠)"
        } else {
            return "🌿 核显"
        }
    }

    var detailText: String {
        var parts: [String] = []
        if onDiscrete {
            var d = "dGPU×\(discreteClientCount)"
            if hasDiscreteOpenGLLock { d += " [OpenGL锁]" }
            if hasDiscreteFramebuffer { d += " [FB]" }
            parts.append(d)
        }
        if onIntegrated {
            parts.append("iGPU×\(integratedClientCount)")
        }
        return parts.joined(separator: "  ")
    }
}

final class GPUProcessMonitor {
    private static let protectedNames: Set<String> = [
        "WindowServer", "loginwindow", "Dock", "Finder",
        "SystemUIServer", "ControlCenter", "NotificationCenter",
        "GPUGuardian", "kernel_task", "launchd"
    ]

    // CPU % needs two samples: (ΔCPU time / Δwall time) / logical core count.
    private struct CPUSample {
        let cpuTimeNS: UInt64
        let wallClock: Date
    }
    private static var cpuSamples: [Int32: CPUSample] = [:]
    private static let cpuLock = NSLock()
    private static let logicalCores = Double(ProcessInfo.processInfo.processorCount)

    /// Returns (cpuPercent, residentBytes). `cpuPercent` is nil on the first
    /// sighting of a PID or when usage is not readable (e.g. root processes).
    private static func usage(for pid: Int32) -> (cpu: Double?, memory: UInt64?) {
        var cpuNS: UInt64 = 0
        var rss: UInt64 = 0
        guard gpu_process_usage(pid, &cpuNS, &rss) == 0 else {
            cpuLock.lock(); cpuSamples.removeValue(forKey: pid); cpuLock.unlock()
            return (nil, nil)
        }

        let now = Date()
        cpuLock.lock()
        let previous = cpuSamples[pid]
        cpuSamples[pid] = CPUSample(cpuTimeNS: cpuNS, wallClock: now)
        // Drop samples for PIDs we have not seen recently to avoid stale buildup.
        if cpuSamples.count > 2048 {
            cpuSamples = cpuSamples.filter { now.timeIntervalSince($0.value.wallClock) < 120 }
        }
        cpuLock.unlock()

        var cpuPercent: Double? = nil
        if let prev = previous {
            let deltaCPU = Double(cpuNS > prev.cpuTimeNS ? cpuNS - prev.cpuTimeNS : 0)
            let deltaWall = now.timeIntervalSince(prev.wallClock)
            if deltaWall > 0.05 {
                // Normalize by core count so a fully busy core reads ~100%.
                cpuPercent = min(100.0 * logicalCores, deltaCPU / 1_000_000_000.0 / deltaWall / logicalCores * 100.0)
            }
        }
        return (cpuPercent, rss)
    }

    static func readHardwareStatus() -> GPUHardwareStatus {
        return gpu_read_hardware_status()
    }

    static func readPmsetGPUSwitch() -> Int {
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = ["-g"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let out = String(data: data, encoding: .utf8) {
                for line in out.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("gpuswitch") {
                        let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        if tokens.count >= 2, let val = Int(tokens[1]) {
                            return val
                        }
                    }
                }
            }
        } catch {}
        return 2
    }

    static func fetchProcesses(dgpuPowered: Bool) -> [GPUProcessInfo] {
        let maxEntries = 512
        var rawEntries = [GPUProcessEntry](repeating: GPUProcessEntry(), count: maxEntries)
        let count = Int(gpu_collect_processes(&rawEntries, Int32(maxEntries)))
        let selfPid = ProcessInfo.processInfo.processIdentifier

        var result: [GPUProcessInfo] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            let entry = rawEntries[i]
            // IOKit client records can outlive the process; never show dead PIDs.
            guard gpu_pid_is_alive(entry.pid) else { continue }

            let rawName = withUnsafePointer(to: entry.name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 128) {
                    String(cString: $0)
                }
            }

            let app = NSRunningApplication(processIdentifier: entry.pid)
            let displayName = app?.localizedName ?? rawName
            let icon = app?.icon ?? NSWorkspace.shared.icon(forFileType: NSFileTypeForHFSTypeCode(OSType(kGenericApplicationIcon)))
            icon.size = NSSize(width: 20, height: 20)

            let usageInfo = usage(for: entry.pid)

            let isProtected = (entry.pid == selfPid) ||
                              (entry.pid <= 1) ||
                              protectedNames.contains(rawName) ||
                              protectedNames.contains(displayName)

            let info = GPUProcessInfo(
                pid: entry.pid,
                name: displayName,
                bundleIdentifier: app?.bundleIdentifier,
                icon: icon,
                onDiscrete: entry.onDiscrete,
                onIntegrated: entry.onIntegrated,
                hasDiscreteOpenGLLock: entry.hasDiscreteOpenGLLock,
                hasDiscreteFramebuffer: entry.hasDiscreteFramebuffer,
                discreteClientCount: entry.discreteClientCount,
                integratedClientCount: entry.integratedClientCount,
                isProtected: isProtected,
                dgpuPoweredNow: dgpuPowered,
                cpuPercent: usageInfo.cpu,
                memoryBytes: usageInfo.memory
            )
            result.append(info)
        }

        result.sort { lhs, rhs in
            if lhs.gpuPriority != rhs.gpuPriority {
                return lhs.gpuPriority < rhs.gpuPriority
            }
            if lhs.discreteClientCount != rhs.discreteClientCount {
                return lhs.discreteClientCount > rhs.discreteClientCount
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return result
    }

    /// Perform system-level global GPU mode switch:
    /// 1) Try live AppleGraphicsControl mux switch;
    /// 2) Also apply persistent `pmset -a gpuswitch` policy via admin prompt if requested or if mux requires privileges.
    static func switchGlobalMode(_ mode: GPUMode, persistWithPmset: Bool) -> (success: Bool, message: String) {
        let muxResult = gpu_mux_switch_live(mode.rawValue)

        if persistWithPmset {
            let script = "do shell script \"pmset -a gpuswitch \(mode.rawValue)\" with administrator privileges"
            var errDict: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&errDict)
                if let err = errDict {
                    let msg = (err[NSAppleScript.errorMessage] as? String) ?? "权限授权被取消或失败"
                    if muxResult == 0 {
                        return (true, "Mux 实时切换已尝试，但 pmset 写入未完成: \(msg)")
                    }
                    return (false, "切换失败: \(msg)")
                }
                return (true, "已系统级切换为: \(mode.title)")
            }
        }

        if muxResult == 0 {
            return (true, "已通过硬件 Mux 切换为: \(mode.title)")
        } else {
            return (false, "硬件 Mux 返回状态码 \(muxResult)，建议使用「系统级策略切换 (pmset)」")
        }
    }

    static func terminateProcess(pid: Int32, force: Bool) -> (success: Bool, message: String) {
        // The process may have exited between the snapshot and the click.
        guard gpu_pid_is_alive(pid) else {
            return (false, "PID \(pid) 已经退出，列表将自动刷新")
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            let ok = force ? app.forceTerminate() : app.terminate()
            if ok {
                return (true, force ? "已发送强杀信号到 PID \(pid)" : "已请求应用退出 (PID \(pid))")
            }
        }
        let sig = force ? SIGKILL : SIGTERM
        if kill(pid, sig) == 0 {
            return (true, "已发送 \(force ? "SIGKILL" : "SIGTERM") 到 PID \(pid)")
        } else {
            let errStr = String(cString: strerror(errno))
            if errno == EPERM {
                // Root-owned process: offer AppleScript admin kill
                let cmd = "do shell script \"kill -\(force ? 9 : 15) \(pid)\" with administrator privileges"
                var errDict: NSDictionary?
                if let appleScript = NSAppleScript(source: cmd) {
                    appleScript.executeAndReturnError(&errDict)
                    if errDict == nil {
                        return (true, "已提权终止进程 PID \(pid)")
                    }
                }
            }
            return (false, "无法终止 PID \(pid): \(errStr)")
        }
    }
}
