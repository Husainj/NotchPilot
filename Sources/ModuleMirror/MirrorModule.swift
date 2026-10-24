import AVFoundation
import NotchShell
import SwiftUI

/// Camera preview for a quick look before a call. The camera runs only
/// while the Mirror tab is on screen.
@MainActor
@Observable
public final class MirrorModule: NotchModule {
    public let id = "mirror"
    public let title = "Mirror"
    public let systemImage = "person.crop.square"

    let camera = CameraController()

    public init() {}

    public func start(context: NotchContext) {}
    public func stop() { camera.stop() }

    public func makeExpandedView() -> AnyView {
        AnyView(MirrorView(camera: camera))
    }
}

@MainActor
@Observable
final class CameraController {
    enum Status { case idle, running, denied, noCamera }

    private(set) var status: Status = .idle
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private var configured = false
    /// Session start/stop block, so they run off the main thread.
    @ObservationIgnored private let queue = DispatchQueue(label: "notch.mirror.camera")

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) { run() } else { status = .denied }
            }
        default:
            status = .denied
        }
    }

    func stop() {
        guard status == .running else { return }
        status = .idle
        nonisolated(unsafe) let session = session
        queue.async { session.stopRunning() }
    }

    private func run() {
        if !configured {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                status = .noCamera
                return
            }
            session.sessionPreset = .medium
            session.addInput(input)
            configured = true
        }
        status = .running
        nonisolated(unsafe) let session = session
        queue.async { session.startRunning() }
    }
}

private struct MirrorView: View {
    let camera: CameraController

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06))
            switch camera.status {
            case .denied:
                VStack(spacing: 6) {
                    Text("Camera access is off.").font(.callout)
                    Button("Open Camera Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                    .buttonStyle(.link).font(.caption)
                }
                .foregroundStyle(.white.opacity(0.6))
            case .noCamera:
                Text("No camera found.").font(.callout).foregroundStyle(.white.opacity(0.6))
            default:
                CameraPreview(session: camera.session)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        // Mirror like a real mirror.
        layer.connection?.automaticallyAdjustsVideoMirroring = false
        layer.connection?.isVideoMirrored = true
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
