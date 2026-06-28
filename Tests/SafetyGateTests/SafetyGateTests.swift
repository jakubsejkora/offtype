import XCTest

@testable import ComputerUse

/// The computer-use safety surface is where you get publicly embarrassed; lock it.
final class SafetyGateTests: XCTestCase {
    func testDeniedAppIsBlocked() {
        let d = SafetyGate().evaluate(actionLabel: "click", targetApp: "Keychain Access")
        guard case .block = d else { return XCTFail("expected block, got \(d)") }
    }

    func testSensitiveActionRequiresConfirmation() {
        let d = SafetyGate().evaluate(actionLabel: "Send", targetApp: "Mail")
        guard case .requireConfirmation = d else { return XCTFail("expected confirmation, got \(d)") }
    }

    func testBenignActionAllowed() {
        XCTAssertEqual(SafetyGate().evaluate(actionLabel: "click", targetApp: "TextEdit"), .allow)
    }
}
