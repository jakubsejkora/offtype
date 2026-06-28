import Foundation
import OfftypeCore

// AGENT(ScreenContext): implement WHOLE-screen capture with ScreenCaptureKit
// (SCShareableContent → iterate content.displays → SCContentFilter(display:
// excludingWindows:[]) → SCScreenshotManager.captureImage). Full-res for OCR,
// downscaled (~1280px) for the Gemini path. Build a "what's running" context
// bundle from SCShareableContent windows + NSWorkspace.runningApplications +
// frontmost app. OCR via Vision RecognizeTextRequest(.accurate) → NLTagger
// (.nameType, .joinNames) NER → DictionaryEntry(source: .ocr). Requires Screen
// Recording; preflight with CGPreflightScreenCaptureAccess. Capture on-demand,
// debounced — never a continuous SCStream. Do NOT use the obsoleted
// CGWindowListCreateImage / CGDisplayCreateImage (compile error on macOS 15+).

/// A snapshot of what the user sees + what's running, for the Gemini agent.
public struct ScreenContextBundle: Sendable {
    public var frontmostApp: String?
    public var runningApps: [String]
    public var windowSummaries: [String]   // "AppName — Window Title"
    public init(frontmostApp: String? = nil, runningApps: [String] = [], windowSummaries: [String] = []) {
        self.frontmostApp = frontmostApp
        self.runningApps = runningApps
        self.windowSummaries = windowSummaries
    }
}

/// Placeholder so the package compiles before implementation.
public final class ScreenContextCapturer: @unchecked Sendable {
    public init() {}
    public func captureContextBundle() async -> ScreenContextBundle { ScreenContextBundle() }
    /// Returns proper nouns found on screen via OCR, for the personal dictionary.
    public func harvestProperNouns() async -> [DictionaryEntry] { [] }
}
