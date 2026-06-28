import CoreGraphics
import Foundation
import OfftypeCore
@preconcurrency import AppKit
import ScreenContext
import SecureStore

// AGENT(ComputerUse): implement the Gemini 3.5 Flash computer-use loop via the
// Interactions API (REST/URLSession — no Swift SDK). POST /v1beta/interactions
// with tools=[{type:"computer_use", environment:"desktop",
// enable_prompt_injection_detection:true}]; loop with previous_interaction_id +
// function_result(+fresh screenshot). PARSE DEFENSIVELY (steps[] vs outputs[]).
// Execute actions via CGEvent (reuse Injection patterns). Honor
// safety_decision==require_confirmation. Then MacroCrystallizer records a verified
// action sequence as a deterministic macro replayed with ZERO Gemini calls.

/// Pure coordinate math: Gemini emits normalized 0...1000 coords relative to the
/// screenshot (in PIXELS). Convert to a global CGEvent point (Quartz top-left),
/// accounting for Retina backing scale and the display's global origin. This is
/// the single most error-prone step, so it's isolated and unit-tested.
public enum CoordinateMapper {
    public static func toGlobalPoint(
        normX: Double,
        normY: Double,
        imagePixelWidth: Double,
        imagePixelHeight: Double,
        backingScale: Double,
        displayOrigin: CGPoint
    ) -> CGPoint {
        precondition(backingScale > 0, "backingScale must be > 0")
        let pxX = normX / 1000.0 * imagePixelWidth
        let pxY = normY / 1000.0 * imagePixelHeight
        return CGPoint(x: pxX / backingScale + displayOrigin.x,
                       y: pxY / backingScale + displayOrigin.y)
    }
}

/// Gates every proposed action: honors Gemini's require_confirmation and our own
/// app/action denylist; supports a hard kill-switch.
public struct SafetyGate: Sendable {
    public enum Decision: Sendable, Equatable {
        case allow
        case requireConfirmation(reason: String)
        case block(reason: String)
    }

    /// Apps we never drive automatically.
    public static let deniedAppKeywords = [
        "system settings", "system preferences", "keychain access",
        "terminal", "iterm", "1password", "bitwarden",
    ]
    /// Action labels that always require explicit human confirmation.
    public static let confirmKeywords = ["send", "pay", "delete", "confirm purchase", "transfer", "buy"]

    public init() {}

    public func evaluate(actionLabel: String, targetApp: String?) -> Decision {
        let app = (targetApp ?? "").lowercased()
        if Self.deniedAppKeywords.contains(where: app.contains) {
            return .block(reason: "App is on the denylist: \(targetApp ?? "?")")
        }
        let label = actionLabel.lowercased()
        if Self.confirmKeywords.contains(where: label.contains) {
            return .requireConfirmation(reason: "Sensitive action: \(actionLabel)")
        }
        return .allow
    }
}

// NOTE(OfftypeCore): OfftypeError intentionally has only shared cases today, so
// module-local parse/execution failures live in ComputerUseError.
public enum ComputerUseError: Error, Sendable, Equatable {
    case invalidEndpoint
    case invalidResponse(String)
    case httpStatus(Int)
    case unknownAction(String)
    case missingCoordinate(String)
    case keyNotSupported(String)
    case cancelled
    case noPendingConfirmation
}

public enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): String(value)
        case .bool(let value): String(value)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let value):
            value
        case .string(let value):
            Double(value)
        default:
            nil
        }
    }

    public var intValue: Int? {
        guard let doubleValue else { return nil }
        return Int(doubleValue)
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value):
            value
        case .string(let value):
            Bool(value)
        default:
            nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }
}

public struct ModelSafetyDecision: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case allow
        case requireConfirmation
        case block
        case unknown
    }

    public var kind: Kind
    public var reason: String?

    public init(kind: Kind, reason: String? = nil) {
        self.kind = kind
        self.reason = reason
    }

    public var requiresConfirmation: Bool { kind == .requireConfirmation }
}

public struct GeminiFunctionCall: Sendable, Equatable, Codable {
    public var name: String
    public var args: [String: JSONValue]
    public var safetyDecision: ModelSafetyDecision?

    public init(name: String, args: [String: JSONValue] = [:], safetyDecision: ModelSafetyDecision? = nil) {
        self.name = name
        self.args = args
        self.safetyDecision = safetyDecision
    }
}

public struct GeminiInteractionResponse: Sendable, Equatable, Codable {
    public var interactionID: String?
    public var functionCalls: [GeminiFunctionCall]

    public init(interactionID: String? = nil, functionCalls: [GeminiFunctionCall] = []) {
        self.interactionID = interactionID
        self.functionCalls = functionCalls
    }
}

public enum InteractionResponseParser {
    public static func parse(data: Data) throws -> GeminiInteractionResponse {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let object) = root else {
            throw ComputerUseError.invalidResponse("Expected a JSON object response.")
        }

        let interactionID = object.firstString(for: ["id", "interaction_id", "interactionId", "previous_interaction_id"])
        let containers = object["steps"]?.arrayValue
            ?? object["outputs"]?.arrayValue
            ?? object["candidates"]?.arrayValue
            ?? []
        let calls = containers.flatMap { extractFunctionCalls(from: $0) }

        return GeminiInteractionResponse(interactionID: interactionID, functionCalls: calls)
    }

    private static func extractFunctionCalls(from value: JSONValue) -> [GeminiFunctionCall] {
        guard case .object(let object) = value else { return [] }

        var calls: [GeminiFunctionCall] = []
        let type = object.firstString(for: ["type", "kind"])?.normalizedActionToken

        if type == "function_call" || object["function_call"] != nil || object["functionCall"] != nil {
            if let call = parseFunctionCall(from: object) {
                calls.append(call)
            }
        }

        for key in ["steps", "outputs", "parts", "content"] {
            if let nested = object[key]?.arrayValue {
                calls += nested.flatMap { extractFunctionCalls(from: $0) }
            } else if let nestedObject = object[key] {
                calls += extractFunctionCalls(from: nestedObject)
            }
        }

        return calls
    }

    private static func parseFunctionCall(from object: [String: JSONValue]) -> GeminiFunctionCall? {
        let callObject = object["function_call"]?.objectValue
            ?? object["functionCall"]?.objectValue
            ?? object
        guard let name = callObject.firstString(for: ["name", "action", "function_name", "functionName"]) else {
            return nil
        }

        let args = callObject["args"]?.objectValue
            ?? callObject["arguments"]?.objectValue
            ?? callObject["parameters"]?.objectValue
            ?? [:]
        let safetyValue = callObject["safety_decision"]
            ?? callObject["safetyDecision"]
            ?? object["safety_decision"]
            ?? object["safetyDecision"]
            ?? args["safety_decision"]
            ?? args["safetyDecision"]

        return GeminiFunctionCall(
            name: name,
            args: args,
            safetyDecision: parseSafetyDecision(safetyValue)
        )
    }

    private static func parseSafetyDecision(_ value: JSONValue?) -> ModelSafetyDecision? {
        guard let value else { return nil }
        let rawDecision: String?
        let reason: String?

        if let object = value.objectValue {
            rawDecision = object.firstString(for: ["decision", "kind", "status", "action"])
            reason = object.firstString(for: ["reason", "message", "explanation"])
        } else {
            rawDecision = value.stringValue
            reason = nil
        }

        guard let rawDecision else { return nil }
        let normalized = rawDecision.normalizedActionToken
        let kind: ModelSafetyDecision.Kind
        if normalized.contains("require") || normalized.contains("confirmation") || normalized.contains("ack") {
            kind = .requireConfirmation
        } else if normalized.contains("block") || normalized.contains("deny") {
            kind = .block
        } else if normalized.contains("allow") || normalized.contains("safe") {
            kind = .allow
        } else {
            kind = .unknown
        }
        return ModelSafetyDecision(kind: kind, reason: reason)
    }
}

public enum ComputerUseActionKind: String, Sendable, Equatable, Codable {
    case click
    case doubleClick = "double_click"
    case rightClick = "right_click"
    case move
    case mouseDown = "mouse_down"
    case mouseUp = "mouse_up"
    case dragAndDrop = "drag_and_drop"
    case type
    case pressKey = "press_key"
    case hotkey
    case scroll
    case wait

    public init?(modelName: String) {
        switch modelName.normalizedActionToken {
        case "click", "left_click", "click_at":
            self = .click
        case "double_click", "doubleclick":
            self = .doubleClick
        case "right_click", "secondary_click", "context_click":
            self = .rightClick
        case "move", "move_mouse", "mouse_move":
            self = .move
        case "mouse_down", "mousedown":
            self = .mouseDown
        case "mouse_up", "mouseup":
            self = .mouseUp
        case "drag_and_drop", "drag", "drag_drop":
            self = .dragAndDrop
        case "type", "type_text", "input_text":
            self = .type
        case "press_key", "keypress", "key_press":
            self = .pressKey
        case "hotkey", "shortcut":
            self = .hotkey
        case "scroll", "mouse_wheel":
            self = .scroll
        case "wait", "pause":
            self = .wait
        default:
            return nil
        }
    }
}

public struct ComputerUseAction: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var kind: ComputerUseActionKind
    public var x: Double?
    public var y: Double?
    public var endX: Double?
    public var endY: Double?
    public var text: String?
    public var key: String?
    public var keys: [String]
    public var scrollDeltaX: Double?
    public var scrollDeltaY: Double?
    public var durationMS: Double?
    public var displayIndex: Int
    public var intent: String?

    public init(
        id: UUID = UUID(),
        kind: ComputerUseActionKind,
        x: Double? = nil,
        y: Double? = nil,
        endX: Double? = nil,
        endY: Double? = nil,
        text: String? = nil,
        key: String? = nil,
        keys: [String] = [],
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil,
        durationMS: Double? = nil,
        displayIndex: Int = 0,
        intent: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.endX = endX
        self.endY = endY
        self.text = text
        self.key = key
        self.keys = keys
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.durationMS = durationMS
        self.displayIndex = displayIndex
        self.intent = intent
    }

    public init(functionCall: GeminiFunctionCall) throws {
        guard let kind = ComputerUseActionKind(modelName: functionCall.name) else {
            throw ComputerUseError.unknownAction(functionCall.name)
        }

        let args = functionCall.args
        self.init(
            kind: kind,
            x: args.firstDouble(for: ["x", "norm_x", "normX"]),
            y: args.firstDouble(for: ["y", "norm_y", "normY"]),
            endX: args.firstDouble(for: ["end_x", "endX", "x2", "to_x", "toX"]),
            endY: args.firstDouble(for: ["end_y", "endY", "y2", "to_y", "toY"]),
            text: args.firstString(for: ["text", "value", "content"]),
            key: args.firstString(for: ["key", "name"]),
            keys: args.firstStringArray(for: ["keys", "shortcut", "combo"]),
            scrollDeltaX: args.firstDouble(for: ["dx", "delta_x", "deltaX", "scroll_x", "scrollX"]),
            scrollDeltaY: args.firstDouble(for: ["dy", "delta_y", "deltaY", "scroll_y", "scrollY"]),
            durationMS: args.firstDouble(for: ["duration_ms", "durationMS", "duration", "wait_ms", "waitMS"]),
            displayIndex: args.firstInt(for: ["display_index", "displayIndex", "screen", "screen_index"]) ?? 0,
            intent: args.firstString(for: ["intent", "description", "label"])
        )
    }

    public var actionLabel: String {
        let shortcut = keys.isEmpty ? nil : keys.joined(separator: "+")
        return intent ?? text ?? key ?? shortcut ?? kind.rawValue
    }
}

public struct InteractionScreenshot: Sendable, Equatable, Codable {
    public var data: Data
    public var mimeType: String
    public var displayID: CGDirectDisplayID
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var backingScale: Double
    public var displayOriginX: Double
    public var displayOriginY: Double

    public init(displayCapture: ScreenDisplayCapture) {
        self.data = displayCapture.modelImageData
        self.mimeType = displayCapture.modelImageContentType
        self.displayID = displayCapture.displayID
        self.pixelWidth = displayCapture.pixelWidth
        self.pixelHeight = displayCapture.pixelHeight
        self.backingScale = displayCapture.backingScale
        self.displayOriginX = displayCapture.frame.origin.x
        self.displayOriginY = displayCapture.frame.origin.y
    }
}

public struct ComputerUseFunctionResult: Sendable, Equatable, Codable {
    public var actionName: String
    public var ok: Bool
    public var message: String
    public var safetyAcknowledgement: Bool

    public init(actionName: String, ok: Bool, message: String, safetyAcknowledgement: Bool = false) {
        self.actionName = actionName
        self.ok = ok
        self.message = message
        self.safetyAcknowledgement = safetyAcknowledgement
    }
}

public struct InteractionRequest: Sendable, Equatable, Codable {
    public var instruction: String
    public var previousInteractionID: String?
    public var screenshots: [InteractionScreenshot]
    public var context: ScreenContextBundleSummary
    public var functionResult: ComputerUseFunctionResult?

    public init(
        instruction: String,
        previousInteractionID: String? = nil,
        screenshots: [InteractionScreenshot],
        context: ScreenContextBundleSummary,
        functionResult: ComputerUseFunctionResult? = nil
    ) {
        self.instruction = instruction
        self.previousInteractionID = previousInteractionID
        self.screenshots = screenshots
        self.context = context
        self.functionResult = functionResult
    }
}

public struct ScreenContextBundleSummary: Sendable, Equatable, Codable {
    public var frontmostApp: String?
    public var runningApps: [String]
    public var windowSummaries: [String]

    public init(bundle: ScreenContextBundle) {
        self.frontmostApp = bundle.frontmostApp
        self.runningApps = bundle.runningApps
        self.windowSummaries = bundle.windowSummaries
    }
}

public protocol ComputerUseProvider: Sendable {
    func send(_ request: InteractionRequest) async throws -> GeminiInteractionResponse
}

public final class GeminiInteractionsClient: ComputerUseProvider, @unchecked Sendable {
    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL

    public init(
        featureFlags: FeatureFlags,
        keychain: KeychainStore = KeychainStore(),
        session: URLSession = .shared
    ) throws {
        guard featureFlags.cloudFeaturesEnabled, featureFlags.computerUseEnabled else {
            throw OfftypeError.cloudDisabled
        }
        guard let apiKey = keychain.get(account: KeychainStore.geminiAPIKeyAccount), !apiKey.isEmpty else {
            throw OfftypeError.missingAPIKey
        }
        guard let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions") else {
            throw ComputerUseError.invalidEndpoint
        }
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
    }

    public func send(_ request: InteractionRequest) async throws -> GeminiInteractionResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try JSONEncoder().encode(GeminiRequestBody(request: request))

        Log.cloud.info("Sending Gemini computer-use interaction")
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ComputerUseError.invalidResponse("Missing HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            Log.cloud.error("Gemini computer-use request failed with HTTP \(httpResponse.statusCode, privacy: .public)")
            throw ComputerUseError.httpStatus(httpResponse.statusCode)
        }

        return try InteractionResponseParser.parse(data: data)
    }
}

public actor MockComputerUseProvider: ComputerUseProvider {
    private var scriptedActions: [ComputerUseAction]
    private var index: Int = 0

    public init(scriptedActions: [ComputerUseAction] = [
        ComputerUseAction(kind: .move, x: 500, y: 500, intent: "move to target"),
        ComputerUseAction(kind: .click, x: 500, y: 500, intent: "click target"),
    ]) {
        self.scriptedActions = scriptedActions
    }

    public func send(_ request: InteractionRequest) async throws -> GeminiInteractionResponse {
        guard index < scriptedActions.count else {
            return GeminiInteractionResponse(interactionID: request.previousInteractionID ?? "mock-complete", functionCalls: [])
        }
        let action = scriptedActions[index]
        index += 1
        let call = GeminiFunctionCall(name: action.kind.rawValue, args: action.asFunctionArgs())
        return GeminiInteractionResponse(interactionID: "mock-\(index)", functionCalls: [call])
    }
}

public protocol ComputerUseActionExecuting: Sendable {
    func execute(_ action: ComputerUseAction, display: ScreenDisplayCapture?) async throws
    func releaseModifiersAndButtons()
}

public final class CGEventActionExecutor: ComputerUseActionExecuting, @unchecked Sendable {
    public init() {}

    public func execute(_ action: ComputerUseAction, display: ScreenDisplayCapture?) async throws {
        switch action.kind {
        case .click:
            try click(action, display: display, mouseButton: .left, downType: .leftMouseDown, upType: .leftMouseUp, clickCount: 1)
        case .doubleClick:
            try click(action, display: display, mouseButton: .left, downType: .leftMouseDown, upType: .leftMouseUp, clickCount: 2)
        case .rightClick:
            try click(action, display: display, mouseButton: .right, downType: .rightMouseDown, upType: .rightMouseUp, clickCount: 1)
        case .move:
            let point = try point(for: action, display: display)
            postMouse(type: .mouseMoved, point: point, button: .left)
        case .mouseDown:
            let point = try point(for: action, display: display)
            postMouse(type: .leftMouseDown, point: point, button: .left)
        case .mouseUp:
            let point = try point(for: action, display: display)
            postMouse(type: .leftMouseUp, point: point, button: .left)
        case .dragAndDrop:
            try await drag(action, display: display)
        case .type:
            guard let text = action.text else { throw ComputerUseError.invalidResponse("Missing text for type action.") }
            type(text)
        case .pressKey:
            let key = action.key ?? action.keys.first
            guard let key else { throw ComputerUseError.invalidResponse("Missing key for press_key action.") }
            try pressKey(key, flags: [])
        case .hotkey:
            try hotkey(action.keys.isEmpty ? action.key.map { [$0] } ?? [] : action.keys)
        case .scroll:
            scroll(deltaX: action.scrollDeltaX ?? 0, deltaY: action.scrollDeltaY ?? 0)
        case .wait:
            let ms = max(0, action.durationMS ?? 500)
            try await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
        }
    }

    public func releaseModifiersAndButtons() {
        for modifier in KeyMap.modifierKeys.values {
            postKeyCode(modifier.keyCode, keyDown: false, flags: [])
        }
        let location = CGEvent(source: nil)?.location ?? .zero
        postMouse(type: .leftMouseUp, point: location, button: .left)
        postMouse(type: .rightMouseUp, point: location, button: .right)
    }
}

public struct PendingComputerUseConfirmation: Sendable, Equatable {
    public var action: ComputerUseAction
    public var reason: String

    public init(action: ComputerUseAction, reason: String) {
        self.action = action
        self.reason = reason
    }
}

public enum ComputerUseRunState: Sendable, Equatable {
    case completed([ComputerUseAction])
    case pendingConfirmation(PendingComputerUseConfirmation)
    case blocked(String)
    case cancelled
    case unavailable(String)
    case failed(String)
}

public actor AgentLoop {
    private let provider: any ComputerUseProvider
    private let executor: any ComputerUseActionExecuting
    private let screenCapturer: ScreenContextCapturer
    private let safetyGate: SafetyGate
    private var cancelled = false
    private var previousInteractionID: String?
    private var pendingConfirmation: PendingComputerUseConfirmation?
    private var verifiedActions: [ComputerUseAction] = []
    private var lastInstruction = ""

    public init(
        provider: any ComputerUseProvider,
        executor: any ComputerUseActionExecuting = CGEventActionExecutor(),
        screenCapturer: ScreenContextCapturer = ScreenContextCapturer(),
        safetyGate: SafetyGate = SafetyGate()
    ) {
        self.provider = provider
        self.executor = executor
        self.screenCapturer = screenCapturer
        self.safetyGate = safetyGate
    }

    public func run(instruction: String, maxTurns: Int = 8) async -> ComputerUseRunState {
        cancelled = false
        previousInteractionID = nil
        pendingConfirmation = nil
        verifiedActions = []
        lastInstruction = instruction
        return await continueLoop(maxTurns: maxTurns, functionResult: nil)
    }

    public func acknowledgeSafety(maxTurns: Int = 8) async -> ComputerUseRunState {
        guard let pendingConfirmation else {
            return .failed(String(describing: ComputerUseError.noPendingConfirmation))
        }
        self.pendingConfirmation = nil

        do {
            let display = await displayForAction(pendingConfirmation.action)
            try await executor.execute(pendingConfirmation.action, display: display)
            verifiedActions.append(pendingConfirmation.action)
            let result = ComputerUseFunctionResult(
                actionName: pendingConfirmation.action.kind.rawValue,
                ok: true,
                message: "Action executed after user confirmation.",
                safetyAcknowledgement: true
            )
            return await continueLoop(maxTurns: maxTurns, functionResult: result)
        } catch {
            return .failed(String(describing: error))
        }
    }

    public func cancel() {
        cancelled = true
        executor.releaseModifiersAndButtons()
    }

    private func continueLoop(maxTurns: Int, functionResult: ComputerUseFunctionResult?) async -> ComputerUseRunState {
        var nextFunctionResult = functionResult

        for _ in 0..<maxTurns {
            if cancelled {
                executor.releaseModifiersAndButtons()
                return .cancelled
            }

            let bundle = await screenCapturer.captureContextBundle()
            let request = InteractionRequest(
                instruction: lastInstruction,
                previousInteractionID: previousInteractionID,
                screenshots: bundle.displayCaptures.map(InteractionScreenshot.init(displayCapture:)),
                context: ScreenContextBundleSummary(bundle: bundle),
                functionResult: nextFunctionResult
            )

            do {
                let response = try await provider.send(request)
                previousInteractionID = response.interactionID ?? previousInteractionID

                guard !response.functionCalls.isEmpty else {
                    return .completed(verifiedActions)
                }

                for call in response.functionCalls {
                    let action = try ComputerUseAction(functionCall: call)
                    let targetApp = bundle.frontmostApp

                    if call.safetyDecision?.kind == .block {
                        return .blocked(call.safetyDecision?.reason ?? "Model safety blocked the action.")
                    }
                    if call.safetyDecision?.requiresConfirmation == true {
                        let pending = PendingComputerUseConfirmation(
                            action: action,
                            reason: call.safetyDecision?.reason ?? "Model requested confirmation."
                        )
                        pendingConfirmation = pending
                        return .pendingConfirmation(pending)
                    }

                    switch safetyGate.evaluate(actionLabel: action.actionLabel, targetApp: targetApp) {
                    case .allow:
                        let display = selectDisplay(for: action, from: bundle)
                        try await executor.execute(action, display: display)
                        verifiedActions.append(action)
                        nextFunctionResult = ComputerUseFunctionResult(
                            actionName: action.kind.rawValue,
                            ok: true,
                            message: "Action executed."
                        )
                    case .requireConfirmation(let reason):
                        let pending = PendingComputerUseConfirmation(action: action, reason: reason)
                        pendingConfirmation = pending
                        return .pendingConfirmation(pending)
                    case .block(let reason):
                        return .blocked(reason)
                    }
                }
            } catch is CancellationError {
                executor.releaseModifiersAndButtons()
                return .cancelled
            } catch {
                Log.cloud.error("Computer-use loop failed: \(String(describing: error), privacy: .public)")
                return .failed(String(describing: error))
            }
        }

        return .completed(verifiedActions)
    }

    private func displayForAction(_ action: ComputerUseAction) async -> ScreenDisplayCapture? {
        let bundle = await screenCapturer.captureContextBundle()
        return selectDisplay(for: action, from: bundle)
    }

    private func selectDisplay(for action: ComputerUseAction, from bundle: ScreenContextBundle) -> ScreenDisplayCapture? {
        guard !bundle.displayCaptures.isEmpty else { return nil }
        if bundle.displayCaptures.indices.contains(action.displayIndex) {
            return bundle.displayCaptures[action.displayIndex]
        }
        return bundle.displayCaptures[0]
    }
}

public final class ComputerUseAgent: @unchecked Sendable {
    private let loop: AgentLoop

    public init(
        featureFlags: FeatureFlags = .demoDefault,
        keychain: KeychainStore = KeychainStore(),
        screenCapturer: ScreenContextCapturer = ScreenContextCapturer()
    ) {
        let provider: any ComputerUseProvider
        if featureFlags.cloudFeaturesEnabled,
           featureFlags.computerUseEnabled,
           let gemini = try? GeminiInteractionsClient(featureFlags: featureFlags, keychain: keychain) {
            provider = gemini
        } else {
            provider = MockComputerUseProvider()
        }
        self.loop = AgentLoop(provider: provider, screenCapturer: screenCapturer)
    }

    public init(loop: AgentLoop) {
        self.loop = loop
    }

    public func run(_ instruction: String, maxTurns: Int = 8) async -> ComputerUseRunState {
        await loop.run(instruction: instruction, maxTurns: maxTurns)
    }

    public func acknowledgeSafety(maxTurns: Int = 8) async -> ComputerUseRunState {
        await loop.acknowledgeSafety(maxTurns: maxTurns)
    }

    public func cancel() async {
        await loop.cancel()
    }
}

public struct MacroSlot: Sendable, Equatable, Codable {
    public var name: String
    public var placeholder: String

    public init(name: String, placeholder: String? = nil) {
        self.name = name
        self.placeholder = placeholder ?? "{{\(name)}}"
    }
}

public struct ComputerUseMacro: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var slotTemplate: String
    public var slots: [MacroSlot]
    public var actions: [ComputerUseAction]

    public init(
        id: UUID = UUID(),
        name: String,
        slotTemplate: String,
        slots: [MacroSlot],
        actions: [ComputerUseAction]
    ) {
        self.id = id
        self.name = name
        self.slotTemplate = slotTemplate
        self.slots = slots
        self.actions = actions
    }
}

public struct MacroCrystallizer: Sendable {
    public init() {}

    public func recordVerifiedSequence(
        name: String,
        slotTemplate: String,
        slots: [MacroSlot],
        actions: [ComputerUseAction]
    ) -> ComputerUseMacro {
        ComputerUseMacro(name: name, slotTemplate: slotTemplate, slots: slots, actions: actions)
    }

    public func fillSlots(in macro: ComputerUseMacro, values: [String: String]) -> [ComputerUseAction] {
        macro.actions.map { action in
            var filled = action
            filled.text = fill(action.text, slots: macro.slots, values: values)
            filled.key = fill(action.key, slots: macro.slots, values: values)
            filled.keys = action.keys.map { fill($0, slots: macro.slots, values: values) ?? $0 }
            filled.intent = fill(action.intent, slots: macro.slots, values: values)
            return filled
        }
    }

    public func replay(
        _ macro: ComputerUseMacro,
        values: [String: String],
        executor: any ComputerUseActionExecuting,
        display: ScreenDisplayCapture? = nil
    ) async throws -> [ComputerUseAction] {
        let actions = fillSlots(in: macro, values: values)
        for action in actions {
            try await executor.execute(action, display: display)
        }
        return actions
    }

    private func fill(_ value: String?, slots: [MacroSlot], values: [String: String]) -> String? {
        guard var value else { return nil }
        for slot in slots {
            if let replacement = values[slot.name] {
                value = value.replacingOccurrences(of: slot.placeholder, with: replacement)
            }
        }
        return value
    }
}

private struct GeminiRequestBody: Encodable {
    var model = "gemini-3.5-flash"
    var input: Input
    var previousInteractionID: String?
    var tools: [Tool]
    var screenshots: [Screenshot]
    var screenContext: ScreenContextBundleSummary
    var functionResult: ComputerUseFunctionResult?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case previousInteractionID = "previous_interaction_id"
        case tools
        case screenshots
        case screenContext = "screen_context"
        case functionResult = "function_result"
    }

    init(request: InteractionRequest) {
        self.input = Input(text: request.instruction)
        self.previousInteractionID = request.previousInteractionID
        self.tools = [Tool()]
        self.screenshots = request.screenshots.map(Screenshot.init)
        self.screenContext = request.context
        self.functionResult = request.functionResult
    }

    struct Input: Encodable {
        var text: String
    }

    struct Tool: Encodable {
        var type = "computer_use"
        var environment = "desktop"
        var enablePromptInjectionDetection = true

        enum CodingKeys: String, CodingKey {
            case type
            case environment
            case enablePromptInjectionDetection = "enable_prompt_injection_detection"
        }
    }

    struct Screenshot: Encodable {
        var mimeType: String
        var data: String
        var displayID: CGDirectDisplayID
        var pixelWidth: Int
        var pixelHeight: Int
        var backingScale: Double
        var displayOriginX: Double
        var displayOriginY: Double

        enum CodingKeys: String, CodingKey {
            case mimeType = "mime_type"
            case data
            case displayID = "display_id"
            case pixelWidth = "pixel_width"
            case pixelHeight = "pixel_height"
            case backingScale = "backing_scale"
            case displayOriginX = "display_origin_x"
            case displayOriginY = "display_origin_y"
        }

        init(_ screenshot: InteractionScreenshot) {
            self.mimeType = screenshot.mimeType
            self.data = screenshot.data.base64EncodedString()
            self.displayID = screenshot.displayID
            self.pixelWidth = screenshot.pixelWidth
            self.pixelHeight = screenshot.pixelHeight
            self.backingScale = screenshot.backingScale
            self.displayOriginX = screenshot.displayOriginX
            self.displayOriginY = screenshot.displayOriginY
        }
    }
}

private extension CGEventActionExecutor {
    func click(
        _ action: ComputerUseAction,
        display: ScreenDisplayCapture?,
        mouseButton: CGMouseButton,
        downType: CGEventType,
        upType: CGEventType,
        clickCount: Int64
    ) throws {
        let point = try point(for: action, display: display)
        postMouse(type: downType, point: point, button: mouseButton, clickCount: clickCount)
        postMouse(type: upType, point: point, button: mouseButton, clickCount: clickCount)
        if clickCount == 2 {
            postMouse(type: downType, point: point, button: mouseButton, clickCount: clickCount)
            postMouse(type: upType, point: point, button: mouseButton, clickCount: clickCount)
        }
    }

    func drag(_ action: ComputerUseAction, display: ScreenDisplayCapture?) async throws {
        let start = try point(for: action, display: display)
        guard let endX = action.endX, let endY = action.endY else {
            throw ComputerUseError.missingCoordinate("drag_and_drop requires endX/endY.")
        }
        let end = try point(normX: endX, normY: endY, display: display)
        postMouse(type: .mouseMoved, point: start, button: .left)
        postMouse(type: .leftMouseDown, point: start, button: .left)

        for step in 1...8 {
            let t = CGFloat(step) / 8.0
            let point = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            postMouse(type: .leftMouseDragged, point: point, button: .left)
            try await Task.sleep(nanoseconds: 8_000_000)
        }

        postMouse(type: .leftMouseUp, point: end, button: .left)
    }

    func point(for action: ComputerUseAction, display: ScreenDisplayCapture?) throws -> CGPoint {
        guard let x = action.x, let y = action.y else {
            throw ComputerUseError.missingCoordinate("\(action.kind.rawValue) requires x/y.")
        }
        return try point(normX: x, normY: y, display: display)
    }

    func point(normX: Double, normY: Double, display: ScreenDisplayCapture?) throws -> CGPoint {
        guard let display else {
            throw ComputerUseError.missingCoordinate("No screenshot display metadata is available.")
        }
        return CoordinateMapper.toGlobalPoint(
            normX: normX,
            normY: normY,
            imagePixelWidth: Double(display.pixelWidth),
            imagePixelHeight: Double(display.pixelHeight),
            backingScale: display.backingScale,
            displayOrigin: display.frame.origin
        )
    }

    func type(_ text: String) {
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
            up?.post(tap: .cghidEventTap)
        }
    }

    func pressKey(_ key: String, flags: CGEventFlags) throws {
        guard let keyCode = KeyMap.keyCode(for: key) else {
            throw ComputerUseError.keyNotSupported(key)
        }
        postKeyCode(keyCode, keyDown: true, flags: flags)
        postKeyCode(keyCode, keyDown: false, flags: flags)
    }

    func hotkey(_ keys: [String]) throws {
        guard !keys.isEmpty else {
            throw ComputerUseError.keyNotSupported("empty hotkey")
        }

        let modifiers = keys.compactMap { KeyMap.modifier(for: $0) }
        let normalKeys = keys.filter { KeyMap.modifier(for: $0) == nil }
        guard let key = normalKeys.last, let keyCode = KeyMap.keyCode(for: key) else {
            throw ComputerUseError.keyNotSupported(keys.joined(separator: "+"))
        }

        var flags: CGEventFlags = []
        for modifier in modifiers {
            flags.insert(modifier.flag)
            postKeyCode(modifier.keyCode, keyDown: true, flags: flags)
        }

        postKeyCode(keyCode, keyDown: true, flags: flags)
        postKeyCode(keyCode, keyDown: false, flags: flags)

        for modifier in modifiers.reversed() {
            flags.remove(modifier.flag)
            postKeyCode(modifier.keyCode, keyDown: false, flags: flags)
        }
    }

    func scroll(deltaX: Double, deltaY: Double) {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        )
        event?.post(tap: .cghidEventTap)
    }

    func postMouse(type: CGEventType, point: CGPoint, button: CGMouseButton, clickCount: Int64 = 1) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event?.post(tap: .cghidEventTap)
    }

    func postKeyCode(_ keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

private enum KeyMap {
    struct Modifier {
        var keyCode: CGKeyCode
        var flag: CGEventFlags
    }

    static let modifierKeys: [String: Modifier] = [
        "cmd": Modifier(keyCode: 55, flag: .maskCommand),
        "command": Modifier(keyCode: 55, flag: .maskCommand),
        "meta": Modifier(keyCode: 55, flag: .maskCommand),
        "shift": Modifier(keyCode: 56, flag: .maskShift),
        "option": Modifier(keyCode: 58, flag: .maskAlternate),
        "alt": Modifier(keyCode: 58, flag: .maskAlternate),
        "control": Modifier(keyCode: 59, flag: .maskControl),
        "ctrl": Modifier(keyCode: 59, flag: .maskControl),
    ]

    private static let keys: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
        "`": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115,
        "end": 119, "page_up": 116, "pageup": 116, "page_down": 121,
        "pagedown": 121, "forward_delete": 117,
    ]

    static func modifier(for key: String) -> Modifier? {
        modifierKeys[key.normalizedActionToken]
    }

    static func keyCode(for key: String) -> CGKeyCode? {
        keys[key.normalizedActionToken]
    }
}

private extension ComputerUseAction {
    func asFunctionArgs() -> [String: JSONValue] {
        var args: [String: JSONValue] = [:]
        if let x { args["x"] = .number(x) }
        if let y { args["y"] = .number(y) }
        if let endX { args["end_x"] = .number(endX) }
        if let endY { args["end_y"] = .number(endY) }
        if let text { args["text"] = .string(text) }
        if let key { args["key"] = .string(key) }
        if !keys.isEmpty { args["keys"] = .array(keys.map(JSONValue.string)) }
        if let scrollDeltaX { args["dx"] = .number(scrollDeltaX) }
        if let scrollDeltaY { args["dy"] = .number(scrollDeltaY) }
        if let durationMS { args["duration_ms"] = .number(durationMS) }
        if displayIndex != 0 { args["display_index"] = .number(Double(displayIndex)) }
        if let intent { args["intent"] = .string(intent) }
        return args
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func firstString(for keys: [String]) -> String? {
        for key in keys {
            if let value = self[key]?.stringValue {
                return value
            }
        }
        return nil
    }

    func firstDouble(for keys: [String]) -> Double? {
        for key in keys {
            if let value = self[key]?.doubleValue {
                return value
            }
        }
        return nil
    }

    func firstInt(for keys: [String]) -> Int? {
        for key in keys {
            if let value = self[key]?.intValue {
                return value
            }
        }
        return nil
    }

    func firstStringArray(for keys: [String]) -> [String] {
        for key in keys {
            guard let value = self[key] else { continue }
            if let array = value.arrayValue {
                return array.compactMap(\.stringValue)
            }
            if let string = value.stringValue {
                return string
                    .split { $0 == "+" || $0 == "," || $0 == " " }
                    .map(String.init)
            }
        }
        return []
    }
}

private extension String {
    var normalizedActionToken: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }
}
