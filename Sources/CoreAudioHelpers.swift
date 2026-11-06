import AppKit
import AudioToolbox
import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let what: String
    let status: OSStatus
    var errorDescription: String? { "\(what) failed (\(status.fourCC))" }
}

extension OSStatus {
    var fourCC: String {
        let n = UInt32(bitPattern: self)
        let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return "'" + String(decoding: bytes, as: UTF8.self) + "'"
        }
        return String(self)
    }
}

@inline(__always)
func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CoreAudioError(what: what, status: status) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func read<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, default value: T) throws -> T {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var v = value
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &v), "Read property")
        return v
    }

    func readObjectList(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size), "Read list size")
        var list = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &list), "Read list")
        return list
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value), "Read string")
        return value?.takeRetainedValue() as String? ?? ""
    }
}

/// One Core Audio "process object": any process that has talked to the audio system.
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isPlaying: Bool

    static func all() -> [AudioProcess] {
        let ids = (try? AudioObjectID.system.readObjectList(kAudioHardwarePropertyProcessObjectList)) ?? []
        return ids.compactMap { id in
            guard let pid = try? id.read(kAudioProcessPropertyPID, default: pid_t(-1)), pid > 0 else { return nil }
            let bundle = (try? id.readString(kAudioProcessPropertyBundleID)) ?? ""
            let running = (try? id.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundle, isPlaying: running != 0)
        }
    }
}

func defaultOutputDeviceUID() throws -> String {
    let device = try AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, default: AudioDeviceID.unknown)
    return try device.readString(kAudioDevicePropertyDeviceUID)
}

// Helper processes (Safari's WebKit GPU process, Chrome helpers…) are "owned" by their app.
// macOS tracks that as the responsible PID; the lookup is a libsystem symbol.
private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsibleFn: ResponsibleFn? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

func responsiblePID(for pid: pid_t) -> pid_t {
    guard let r = responsibleFn?(pid), r > 0 else { return pid }
    return r
}
