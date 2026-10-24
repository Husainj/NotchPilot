import Foundation
import Observation

/// Holds every module, tracks which are enabled, and starts/stops them.
@MainActor
@Observable
public final class ModuleRegistry {
    public private(set) var all: [any NotchModule] = []
    public private(set) var disabledIDs: Set<String>

    @ObservationIgnored private weak var context: NotchContext?
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults
    private static let disabledKey = "disabledModules"
    private static let seenKey = "seenModules"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        disabledIDs = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
    }

    public var enabled: [any NotchModule] {
        all.filter { !disabledIDs.contains($0.id) }
    }

    public func module(id: String) -> (any NotchModule)? {
        all.first { $0.id == id }
    }

    /// `enabledByDefault: false` keeps niche modules off until the user turns them on.
    /// Defaults apply only the first time a module is seen, so user choices stick.
    public func register(_ module: any NotchModule, enabledByDefault: Bool = true) {
        all.append(module)
        var seen = Set(defaults.stringArray(forKey: Self.seenKey) ?? [])
        guard !seen.contains(module.id) else { return }
        seen.insert(module.id)
        defaults.set(Array(seen), forKey: Self.seenKey)
        if !enabledByDefault {
            disabledIDs.insert(module.id)
            defaults.set(Array(disabledIDs), forKey: Self.disabledKey)
        }
    }

    func startEnabled(context: NotchContext) {
        self.context = context
        for module in enabled { start(module) }
    }

    public func isEnabled(_ id: String) -> Bool { !disabledIDs.contains(id) }

    public func setEnabled(_ id: String, _ isEnabled: Bool) {
        if isEnabled { disabledIDs.remove(id) } else { disabledIDs.insert(id) }
        defaults.set(Array(disabledIDs), forKey: Self.disabledKey)
        guard let module = module(id: id) else { return }
        if isEnabled { start(module) } else { stop(module) }
    }

    public func stopAll() {
        for module in all { stop(module) }
    }

    private func start(_ module: any NotchModule) {
        guard let context, !running.contains(module.id) else { return }
        running.insert(module.id)
        module.start(context: context)
    }

    private func stop(_ module: any NotchModule) {
        guard running.remove(module.id) != nil else { return }
        module.stop()
    }
}
