import Foundation

/// Watches the folder `notch-agent-hook` drops event files into and hands
/// them over in the order they were written. Files are deleted once read.
@MainActor
final class AgentEventWatcher {
    let directory: URL
    var onEvents: (([AgentEvent]) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var fallbackTimer: Timer?

    init(directory: URL) {
        self.directory = directory
    }

    func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Events from while NotchPilot wasn't running are stale; don't replay them.
        drain(maxAge: 120)

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drain(maxAge: nil) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        // Belt and braces in case a directory event is coalesced away.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain(maxAge: nil) }
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func drain(maxAge: TimeInterval?) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey],
                                                     options: []) else { return }
        let now = Date()
        var items: [(date: Date, url: URL)] = []
        // In-progress files are ".event.XXXXXX" without the .json extension.
        // Earlier hook versions left finished files hidden too, so don't skip dotfiles.
        for url in urls where url.pathExtension == "json" {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            items.append((created, url))
        }
        guard !items.isEmpty else { return }
        var events: [AgentEvent] = []
        for item in items.sorted(by: { $0.date < $1.date }) {
            defer { try? fm.removeItem(at: item.url) }
            if let maxAge, now.timeIntervalSince(item.date) > maxAge { continue }
            guard let data = try? Data(contentsOf: item.url),
                  var event = AgentEvent.parse(data, fallbackDate: item.date) else { continue }
            // The script's clock has 1s resolution; the file's creation time is finer.
            event.date = item.date
            events.append(event)
        }
        if !events.isEmpty { onEvents?(events) }
    }
}
