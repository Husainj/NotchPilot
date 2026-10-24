import NotchShell
import SwiftUI

@MainActor
@Observable
public final class StatsModule: NotchModule {
    public let id = "stats"
    public let title = "Stats"
    public let systemImage = "cpu"

    let sampler = StatsSampler()

    public init() {}

    public func start(context: NotchContext) {}
    public func stop() {}

    public func makeExpandedView() -> AnyView {
        AnyView(StatsView(sampler: sampler))
    }
}

enum ByteFormat {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}

private struct StatsView: View {
    let sampler: StatsSampler

    var body: some View {
        HStack(spacing: 18) {
            StatRing(title: "CPU", value: sampler.cpu,
                     detail: "\(Int((sampler.cpu * 100).rounded()))%")
            StatRing(title: "Memory",
                     value: Double(sampler.memoryUsed) / Double(max(sampler.memoryTotal, 1)),
                     detail: "\(ByteFormat.size(Int64(sampler.memoryUsed))) of \(ByteFormat.size(Int64(sampler.memoryTotal)))")
            StatRing(title: "Disk",
                     value: sampler.diskTotal > 0 ? Double(sampler.diskUsed) / Double(sampler.diskTotal) : 0,
                     detail: "\(ByteFormat.size(sampler.diskTotal - sampler.diskUsed)) free")
            VStack(alignment: .leading, spacing: 10) {
                Label(ByteFormat.rate(sampler.downloadRate), systemImage: "arrow.down.circle.fill")
                Label(ByteFormat.rate(sampler.uploadRate), systemImage: "arrow.up.circle.fill")
                if let battery = sampler.battery {
                    Divider().overlay(.white.opacity(0.15))
                    Label("Battery health \(battery.healthPercent)%", systemImage: "heart.fill")
                    Label("\(battery.cycleCount) cycles", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 6)
        .onAppear { sampler.start() }
        .onDisappear { sampler.stop() }
    }
}

private struct StatRing: View {
    let title: String
    let value: Double
    let detail: String
    @Environment(\.notchAccent) private var accent

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: min(max(value, 0), 1))
                    .stroke(value > 0.9 ? Color.red : accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
                Text("\(Int((min(max(value, 0), 1) * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            .frame(width: 70, height: 70)
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 96)
    }
}
