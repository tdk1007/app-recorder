import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        VStack(spacing: 0) {
            if model.apps.isEmpty {
                ContentUnavailableView {
                    Label("No Apps Using Audio", systemImage: "speaker.slash")
                } description: {
                    Text("Start playing something in an app and it will show up here.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $model.selectedID) {
                    let playing = model.apps.filter(\.isPlaying)
                    let quiet = model.apps.filter { !$0.isPlaying }
                    if !playing.isEmpty {
                        Section("Playing now") {
                            ForEach(playing) { app in
                                AppRow(app: app, isRecordingThis: model.recordingApp?.id == app.id).tag(app.id)
                            }
                        }
                    }
                    if !quiet.isEmpty {
                        Section("Other apps") {
                            ForEach(quiet) { app in
                                AppRow(app: app, isRecordingThis: model.recordingApp?.id == app.id).tag(app.id)
                            }
                        }
                    }
                }
                .disabled(model.isRecording)
            }
            Divider()
            ControlPanel()
        }
        .toolbar {
            ToolbarItem {
                Button { model.openFolder() } label: {
                    Label("Recordings Folder", systemImage: "folder")
                }
                .help("Open the recordings folder")
            }
        }
    }
}

struct AppRow: View {
    let app: RecordableApp
    let isRecordingThis: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                Text(isRecordingThis ? "Recording" : app.isPlaying ? "Playing" : "Not playing")
                    .font(.caption)
                    .foregroundStyle(isRecordingThis ? .red : .secondary)
            }
            Spacer()
            if app.isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct ControlPanel: View {
    @EnvironmentObject var model: RecorderModel

    private var shownApp: RecordableApp? { model.recordingApp ?? model.selectedApp }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                if let app = shownApp {
                    Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                    Text(app.name).font(.headline).lineLimit(1)
                } else {
                    Text("Choose an app above").foregroundStyle(.secondary)
                }
                Spacer()
                Text(timeString(model.elapsed))
                    .font(.system(.title2, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(model.isRecording ? .primary : .tertiary)
            }

            LevelMeter(peak: model.level)

            HStack {
                Toggle("Mute on my speakers", isOn: $model.muteSpeakers)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Record the app without hearing it yourself")
                Spacer()
                Picker("Format", selection: $model.format) {
                    ForEach(OutputFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("M4A is small; WAV is lossless")
            }
            .disabled(model.isRecording)

            RecordButton(isRecording: model.isRecording) { model.toggle() }
                .disabled(!model.isRecording && model.selectedApp == nil)

            StatusLine()
                .frame(minHeight: 34, alignment: .top)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(.regularMaterial)
    }

    private func timeString(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
            : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

struct StatusLine: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        Group {
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            } else if model.isRecording && model.elapsed > 4 && !model.heardSound {
                VStack(spacing: 4) {
                    Text("No sound yet. Make sure the app is playing.")
                    Button("Allowed recording? Check Privacy settings…") { model.openPrivacySettings() }
                        .buttonStyle(.link)
                }
                .foregroundStyle(.secondary)
            } else if let url = model.lastSaved, !model.isRecording {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "play.fill") }
                        .help("Play")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Show in Finder")
                }
                .buttonStyle(.borderless)
            } else {
                Text(model.isRecording ? "Recording…" : "Press ⌘R or the button to record")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
    }
}

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 3)
                    .frame(width: 60, height: 60)
                RoundedRectangle(cornerRadius: isRecording ? 6 : 24, style: .continuous)
                    .fill(Color.red.opacity(isEnabled ? 1 : 0.35))
                    .frame(width: isRecording ? 24 : 48, height: isRecording ? 24 : 48)
            }
            .contentShape(Circle())
            .animation(.spring(duration: 0.3, bounce: 0.2), value: isRecording)
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Stop recording (⌘R)" : "Start recording (⌘R)")
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

struct LevelMeter: View {
    let peak: Float

    private var fraction: CGFloat {
        guard peak > 0 else { return 0 }
        let db = 20 * log10(Double(peak))
        return CGFloat(min(max((db + 60) / 60, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red],
                                         startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: geo.size.width * fraction)
                    }
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.08), value: fraction)
        .accessibilityHidden(true)
    }
}
