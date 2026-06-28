import Foundation
import os

// MARK: - Logging
//
// One subsystem, per-category loggers. Transcripts, keys, and screenshots must
// be logged with `privacy: .private` (or not at all) — see SECURITY.md.
public enum Log {
    public static let subsystem = "cz.sejkora.offtype"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let stt = Logger(subsystem: subsystem, category: "stt")
    public static let learning = Logger(subsystem: subsystem, category: "learning")
    public static let inject = Logger(subsystem: subsystem, category: "inject")
    public static let cloud = Logger(subsystem: subsystem, category: "cloud")
    public static let screen = Logger(subsystem: subsystem, category: "screen")
}

// MARK: - Paths

public enum AppPaths {
    /// `~/Library/Application Support/Offtype` — the on-device learning store lives here.
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Offtype", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var databaseURL: URL {
        appSupport.appendingPathComponent("offtype.sqlite")
    }

    /// Local model weights live OUTSIDE the bundle, at `~/Models`, to keep the app lean.
    public static var models: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models", isDirectory: true)
    }
}

// MARK: - Pipeline state (drives the Dynamic Circle HUD)

public enum PipelineState: Sendable, Equatable {
    case idle
    case listening(level: Float)   // 0...1 mic RMS for the live waveform
    case processing
    case result(ok: Bool)
}

// MARK: - Feature flags
//
// `cloudFeaturesEnabled` is the single switch that gates ALL networking. When
// false, no cloud client is ever instantiated — "nothing leaves the machine."
public struct FeatureFlags: Sendable, Equatable, Codable {
    public var cloudFeaturesEnabled: Bool
    public var computerUseEnabled: Bool
    public var screenAwarenessEnabled: Bool
    public var llmCleanupEnabled: Bool

    public init(
        cloudFeaturesEnabled: Bool = false,
        computerUseEnabled: Bool = false,
        screenAwarenessEnabled: Bool = false,
        llmCleanupEnabled: Bool = false
    ) {
        self.cloudFeaturesEnabled = cloudFeaturesEnabled
        self.computerUseEnabled = computerUseEnabled
        self.screenAwarenessEnabled = screenAwarenessEnabled
        self.llmCleanupEnabled = llmCleanupEnabled
    }

    public static let demoDefault = FeatureFlags()
}

// MARK: - Errors

public enum OfftypeError: Error, Sendable, Equatable {
    case secureInputActive
    case permissionDenied(String)
    case transcriptionFailed(String)
    case modelNotFound(String)
    case cloudDisabled
    case missingAPIKey
}
