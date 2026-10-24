import Testing
@testable import ModuleStats

@Test func cpuUsageFromTickDeltas() {
    let a = StatsSampler.CPUTicks(busy: 100, total: 1000)
    let b = StatsSampler.CPUTicks(busy: 400, total: 2000)
    #expect(b.usage(since: a) == 0.3)
    #expect(a.usage(since: a) == 0)
}

@Test func liveReadingsArePlausible() throws {
    let ticks = try #require(StatsSampler.readCPUTicks())
    #expect(ticks.total > 0 && ticks.busy <= ticks.total)
    #expect(StatsSampler.readMemoryUsed() > 0)
    let disk = try #require(StatsSampler.readDisk())
    #expect(disk.used > 0 && disk.used < disk.total)
    #expect(StatsSampler.readNetworkBytes() != nil)
}
