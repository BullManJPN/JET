# Roadmap

Ideas that are not started. Nothing here is promised.

- **System audio via a Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) so that only the "System Audio Recording" permission is needed instead of "Screen & System Audio Recording". Looks feasible, but is untested on macOS 27.2. Needs handling for the silent-audio case when permission is denied, `NSAudioCaptureUsageDescription` written directly into `Info.plist`, and checks for aggregate devices, output-device changes, stereo-to-mono conversion and Bluetooth.
- **Capture one app only** (`--app <bundleID>`), by changing how the `SCContentFilter` is built.
- **Key phrases** for meetings: the core of what is being said in 2–3 words (agenda item, action item) in a separate field from the captions.
- **Stronger detection of Chinese characters** mixed into the on-device model's output (not currently reproducible; to be done if it reappears).
- **Closing clauses on pauses by JET itself** (without forcing the recognizer to finalize). Expected gain is small (about 0.3 s).
