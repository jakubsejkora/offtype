import XCTest

import OfftypeCore
@testable import Injection

// AGENT(Injection): replace with tests for secure-input refusal and pasteboard
// save/restore. Placeholder keeps the target compiling.
final class InjectionPlaceholderTests: XCTestCase {
    func testSecureInputProbeDoesNotCrash() {
        _ = TextInjector.isSecureInputActive()
    }
}
