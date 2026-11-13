import Foundation
import ObjectiveC

/// Keyboard backlight via the private CoreBrightness `KeyboardBrightnessClient`.
/// Loaded at runtime so a missing class or selector degrades to "unsupported".
@MainActor
enum KeyboardBacklightController {
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> ObjCBool

    private static let client: NSObject? = {
        let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        guard dlopen(path, RTLD_LAZY) != nil,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return type.init()
    }()

    /// The first backlit keyboard, or nil when there is none (e.g. desktop Macs).
    private static let keyboardID: UInt64? = {
        guard let client else { return nil }
        let selector = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard client.responds(to: selector),
              let ids = client.perform(selector)?.takeRetainedValue() as? [NSNumber],
              let first = ids.first else { return nil }
        return first.uint64Value
    }()

    private static func implementation<T>(_ name: String, as type: T.Type) -> T? {
        guard let client, let method = class_getInstanceMethod(Swift.type(of: client), NSSelectorFromString(name))
        else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: type)
    }

    /// 0...1, or nil when unsupported.
    static var brightness: Float? {
        guard let client, let keyboardID,
              let get = implementation("brightnessForKeyboard:", as: GetFn.self) else { return nil }
        return get(client, NSSelectorFromString("brightnessForKeyboard:"), keyboardID)
    }

    static func setBrightness(_ value: Float) {
        guard let client, let keyboardID,
              let set = implementation("setBrightness:forKeyboard:", as: SetFn.self) else { return }
        _ = set(client, NSSelectorFromString("setBrightness:forKeyboard:"), min(max(value, 0), 1), keyboardID)
    }
}
