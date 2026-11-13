import NotchShell
import SwiftUI

@MainActor
@Observable
public final class StatsModule: NotchModule {
    public let id = "stats"
    public let title = "Stats"
    public let systemImage = "gauge.with.dots.needle.67percent"

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

private enum StatColors {
    static let cpu = Color(red: 0.25, green: 0.9, blue: 0.7)
    static let memory = Color(red: 0.72, green: 0.5, blue: 1.0)
    static let disk = Color(red: 1.0, green: 0.65, blue: 0.3)
    static let network = Color(red: 0.38, green: 0.7, blue: 1.0)
}

private struct StatsView: View {
    let sampler: StatsSampler

    var body: some View {
        HStack(spacing: 10) {
            StatCard(title: "CPU", symbol: "cpu", color: StatColors.cpu, value: sampler.cpu,
                     detail: "\(Int((sampler.cpu * 100).rounded()))% in use")
            StatCard(title: "Memory", symbol: "memorychip", color: StatColors.memory,
                     value: Double(sampler.memoryUsed) / Double(max(sampler.memoryTotal, 1)),
                     detail: "\(ByteFormat.size(Int64(sampler.memoryUsed))) of \(ByteFormat.size(Int64(sampler.memoryTotal)))")
            StatCard(title: "Disk", symbol: "internaldrive", color: StatColors.disk,
                     value: sampler.diskTotal > 0 ? Double(sampler.diskUsed) / Double(sampler.diskTotal) : 0,
                     detail: "\(ByteFormat.size(sampler.diskTotal - sampler.diskUsed)) free")
            NetworkCard(sampler: sampler)
        }
        .padding(.vertical, 2)
        .onAppear { sampler.start() }
        .onDisappear { sampler.stop() }
    }
}

private struct StatCard: View {
    let title: String
    let symbol: String
    let color: Color
    let value: Double
    let detail: String

    var body: some View {
        let clamped = min(max(value, 0), 1)
        let ring = clamped > 0.9 ? Color.red : color
        IslandCard(tint: color, padding: 10) {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(color)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                }
                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: clamped)
                        .stroke(AngularGradient(colors: [ring.opacity(0.55), ring], center: .center,
                                                startAngle: .degrees(0), endAngle: .degrees(360 * clamped)),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: ring.opacity(0.5), radius: 4)
                        .animation(.easeOut(duration: 0.4), value: clamped)
                    Text("\(Int((clamped * 100).rounded()))%")
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                }
                .padding(4)
                .frame(maxHeight: .infinity)
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

private struct NetworkCard: View {
    let sampler: StatsSampler

    var body: some View {
        IslandCard(tint: StatColors.network, padding: 10) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: "network")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(StatColors.network)
                    Text("Network")
                        .font(.system(size: 11, weight: .semibold))
                }
                row("arrow.down", color: StatColors.cpu, ByteFormat.rate(sampler.downloadRate))
                row("arrow.up", color: StatColors.network, ByteFormat.rate(sampler.uploadRate))
                Spacer(minLength: 0)
                if let battery = sampler.battery {
                    Divider().overlay(.white.opacity(0.12))
                    row("heart.fill", color: .pink, "Health \(battery.healthPercent)%")
                    row("arrow.triangle.2.circlepath", color: StatColors.disk, "\(battery.cycleCount) cycles")
                }
            }
        }
        .frame(width: 150)
    }

    private func row(_ symbol: String, color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 16, height: 16)
                .background(color.opacity(0.18), in: Circle())
            Text(text)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}
