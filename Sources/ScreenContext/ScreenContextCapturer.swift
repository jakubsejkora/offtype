@preconcurrency import AppKit
import CoreGraphics
import Foundation
import ImageIO
import NaturalLanguage
import OfftypeCore
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

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
    public var windows: [ScreenWindowInfo]
    public var displayCaptures: [ScreenDisplayCapture]

    public init(
        frontmostApp: String? = nil,
        runningApps: [String] = [],
        windowSummaries: [String] = [],
        windows: [ScreenWindowInfo] = [],
        displayCaptures: [ScreenDisplayCapture] = []
    ) {
        self.frontmostApp = frontmostApp
        self.runningApps = runningApps
        self.windowSummaries = windowSummaries
        self.windows = windows
        self.displayCaptures = displayCaptures
    }
}

public struct ScreenWindowInfo: Sendable, Equatable {
    public var appName: String
    public var title: String
    public var frame: CGRect
    public var layer: Int

    public init(appName: String, title: String, frame: CGRect, layer: Int) {
        self.appName = appName
        self.title = title
        self.frame = frame
        self.layer = layer
    }

    public var summary: String {
        title.isEmpty ? appName : "\(appName) — \(title)"
    }
}

public struct ScreenDisplayCapture: @unchecked Sendable {
    public var displayID: CGDirectDisplayID
    public var frame: CGRect
    public var backingScale: Double
    public var fullResolutionImage: CGImage
    public var modelImageData: Data
    public var modelImageContentType: String
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(
        displayID: CGDirectDisplayID,
        frame: CGRect,
        backingScale: Double,
        fullResolutionImage: CGImage,
        modelImageData: Data,
        modelImageContentType: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.displayID = displayID
        self.frame = frame
        self.backingScale = backingScale
        self.fullResolutionImage = fullResolutionImage
        self.modelImageData = modelImageData
        self.modelImageContentType = modelImageContentType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public final class ScreenContextCapturer: @unchecked Sendable {
    private let modelMaxWidth: Int

    public init(modelMaxWidth: Int = 1_280) {
        self.modelMaxWidth = modelMaxWidth
    }

    /// Graceful wrapper for call sites that should degrade instead of failing.
    public func captureContextBundle() async -> ScreenContextBundle {
        do {
            return try await captureContextBundleOrThrow()
        } catch {
            Log.screen.error("Screen context capture failed: \(String(describing: error), privacy: .public)")
            return Self.workspaceOnlyBundle()
        }
    }

    public func captureContextBundleOrThrow() async throws -> ScreenContextBundle {
        guard Self.ensureScreenCapturePermission() else {
            throw OfftypeError.permissionDenied("Screen Recording permission is required for screen awareness.")
        }

        let content = try await SCShareableContent.current
        let windows = Self.windowInfos(from: content.windows)
        let runningApps = Self.runningAppNames(from: content)
        let displayCaptures = try await captureDisplays(from: content)

        return ScreenContextBundle(
            frontmostApp: NSWorkspace.shared.frontmostApplication?.localizedName,
            runningApps: runningApps,
            windowSummaries: windows.map(\.summary),
            windows: windows,
            displayCaptures: displayCaptures
        )
    }

    /// Returns proper nouns found on screen via OCR, for the personal dictionary.
    public func harvestProperNouns() async -> [DictionaryEntry] {
        do {
            let bundle = try await captureContextBundleOrThrow()
            let text = try await recognizedText(from: bundle.displayCaptures.map(\.fullResolutionImage))
            let terms = Self.extractProperNouns(from: text)
            return terms.map { DictionaryEntry(term: $0, weight: 1.0, locale: "en_US", source: .ocr) }
        } catch {
            Log.screen.error("OCR harvest failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}

private extension ScreenContextCapturer {
    static func ensureScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        Log.screen.info("Requesting Screen Recording permission")
        return CGRequestScreenCaptureAccess()
    }

    static func workspaceOnlyBundle() -> ScreenContextBundle {
        let apps = NSWorkspace.shared.runningApplications
            .compactMap(\.localizedName)
            .uniqued()
            .sorted()

        return ScreenContextBundle(
            frontmostApp: NSWorkspace.shared.frontmostApplication?.localizedName,
            runningApps: apps
        )
    }

    static func runningAppNames(from content: SCShareableContent) -> [String] {
        let screenCaptureKitApps = content.applications.map(\.applicationName)
        let workspaceApps = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        return (screenCaptureKitApps + workspaceApps)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniqued()
            .sorted()
    }

    static func windowInfos(from windows: [SCWindow]) -> [ScreenWindowInfo] {
        windows
            .filter(\.isOnScreen)
            .sorted { lhs, rhs in
                if lhs.windowLayer == rhs.windowLayer {
                    return lhs.frame.minY < rhs.frame.minY
                }
                return lhs.windowLayer < rhs.windowLayer
            }
            .map { window in
                ScreenWindowInfo(
                    appName: window.owningApplication?.applicationName ?? "Unknown",
                    title: window.title ?? "",
                    frame: window.frame,
                    layer: window.windowLayer
                )
            }
    }

    func captureDisplays(from content: SCShareableContent) async throws -> [ScreenDisplayCapture] {
        var captures: [ScreenDisplayCapture] = []
        captures.reserveCapacity(content.displays.count)

        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            filter.includeMenuBar = true
            let scale = max(Double(filter.pointPixelScale), 1.0)
            let width = max(1, Int((Double(display.frame.width) * scale).rounded()))
            let height = max(1, Int((Double(display.frame.height) * scale).rounded()))

            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.captureResolution = .best
            configuration.captureDynamicRange = .SDR

            let image = try await Self.captureImage(filter: filter, configuration: configuration)
            let modelImageData = try Self.downscaledImageData(from: image, maxWidth: modelMaxWidth)

            captures.append(
                ScreenDisplayCapture(
                    displayID: display.displayID,
                    frame: display.frame,
                    backingScale: scale,
                    fullResolutionImage: image,
                    modelImageData: modelImageData,
                    modelImageContentType: UTType.jpeg.preferredMIMEType ?? "image/jpeg",
                    pixelWidth: image.width,
                    pixelHeight: image.height
                )
            )
        }

        return captures
    }

    static func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: OfftypeError.permissionDenied("ScreenCaptureKit returned no image."))
                }
            }
        }
    }

    static func downscaledImageData(from image: CGImage, maxWidth: Int) throws -> Data {
        let targetWidth = min(maxWidth, image.width)
        let ratio = Double(targetWidth) / Double(max(image.width, 1))
        let targetHeight = max(1, Int((Double(image.height) * ratio).rounded()))

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw OfftypeError.permissionDenied("Unable to allocate screenshot downscale buffer.")
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let scaledImage = context.makeImage() else {
            throw OfftypeError.permissionDenied("Unable to create model screenshot.")
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw OfftypeError.permissionDenied("Unable to encode model screenshot.")
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.82]
        CGImageDestinationAddImage(destination, scaledImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw OfftypeError.permissionDenied("Unable to finalize model screenshot.")
        }

        return data as Data
    }

    func recognizedText(from images: [CGImage]) async throws -> String {
        var lines: [String] = []

        for image in images {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true

            let observations = try await request.perform(on: image)
            lines += observations.compactMap { observation in
                if let candidate = observation.topCandidates(1).first {
                    return candidate.string
                }
                return observation.transcript
            }
        }

        return lines.joined(separator: "\n")
    }

    static func extractProperNouns(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var terms: [String] = []
        let options: NLTagger.Options = [.joinNames, .omitWhitespace, .omitPunctuation]
        let validTags: Set<NLTag> = [.personalName, .placeName, .organizationName]

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            guard let tag, validTags.contains(tag) else { return true }
            let term = String(text[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}\"'"))
            if term.count > 1 {
                terms.append(term)
            }
            return true
        }

        return terms.uniqued()
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        output.reserveCapacity(count)

        for value in self {
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(value)
        }

        return output
    }
}
