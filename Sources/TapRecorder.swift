import Accelerate
import AVFoundation
import CoreAudio
import Foundation

enum OutputFormat: String, CaseIterable, Identifiable {
    case m4a, wav
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

/// Records the audio of a set of processes using a Core Audio process tap (macOS 14.4+).
/// No virtual audio driver involved: the tap is private to this app and goes away when we stop.
final class TapRecorder {
    struct Update {
        let peak: Float
        let seconds: Double
        let heardSound: Bool
    }

    var onUpdate: ((Update) -> Void)?

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "AppRecorder.io", qos: .userInitiated)

    private var framesWritten: Int64 = 0
    private var framesSinceUpdate: Int64 = 0
    private var pendingPeak: Float = 0
    private var heardSound = false

    func start(processes: [AudioObjectID], muteSpeakers: Bool, url: URL, format: OutputFormat) throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.name = "App Recorder"
        desc.isPrivate = true
        desc.muteBehavior = muteSpeakers ? .mutedWhenTapped : .unmuted
        if #available(macOS 26.0, *) {
            // Keep capturing if the app's audio helper quits and comes back mid-recording.
            desc.isProcessRestoreEnabled = true
        }

        var tap = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(desc, &tap), "Create process tap")
        tapID = tap

        do {
            let outputUID = try defaultOutputDeviceUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "App Recorder Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                ]],
            ]
            var agg = AudioObjectID.unknown
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg), "Create aggregate device")
            aggregateID = agg

            var asbd = try tapID.read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
            guard let pcm = AVAudioFormat(streamDescription: &asbd) else {
                throw CoreAudioError(what: "Read tap format", status: -1)
            }

            let settings: [String: Any]
            switch format {
            case .m4a:
                settings = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: pcm.sampleRate,
                    AVNumberOfChannelsKey: pcm.channelCount,
                    AVEncoderBitRateKey: 256_000,
                ]
            case .wav:
                settings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: pcm.sampleRate,
                    AVNumberOfChannelsKey: pcm.channelCount,
                    AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
            }
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: pcm.isInterleaved)

            let updateEvery = Int64(pcm.sampleRate / 20)
            let sampleRate = pcm.sampleRate
            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, input, _, _, _ in
                guard let self, let file = self.file,
                      let buffer = AVAudioPCMBuffer(pcmFormat: pcm, bufferListNoCopy: input, deallocator: nil)
                else { return }
                try? file.write(from: buffer)

                let peak = Self.peak(of: buffer)
                self.pendingPeak = max(self.pendingPeak, peak)
                if peak > 0.0005 { self.heardSound = true }
                self.framesWritten += Int64(buffer.frameLength)
                self.framesSinceUpdate += Int64(buffer.frameLength)
                if self.framesSinceUpdate >= updateEvery {
                    let update = Update(peak: self.pendingPeak,
                                        seconds: Double(self.framesWritten) / sampleRate,
                                        heardSound: self.heardSound)
                    self.pendingPeak = 0
                    self.framesSinceUpdate = 0
                    self.onUpdate?(update)
                }
            }, "Create IO proc")
            procID = proc

            try check(AudioDeviceStart(aggregateID, procID), "Start recording")
        } catch {
            stop()
            throw error
        }
    }

    /// Stops and finalizes the file. Safe to call more than once.
    func stop() {
        if aggregateID != .unknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            queue.sync {} // let any in-flight buffer finish writing
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != .unknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
        queue.sync { file = nil } // releasing the AVAudioFile closes and finalizes it
    }

    deinit { stop() }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let fmt = buffer.format
        let channels = fmt.isInterleaved ? 1 : Int(fmt.channelCount)
        let count = Int(buffer.frameLength) * (fmt.isInterleaved ? Int(fmt.channelCount) : 1)
        guard count > 0 else { return 0 }
        var result: Float = 0
        for c in 0..<channels {
            var m: Float = 0
            vDSP_maxmgv(data[c], 1, &m, vDSP_Length(count))
            result = max(result, m)
        }
        return result
    }
}
