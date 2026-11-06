import AppKit
import CoreAudio
import SwiftUI

struct RecordableApp: Identifiable, Equatable {
    let id: pid_t // the app's own PID (helpers are grouped under it)
    let name: String
    let bundleID: String
    let icon: NSImage
    let processObjects: [AudioObjectID]
    let isPlaying: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.isPlaying == b.isPlaying && a.processObjects == b.processObjects && a.name == b.name
    }

    /// Groups every audio-using process under the app that owns it.
    /// Regular (Dock) apps always show; menu-bar/background apps and bare
    /// command-line processes show only while they are making sound.
    static func current() -> [RecordableApp] {
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications

        struct Group {
            var name: String
            var bundleID: String
            var icon: NSImage
            var isRegularApp: Bool
            var objects: [AudioObjectID] = []
            var playing = false
        }
        var groups: [pid_t: Group] = [:]

        for proc in AudioProcess.all() where proc.pid != me {
            let owner = NSRunningApplication(processIdentifier: responsiblePID(for: proc.pid))
                ?? NSRunningApplication(processIdentifier: proc.pid)
                ?? running.first { app in
                    guard let b = app.bundleIdentifier, !proc.bundleID.isEmpty else { return false }
                    return proc.bundleID.hasPrefix(b + ".")
                }

            let key: pid_t
            var group: Group
            if let owner {
                guard owner.processIdentifier != me else { continue }
                key = owner.processIdentifier
                group = groups[key] ?? Group(
                    name: owner.localizedName ?? owner.bundleIdentifier ?? "Unknown",
                    bundleID: owner.bundleIdentifier ?? "",
                    icon: owner.icon ?? NSWorkspace.shared.icon(for: .application),
                    isRegularApp: owner.activationPolicy == .regular)
            } else {
                // A command-line tool or daemon with no owning app: list it by its own name.
                key = proc.pid
                group = groups[key] ?? Group(
                    name: processName(proc.pid) ?? (proc.bundleID.isEmpty ? "pid \(proc.pid)" : proc.bundleID),
                    bundleID: proc.bundleID,
                    icon: NSWorkspace.shared.icon(for: .unixExecutable),
                    isRegularApp: false)
            }
            group.objects.append(proc.objectID)
            group.playing = group.playing || proc.isPlaying
            groups[key] = group
        }

        return groups.compactMap { pid, g in
            guard g.isRegularApp || g.playing else { return nil }
            return RecordableApp(id: pid, name: g.name, bundleID: g.bundleID, icon: g.icon,
                                 processObjects: g.objects.sorted(), isPlaying: g.playing)
        }
        .sorted { ($0.isPlaying ? 0 : 1, $0.name.localizedLowercase) < ($1.isPlaying ? 0 : 1, $1.name.localizedLowercase) }
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }
}

@MainActor
final class RecorderModel: ObservableObject {
    static let shared = RecorderModel()

    @Published var apps: [RecordableApp] = []
    @Published var selectedID: pid_t?
    @Published private(set) var recordingApp: RecordableApp?
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var heardSound = false
    @Published private(set) var lastSaved: URL?
    @Published var errorMessage: String?

    @Published var muteSpeakers: Bool = UserDefaults.standard.bool(forKey: "muteSpeakers") {
        didSet { UserDefaults.standard.set(muteSpeakers, forKey: "muteSpeakers") }
    }
    @Published var format: OutputFormat =
        OutputFormat(rawValue: UserDefaults.standard.string(forKey: "format") ?? "") ?? .m4a {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "format") }
    }

    var isRecording: Bool { recordingApp != nil }
    var selectedApp: RecordableApp? { apps.first { $0.id == selectedID } }

    static let folder: URL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("App Recorder", isDirectory: true)

    private var recorder: TapRecorder?
    private var currentURL: URL?
    private var timer: Timer?

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in RecorderModel.shared.refresh() }
        }
    }

    func refresh() {
        let fresh = RecordableApp.current()
        if fresh != apps { apps = fresh }
        if !isRecording, let id = selectedID, !apps.contains(where: { $0.id == id }) {
            selectedID = nil
        }
        if selectedID == nil, !isRecording, let firstPlaying = apps.first(where: \.isPlaying) {
            selectedID = firstPlaying.id
        }
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording, let app = selectedApp else { return }
        errorMessage = nil
        lastSaved = nil
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
                                                   timeZone: .current, calendar: .current))
            let safeName = app.name.replacingOccurrences(of: "/", with: "-")
            let url = Self.folder.appendingPathComponent("\(safeName) \(stamp).\(format.rawValue)")

            let rec = TapRecorder()
            rec.onUpdate = { update in
                DispatchQueue.main.async {
                    let model = RecorderModel.shared
                    guard model.isRecording else { return }
                    model.level = update.peak
                    model.elapsed = update.seconds
                    model.heardSound = update.heardSound
                }
            }
            try rec.start(processes: app.processObjects, muteSpeakers: muteSpeakers, url: url, format: format)
            recorder = rec
            currentURL = url
            elapsed = 0
            level = 0
            heardSound = false
            recordingApp = app
        } catch {
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard let rec = recorder else { return }
        rec.stop()
        recorder = nil
        recordingApp = nil
        level = 0
        if let url = currentURL {
            if heardSound {
                lastSaved = url
            } else {
                try? FileManager.default.removeItem(at: url)
                errorMessage = "Nothing was recorded — the app was silent, so no file was saved."
            }
        }
        currentURL = nil
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.folder)
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
