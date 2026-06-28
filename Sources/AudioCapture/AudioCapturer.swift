import Foundation
import AVFoundation
import os
import OfftypeCore

/// Captures microphone audio with `AVAudioEngine`, down-converts it to the
/// 16 kHz mono Float PCM the on-device recognizer expects, and publishes a
/// per-buffer RMS level (0...1) for the live HUD waveform.
///
/// Permission is requested on the first `start()`, never at init. `start()` may
/// block briefly the very first time while the system shows the microphone
/// prompt, so call it off the main thread (the hotkey callbacks already fire on
/// a background thread). Subsequent starts don't block.
///
/// `@unchecked Sendable`: the capture buffer, the per-session converter, and the
/// `onLevel` callback are guarded by `lock`. `AVAudioEngine`'s own tap callback
/// is serialized by the engine onto one thread.
public final class AudioCapturer: @unchecked Sendable {
    private static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()

    // Guarded by `lock`.
    private var captured: [Float] = []
    private var converter: AVAudioConverter?
    private var _onLevel: (@Sendable (Float) -> Void)?

    /// Per-buffer RMS level in 0...1 for the live waveform. Fired on the audio
    /// thread — hop to the main actor before touching UI.
    public var onLevel: (@Sendable (Float) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onLevel }
        set { lock.lock(); _onLevel = newValue; lock.unlock() }
    }

    public init() {}

    deinit {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Lifecycle

    /// Begin capturing. Throws `OfftypeError.permissionDenied("microphone")` if
    /// the user has denied access, or `.transcriptionFailed` if the input device
    /// or sample-rate converter can't be set up. Robust to start→stop→start.
    public func start() throws {
        try ensureMicrophoneAuthorized()

        // Clean slate — robust to a previous session or a half-failed start.
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw OfftypeError.transcriptionFailed("no microphone input available")
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw OfftypeError.transcriptionFailed("could not build 16 kHz output format")
        }

        guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw OfftypeError.transcriptionFailed("could not build audio converter")
        }

        lock.lock()
        captured.removeAll(keepingCapacity: true)
        converter = newConverter
        lock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, outputFormat: outputFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            lock.lock(); converter = nil; lock.unlock()
            Log.audio.error("AudioCapture: engine failed to start: \(error.localizedDescription, privacy: .public)")
            throw OfftypeError.transcriptionFailed("audio engine failed to start")
        }
        Log.audio.notice("AudioCapture: started (input \(inputFormat.sampleRate, privacy: .public) Hz → 16 kHz mono)")
    }

    /// Stop capturing and return everything recorded this session as 16 kHz mono
    /// Float PCM. Safe to call when not running (returns an empty buffer).
    public func stop() -> AudioSamples {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)

        lock.lock()
        let samples = captured
        captured.removeAll(keepingCapacity: false)
        converter = nil
        lock.unlock()

        Log.audio.notice("AudioCapture: stopped (\(samples.count, privacy: .public) samples)")
        return AudioSamples(samples: samples, sampleRate: Self.targetSampleRate)
    }

    // MARK: - Audio thread

    private func process(_ inputBuffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        lock.lock()
        let conv = converter
        lock.unlock()
        guard let conv, inputBuffer.frameLength > 0 else { return }

        // Down-sampling shrinks the frame count; size the output generously.
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        // The converter calls this block synchronously on this same audio thread,
        // so the SDK's `@Sendable` typing is stricter than reality — feed the one
        // input buffer once, then signal "no more". `nonisolated(unsafe)` states
        // that contract explicitly.
        nonisolated(unsafe) let bufferToConvert = inputBuffer
        nonisolated(unsafe) var consumed = false
        var convError: NSError?
        let status = conv.convert(to: outBuffer, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return bufferToConvert
        }

        if status == .error {
            if let convError {
                Log.audio.error("AudioCapture: convert error: \(convError.localizedDescription, privacy: .public)")
            }
            return
        }

        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0, let channel = outBuffer.floatChannelData?[0] else { return }

        var sumSquares: Float = 0
        var chunk = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let sample = channel[i]
            chunk[i] = sample
            sumSquares += sample * sample
        }

        lock.lock()
        captured.append(contentsOf: chunk)
        let levelCallback = _onLevel
        lock.unlock()

        if let levelCallback {
            let rms = sqrt(sumSquares / Float(frameCount))
            levelCallback(Self.normalizedLevel(rms: rms))
        }
    }

    /// Map a linear RMS amplitude onto a perceptual 0...1 meter (-60 dBFS floor).
    private static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let floorDB: Float = -60
        let level = (db - floorDB) / -floorDB
        return min(1, max(0, level))
    }

    // MARK: - Permission

    private func ensureMicrophoneAuthorized() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw OfftypeError.permissionDenied("microphone")
        case .notDetermined:
            // First use: request and wait. Off the main thread this blocks only
            // until the user answers the system prompt.
            let result = LockedFlag()
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                result.set(granted)
                semaphore.signal()
            }
            semaphore.wait()
            if !result.get() {
                throw OfftypeError.permissionDenied("microphone")
            }
        @unknown default:
            throw OfftypeError.permissionDenied("microphone")
        }
    }
}

/// A minimal lock-protected Bool so the permission completion handler can hand a
/// result back across the semaphore without tripping strict-concurrency checks.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
