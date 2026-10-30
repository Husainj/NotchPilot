import NotchShell
import SwiftUI

@MainActor
@Observable
public final class MediaModule: NotchModule {
    public let id = "media"
    public let title = "Now Playing"
    public let systemImage = "music.note"

    let service = NowPlayingService()

    public init() {}

    public func start(context: NotchContext) { service.start() }
    public func stop() { service.stop() }

    public func makeExpandedView() -> AnyView {
        AnyView(MediaExpandedView(service: service))
    }

    public var compactActivity: CompactActivity? {
        guard service.isPlaying, service.track != nil else { return nil }
        return CompactActivity(id: "media", priority: 10) {
            ArtworkView(image: service.artwork, cornerRadius: 5)
                .frame(width: 22, height: 22)
        } trailing: {
            EqualizerView()
                .frame(width: 18, height: 14)
        }
    }
}

struct MediaExpandedView: View {
    let service: NowPlayingService

    var body: some View {
        if let track = service.track {
            HStack(alignment: .center, spacing: 16) {
                ArtworkView(image: service.artwork, cornerRadius: 12)
                    .frame(width: 112, height: 112)
                    .overlay(alignment: .bottomTrailing) {
                        if let icon = service.sourceAppIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 30, height: 30)
                                .shadow(radius: 3)
                                .offset(x: 6, y: 6)
                        }
                    }
                    .onTapGesture { service.openPlayer() }
                    .help("Open \(service.sourceAppName ?? "player")")
                VStack(alignment: .leading, spacing: 6) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    ProgressScrubber(service: service, duration: track.duration)
                        .padding(.top, 6)
                    HStack(spacing: 28) {
                        ControlButton(systemImage: "backward.fill", size: 16) { service.previousTrack() }
                        ControlButton(systemImage: service.isPlaying ? "pause.fill" : "play.fill", size: 22) { service.togglePlayPause() }
                        ControlButton(systemImage: "forward.fill", size: 16) { service.nextTrack() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.35))
                Text("Nothing playing")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
                HStack(spacing: 28) {
                    ControlButton(systemImage: "backward.fill", size: 14) { service.previousTrack() }
                    ControlButton(systemImage: "playpause.fill", size: 18) { service.togglePlayPause() }
                    ControlButton(systemImage: "forward.fill", size: 14) { service.nextTrack() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ProgressScrubber: View {
    @Environment(\.notchAccent) private var accent
    let service: NowPlayingService
    let duration: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = service.currentPosition(at: context.date)
            VStack(spacing: 3) {
                GeometryReader { geo in
                    let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(accent).frame(width: geo.size.width * fraction)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        guard duration > 0 else { return }
                        let f = min(max(value.location.x / geo.size.width, 0), 1)
                        service.seek(to: f * duration)
                    })
                }
                .frame(height: 5)
                HStack {
                    Text(Self.format(position))
                    Spacer()
                    Text("-" + Self.format(max(duration - position, 0)))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct ControlButton: View {
    let systemImage: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 24, height: size + 18)
                .background(.white.opacity(hovering ? 0.1 : 0), in: Circle())
        }
        .buttonStyle(.island)
        .onHover { hovering = $0 }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.white.opacity(0.12))
                Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Small animated bars shown beside the notch while music plays.
struct EqualizerView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = sin(t * (5 + Double(i) * 1.7) + Double(i))
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(width: 2.5, height: 4 + 10 * CGFloat((phase + 1) / 2))
                }
            }
            .animation(.easeInOut(duration: 0.12), value: t)
        }
    }
}
