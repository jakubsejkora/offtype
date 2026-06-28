// swift-tools-version: 6.0
import PackageDescription

// Offtype — a privacy-first, local-first macOS dictation app that learns your
// vocabulary so it relies less on the cloud/LLM over time.
//
// Architecture note: pure-logic libraries (OfftypeCore / LearningEngine /
// Persistence / Eval / Telemetry) carry zero OS-permission surface and are fully
// unit-testable without launching the app. OS-glue (Hotkey / AudioCapture /
// Injection / Transcription) and UI (HUD) sit above them. T2 modules
// (ScreenContext / ComputerUse) degrade gracefully and are never on the core
// demo path.
let package = Package(
    name: "Offtype",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Offtype", targets: ["OfftypeApp"]),
        .library(name: "OfftypeCore", targets: ["OfftypeCore"]),
        .library(name: "LearningEngine", targets: ["LearningEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // FluidAudio (Parakeet TDT v2, CoreML/ANE) is added by the Transcription
        // implementation step once its product name/version are pinned.
    ],
    targets: [
        // MARK: - Pure logic (no OS permissions; fully testable)
        .target(name: "OfftypeCore"),
        .target(name: "LearningEngine", dependencies: ["OfftypeCore"]),
        .target(
            name: "Persistence",
            dependencies: ["OfftypeCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "Eval", dependencies: ["OfftypeCore", "LearningEngine", "Persistence"]),
        .target(name: "Telemetry", dependencies: ["OfftypeCore", "Persistence"]),

        // MARK: - OS glue
        .target(name: "AudioCapture", dependencies: ["OfftypeCore"]),
        .target(name: "Hotkey", dependencies: ["OfftypeCore"]),
        .target(name: "Injection", dependencies: ["OfftypeCore"]),
        .target(name: "Transcription", dependencies: ["OfftypeCore"]),
        .target(name: "Cleanup", dependencies: ["OfftypeCore"]),
        .target(name: "SecureStore", dependencies: ["OfftypeCore"]),

        // MARK: - UI
        .target(name: "HUD", dependencies: ["OfftypeCore"]),

        // MARK: - T2 (prize tier; gracefully degrading)
        .target(name: "ScreenContext", dependencies: ["OfftypeCore"]),
        .target(name: "ComputerUse", dependencies: ["OfftypeCore", "Injection", "ScreenContext", "SecureStore"]),

        // MARK: - App
        .executableTarget(
            name: "OfftypeApp",
            dependencies: [
                "OfftypeCore", "LearningEngine", "Persistence", "Eval", "Telemetry",
                "AudioCapture", "Hotkey", "Injection", "Transcription", "Cleanup",
                "SecureStore", "HUD", "ScreenContext", "ComputerUse",
            ]
        ),

        // MARK: - Tests
        .testTarget(name: "LearningEngineTests", dependencies: ["LearningEngine", "OfftypeCore"]),
        .testTarget(name: "EvalTests", dependencies: ["Eval", "LearningEngine", "OfftypeCore"]),
        .testTarget(name: "InjectionTests", dependencies: ["Injection", "OfftypeCore"]),
        .testTarget(name: "SafetyGateTests", dependencies: ["ComputerUse", "OfftypeCore"]),
        .testTarget(name: "CoordinateMapperTests", dependencies: ["ComputerUse", "OfftypeCore"]),
    ]
)
