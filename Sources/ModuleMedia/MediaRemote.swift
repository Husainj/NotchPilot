import Foundation

/// System-wide media commands via the private MediaRemote framework.
/// Reading now-playing info is restricted on macOS 15.4+, but sending
/// commands still works and reaches whatever app owns playback.
enum MediaRemote {
    enum Command: Int32 {
        case play = 0, pause = 1, togglePlayPause = 2, nextTrack = 4, previousTrack = 5
    }

    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Bool

    private static let sendCommand: SendCommand? = {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    @discardableResult
    static func send(_ command: Command) -> Bool {
        sendCommand?(command.rawValue, nil) ?? false
    }
}
