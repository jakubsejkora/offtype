import XCTest
import AppKit

import OfftypeCore
@testable import Injection

/// Logic we can exercise without OS permissions: the secure-input probe must not
/// crash, and the pasteboard save/restore must round-trip exactly (no clipboard
/// theft). Posting ⌘V is a real keystroke, so it's left to manual testing.
final class InjectionTests: XCTestCase {
    func testSecureInputProbeDoesNotCrash() {
        // Just needs to return a value without trapping.
        _ = TextInjector.isSecureInputActive()
    }

    func testPasteboardSaveRestoreRoundTripsExactly() {
        let name = NSPasteboard.Name("\(Log.subsystem).tests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        defer { pasteboard.releaseGlobally() }

        // Seed the user's "clipboard" with a string plus a custom binary type.
        pasteboard.clearContents()
        let original = NSPasteboardItem()
        original.setString("user-clipboard-contents", forType: .string)
        let customType = NSPasteboard.PasteboardType("\(Log.subsystem).tests.custom")
        original.setData(Data([0x01, 0x02, 0x03, 0xFF]), forType: customType)
        XCTAssertTrue(pasteboard.writeObjects([original]))

        // Snapshot, then clobber the pasteboard the way inject() would.
        let snapshot = TextInjector.snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("offtype-injected-text", forType: .string)
        XCTAssertEqual(pasteboard.string(forType: .string), "offtype-injected-text")

        // Restore and confirm both the string and the binary type came back intact.
        TextInjector.restore(snapshot, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "user-clipboard-contents")
        XCTAssertEqual(pasteboard.data(forType: customType), Data([0x01, 0x02, 0x03, 0xFF]))
    }

    func testRestoreOfEmptySnapshotLeavesPasteboardEmpty() {
        let name = NSPasteboard.Name("\(Log.subsystem).tests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("something", forType: .string)

        TextInjector.restore(TextInjector.PasteboardSnapshot(items: []), to: pasteboard)
        XCTAssertNil(pasteboard.string(forType: .string))
    }
}
