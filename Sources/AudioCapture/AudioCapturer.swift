import OfftypeCore

// AGENT(AudioCapture): implement an AVAudioEngine input tap that records mono
// PCM, converts to 16 kHz Float, and publishes RMS level (0...1) for the live
// waveform. Expose start() -> Void and stop() async -> AudioSamples. Requires
// Microphone permission (request on first use, not at launch).
//   var onLevel: (@Sendable (Float) -> Void)?

/// Placeholder so the package compiles before implementation.
public final class AudioCapturer: @unchecked Sendable {
    public init() {}
    public func start() throws {}
    public func stop() -> AudioSamples { AudioSamples(samples: [], sampleRate: 16_000) }
}
