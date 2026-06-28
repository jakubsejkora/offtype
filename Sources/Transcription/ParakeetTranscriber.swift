import OfftypeCore

// AGENT(Transcription): implement `ParakeetTranscriber` using FluidAudio
// (Parakeet TDT v2 CoreML at ~/Models/parakeet-tdt-0.6b-v2). Add FluidAudio to
// Package.swift (dependency + product on the Transcription target ONLY). Convert
// AudioSamples (16 kHz mono) → transcript; populate `spans` with per-word text +
// confidence where available. Keep this OFF the critical metric path — the Eval
// runner scores cached raw transcripts, not live STT.

/// A deterministic stand-in used until FluidAudio is wired, and for unit tests.
public struct StubTranscriber: Transcriber {
    private let fixed: String
    public init(returning fixed: String = "") { self.fixed = fixed }
    public func transcribe(_ audio: AudioSamples) async throws -> Transcript {
        Transcript(rawText: fixed, spans: fixed.split(separator: " ").map { TranscriptSpan(text: String($0)) })
    }
}
