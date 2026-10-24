import Darwin
import Foundation
import IOKit
import Observation

/// Samples CPU, memory, disk, network and battery health. Runs only while
/// the Stats tab is visible.
@MainActor
@Observable
final class StatsSampler {
    private(set) var cpu: Double = 0              // 0...1
    private(set) var memoryUsed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    private(set) var diskUsed: Int64 = 0
    private(set) var diskTotal: Int64 = 0
    private(set) var downloadRate: Double = 0     // bytes/s
    private(set) var uploadRate: Double = 0
    private(set) var battery: BatteryHealth?

    struct BatteryHealth: Equatable {
        var healthPercent: Int
        var cycleCount: Int
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastCPU: CPUTicks?
    @ObservationIgnored private var lastNet: (bytesIn: UInt64, bytesOut: UInt64, date: Date)?
    @ObservationIgnored private var visibleCount = 0

    func start() {
        visibleCount += 1
        guard task == nil else { return }
        battery = Self.readBatteryHealth()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        visibleCount = max(visibleCount - 1, 0)
        guard visibleCount == 0 else { return }
        task?.cancel()
        task = nil
        lastCPU = nil
        lastNet = nil
    }

    private func sample() {
        if let ticks = Self.readCPUTicks() {
            if let lastCPU { cpu = ticks.usage(since: lastCPU) }
            lastCPU = ticks
        }
        memoryUsed = Self.readMemoryUsed()
        if let disk = Self.readDisk() { (diskUsed, diskTotal) = disk }
        let now = Date()
        if let net = Self.readNetworkBytes() {
            if let lastNet {
                let dt = now.timeIntervalSince(lastNet.date)
                if dt > 0 {
                    downloadRate = Double(net.bytesIn &- lastNet.bytesIn) / dt
                    uploadRate = Double(net.bytesOut &- lastNet.bytesOut) / dt
                }
            }
            lastNet = (net.bytesIn, net.bytesOut, now)
        }
    }

    // MARK: - CPU

    struct CPUTicks: Equatable {
        var busy: UInt64
        var total: UInt64

        /// Fraction of time busy between two samples.
        func usage(since previous: CPUTicks) -> Double {
            let dTotal = total &- previous.total
            guard dTotal > 0 else { return 0 }
            return min(max(Double(busy &- previous.busy) / Double(dTotal), 0), 1)
        }
    }

    nonisolated static func readCPUTicks() -> CPUTicks? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return CPUTicks(busy: busy, total: total)
    }

    // MARK: - Memory

    /// Roughly Activity Monitor's "Memory Used": app memory + wired + compressed.
    nonisolated static func readMemoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(sysconf(_SC_PAGESIZE))
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    // MARK: - Disk

    nonisolated static func readDisk() -> (used: Int64, total: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return (Int64(total) - available, Int64(total))
    }

    // MARK: - Network

    /// Total bytes in/out across physical interfaces (excludes loopback).
    nonisolated static func readNetworkBytes() -> (bytesIn: UInt64, bytesOut: UInt64)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var bytesIn: UInt64 = 0, bytesOut: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer?.pointee {
            defer { pointer = entry.ifa_next }
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            bytesIn += UInt64(data.pointee.ifi_ibytes)
            bytesOut += UInt64(data.pointee.ifi_obytes)
        }
        return (bytesIn, bytesOut)
    }

    // MARK: - Battery health

    nonisolated static func readBatteryHealth() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        guard let design = int("DesignCapacity"), design > 0,
              let max = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") else { return nil }
        return BatteryHealth(healthPercent: min(Int((Double(max) / Double(design) * 100).rounded()), 100),
                             cycleCount: int("CycleCount") ?? 0)
    }
}
