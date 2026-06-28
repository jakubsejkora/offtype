#if canImport(FluidAudio)
import FluidAudio
#endif
import Foundation
import OfftypeCore

// AGENT(Transcription): `ParakeetTranscriber` runs on-device STT via FluidAudio
// (Parakeet TDT v2, CoreML/ANE) loaded from ~/Models/parakeet-tdt-0.6b-v2. It
// converts AudioSamples (16 kHz mono Float) into a Transcript whose `spans` are
// per-word, carrying the model's per-token confidence (averaged across the word).
// This is OFF the critical metric path — the Eval runner scores cached raw
// transcripts, not live STT. `StubTranscriber` (below) stays the offline/test default.

/// On-device speech-to-text backed by FluidAudio's Parakeet TDT v2 CoreML models.
///
/// An actor so the lazily-loaded `AsrManager` is created exactly once and shared
/// safely across concurrent dictations. The whole FluidAudio surface is wrapped in
/// `#if canImport(FluidAudio)`: if the dependency is ever dropped, this type still
/// compiles (degrading to an empty transcript) and `StubTranscriber` remains usable.
public actor ParakeetTranscriber: Transcriber {

    /// Default on-disk model location: `~/Models/parakeet-tdt-0.6b-v2`. This matches
    /// FluidAudio's `Repo.parakeetV2.folderName` (which strips the `-coreml` suffix),
    /// so `AsrModels.load(from:)` resolves straight to these files with no rename.
    public static let defaultModelDirectory =
        AppPaths.models.appendingPathComponent("parakeet-tdt-0.6b-v2", isDirectory: true)

    static let locale = "en_US"
    /// SentencePiece word-start marker (U+2581 "▁"). A token beginning with it starts
    /// a new word; tokens without it (e.g. trailing punctuation) extend the current word.
    static let wordBoundary: Character = "\u{2581}"

    private let modelDirectory: URL
    private let allowDownloadFallback: Bool

    #if canImport(FluidAudio)
    private var manager: AsrManager?
    private var decoderLayers: Int = 2
    /// Cached in-flight load so concurrent first-calls share one model load (actors are
    /// reentrant across `await`, so a plain `if manager == nil` check would double-load).
    private var loadTask: Task<(AsrManager, Int), Error>?
    #endif

    /// - Parameters:
    ///   - modelDirectory: Where the Parakeet TDT v2 CoreML bundle lives on disk.
    ///   - allowDownloadFallback: If the models are missing locally, let FluidAudio
    ///     download them (one-time, model weights only — no user data leaves the Mac).
    ///     When `false`, a missing model throws `OfftypeError.modelNotFound`.
    public init(
        modelDirectory: URL = ParakeetTranscriber.defaultModelDirectory,
        allowDownloadFallback: Bool = true
    ) {
        self.modelDirectory = modelDirectory
        self.allowDownloadFallback = allowDownloadFallback
    }

    public func transcribe(_ audio: AudioSamples) async throws -> Transcript {
        #if canImport(FluidAudio)
        if abs(audio.sampleRate - 16_000) > 1 {
            // The capture contract is 16 kHz mono; Parakeet assumes it. Log, don't fail.
            Log.stt.error(
                "ParakeetTranscriber expected 16 kHz audio, got \(audio.sampleRate, privacy: .public) Hz"
            )
        }

        let manager = try await ensureManager()
        var decoderState = try makeDecoderState()

        do {
            let result = try await manager.transcribe(audio.samples, decoderState: &decoderState)
            let transcript = Self.makeTranscript(from: result)
            Log.stt.info(
                "Parakeet transcribed \(transcript.spans.count, privacy: .public) words (confidence \(result.confidence, privacy: .public))"
            )
            Log.stt.debug("Parakeet raw text: \(transcript.rawText, privacy: .private)")
            return transcript
        } catch ASRError.invalidAudioData {
            // Sub-300ms / silent capture — not an error, just nothing to say.
            Log.stt.notice("Audio too short or silent; returning empty transcript")
            return Transcript(rawText: "", spans: [], locale: Self.locale)
        } catch {
            Log.stt.error("Parakeet transcription failed: \(error.localizedDescription, privacy: .public)")
            throw OfftypeError.transcriptionFailed(error.localizedDescription)
        }
        #else
        Log.stt.error(
            "ParakeetTranscriber built without FluidAudio; returning empty transcript. Use StubTranscriber for offline builds."
        )
        return Transcript(rawText: "", spans: [], locale: Self.locale)
        #endif
    }

    // MARK: - Token → word spans (pure; FluidAudio-independent so it's unit-testable)

    /// Merge per-token recognizer output into per-word spans. A token starting with the
    /// SentencePiece word-boundary marker opens a new word; the marker is dropped and the
    /// word's confidence is the mean of its tokens' confidences.
    static func wordSpans(fromTokens tokens: [(text: String, confidence: Double?)]) -> [TranscriptSpan] {
        var spans: [TranscriptSpan] = []
        var word = ""
        var confidences: [Double] = []

        func flush() {
            let trimmed = word.trimmingCharacters(in: .whitespaces)
            defer {
                word = ""
                confidences = []
            }
            guard !trimmed.isEmpty else { return }
            let avg = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
            spans.append(TranscriptSpan(text: trimmed, confidence: avg))
        }

        for token in tokens {
            if token.text.hasPrefix(String(wordBoundary)) {
                flush()
                word = String(token.text.dropFirst())
            } else {
                word += token.text
            }
            if let confidence = token.confidence {
                confidences.append(confidence)
            }
        }
        flush()
        return spans
    }
}

#if canImport(FluidAudio)
extension ParakeetTranscriber {

    private func makeDecoderState() throws -> TdtDecoderState {
        do {
            return try TdtDecoderState(decoderLayers: decoderLayers)
        } catch {
            throw OfftypeError.transcriptionFailed(
                "decoder state allocation failed: \(error.localizedDescription)"
            )
        }
    }

    private func ensureManager() async throws -> AsrManager {
        if let manager { return manager }

        let task: Task<(AsrManager, Int), Error>
        if let existing = loadTask {
            task = existing
        } else {
            let directory = modelDirectory
            let allowDownload = allowDownloadFallback
            let created = Task.detached(priority: .userInitiated) {
                try await ParakeetTranscriber.buildManager(
                    modelDirectory: directory, allowDownload: allowDownload)
            }
            loadTask = created
            task = created
        }

        do {
            let (loadedManager, layers) = try await task.value
            manager = loadedManager
            decoderLayers = layers
            return loadedManager
        } catch {
            // Drop the failed task so a later call can retry (e.g. once the user installs the model).
            loadTask = nil
            throw error
        }
    }

    private static func buildManager(
        modelDirectory: URL, allowDownload: Bool
    ) async throws -> (AsrManager, Int) {
        let models = try await loadAsrModels(modelDirectory: modelDirectory, allowDownload: allowDownload)
        let manager = AsrManager(config: .default, models: models)
        return (manager, models.version.decoderLayers)
    }

    private static func loadAsrModels(
        modelDirectory: URL, allowDownload: Bool
    ) async throws -> AsrModels {
        let version: AsrModelVersion = .v2

        if AsrModels.modelsExist(at: modelDirectory, version: version) {
            Log.stt.info("Loading Parakeet TDT v2 from \(modelDirectory.path, privacy: .public)")
            do {
                return try await AsrModels.load(from: modelDirectory, version: version)
            } catch {
                Log.stt.error(
                    "Failed to load local Parakeet models: \(error.localizedDescription, privacy: .public)")
                throw OfftypeError.modelNotFound(
                    "Parakeet TDT v2 at \(modelDirectory.path): \(error.localizedDescription)")
            }
        }

        guard allowDownload else {
            throw OfftypeError.modelNotFound("Parakeet TDT v2 model not found at \(modelDirectory.path)")
        }

        Log.stt.notice(
            "Parakeet models missing at \(modelDirectory.path, privacy: .public); attempting FluidAudio download fallback"
        )
        do {
            return try await AsrModels.downloadAndLoad(to: modelDirectory, version: version)
        } catch {
            throw OfftypeError.modelNotFound(
                "Parakeet TDT v2 unavailable at \(modelDirectory.path) and download failed: \(error.localizedDescription)"
            )
        }
    }

    /// Build a `Transcript` from FluidAudio's result, preferring per-token timings
    /// (merged into words) and falling back to a whitespace split when absent.
    static func makeTranscript(from result: ASRResult) -> Transcript {
        let spans: [TranscriptSpan]
        if let timings = result.tokenTimings, !timings.isEmpty {
            spans = wordSpans(
                fromTokens: timings.map { (text: $0.token, confidence: Double($0.confidence)) })
        } else {
            let confidence = Double(result.confidence)
            spans = result.text
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .map { TranscriptSpan(text: String($0), confidence: confidence) }
        }
        return Transcript(rawText: result.text, spans: spans, locale: locale)
    }
}
#endif

/// A deterministic stand-in used for offline builds and unit tests.
public struct StubTranscriber: Transcriber {
    private let fixed: String
    public init(returning fixed: String = "") { self.fixed = fixed }
    public func transcribe(_ audio: AudioSamples) async throws -> Transcript {
        Transcript(rawText: fixed, spans: fixed.split(separator: " ").map { TranscriptSpan(text: String($0)) })
    }
}
