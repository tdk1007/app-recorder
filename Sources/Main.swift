import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--record-pid") {
            exit(CLI.run(args: Array(args[(i + 1)...])))
        }
        AppRecorderApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Finalize the file so a quit mid-recording still leaves a playable recording.
        MainActor.assumeIsolated { RecorderModel.shared.stop() }
    }
}

struct AppRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = RecorderModel.shared

    var body: some Scene {
        Window("App Recorder", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 360, idealWidth: 380, minHeight: 460, idealHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 380, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Recording") {
                Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggle() }
                    .keyboardShortcut("r")
                    .disabled(!model.isRecording && model.selectedApp == nil)
                Divider()
                Button("Open Recordings Folder") { model.openFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

/// Headless mode for testing: AppRecorder --record-pid <pid> <seconds> <out.m4a|out.wav>
enum CLI {
    static func run(args: [String]) -> Int32 {
        guard args.count == 3, let pid = pid_t(args[0]), let seconds = Double(args[1]) else {
            print("usage: AppRecorder --record-pid <pid> <seconds> <output.m4a|output.wav>")
            return 2
        }
        let url = URL(fileURLWithPath: args[2])
        let objects = AudioProcess.all().filter { $0.pid == pid }.map(\.objectID)
        guard !objects.isEmpty else {
            print("pid \(pid) has no Core Audio process object (is it playing audio?)")
            return 1
        }
        let rec = TapRecorder()
        var last: TapRecorder.Update?
        rec.onUpdate = { last = $0 }
        do {
            try rec.start(processes: objects, muteSpeakers: false, url: url,
                          format: url.pathExtension.lowercased() == "wav" ? .wav : .m4a)
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
        Thread.sleep(forTimeInterval: seconds)
        rec.stop()
        print(String(format: "recorded %.2fs, heardSound=%@ -> %@",
                     last?.seconds ?? 0, String(last?.heardSound ?? false), url.path))
        return 0
    }
}
