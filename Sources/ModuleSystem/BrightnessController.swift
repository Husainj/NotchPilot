import CoreGraphics
import Foundation

/// Built-in display brightness via the private DisplayServices framework.
/// Loaded with dlopen so a missing symbol degrades to "unsupported".
enum BrightnessController {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let functions: (get: GetFn, set: SetFn)? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(get, to: GetFn.self), unsafeBitCast(set, to: SetFn.self))
    }()

    private static var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &displays, &count)
        return displays.first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// 0...1, or nil when unsupported (no built-in display, or API unavailable).
    static var brightness: Float? {
        guard let functions, let display = builtInDisplay else { return nil }
        var value: Float = 0
        return functions.get(display, &value) == 0 ? value : nil
    }

    static func setBrightness(_ value: Float) {
        guard let functions, let display = builtInDisplay else { return }
        _ = functions.set(display, min(max(value, 0), 1))
    }
}
