# App Recorder

A small Mac app that records the sound coming out of one app. It is a free stand-in for Rogue Amoeba's Audio Hijack and Piezo.

It uses Core Audio process taps (macOS 14.4+), so it installs no virtual audio driver. The tap is private to this app and goes away when you stop recording.

## Use

1. Open **App Recorder** (installed in `/Applications`).
2. Pick an app. Apps making sound are listed under **Playing now**.
3. Press the red button or ⌘R. Press it again to stop.
4. Recordings go to `~/Music/App Recorder/<App> <date> at <time>.m4a`. Use the folder button, or ⇧⌘O, to open that folder.

Options:

- **Mute on my speakers**: records the app without you hearing it.
- **M4A / WAV**: M4A is AAC at 256 kbps. WAV is 24-bit lossless.

The first time you record, macOS asks for permission to record system audio. If you denied it, go to System Settings › Privacy & Security › Screen & System Audio Recording and turn on App Recorder.

## Notes

- Helper processes are grouped under their app. For example, Safari's WebKit audio process counts as Safari, and Chrome's helpers count as Chrome.
- A command-line tool with no owning app (for example `afplay`) shows under its own name while it is playing.
- "Playing" means the app has an open audio output, not that it is loud. For example, QuickTime with an empty Audio Recording window counts as playing but is silent.
- If a recording catches no sound at all, the app doesn't keep a file.
- On macOS 26, if the app's audio helper restarts mid-recording, the recording keeps capturing it.

## Build

```bash
./build.sh               # builds, signs with your Apple Development identity, installs to /Applications
./build.sh --no-install  # builds into ./build only
```

Signing with a stable identity, not ad-hoc, keeps macOS from asking for recording permission again after every rebuild.

Headless test mode: `AppRecorder --record-pid <pid> <seconds> <out.m4a|out.wav>`. Launch it with `open -n "/Applications/App Recorder.app" --args …` so macOS applies the app's own recording permission.

## License

MIT. See [LICENSE](LICENSE).
