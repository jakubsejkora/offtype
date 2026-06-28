import CoreGraphics
import XCTest

@testable import ComputerUse

/// Locks the Gemini-normalized → global-CGEvent-point math (Retina + multi-monitor),
/// the single most error-prone step in the computer-use path.
final class CoordinateMapperTests: XCTestCase {
    func testRetinaCenter() {
        // 1440×900-pt main display @2x → 2880×1800-px screenshot. Center (500,500).
        let p = CoordinateMapper.toGlobalPoint(
            normX: 500, normY: 500,
            imagePixelWidth: 2880, imagePixelHeight: 1800,
            backingScale: 2, displayOrigin: .zero)
        XCTAssertEqual(p.x, 720, accuracy: 0.0001)   // 500/1000*2880/2
        XCTAssertEqual(p.y, 450, accuracy: 0.0001)
    }

    func testSecondaryDisplayOriginOffset() {
        // Top-left of a secondary display positioned to the right of the main one.
        let p = CoordinateMapper.toGlobalPoint(
            normX: 0, normY: 0,
            imagePixelWidth: 2560, imagePixelHeight: 1440,
            backingScale: 2, displayOrigin: CGPoint(x: 1440, y: 0))
        XCTAssertEqual(p.x, 1440, accuracy: 0.0001)
        XCTAssertEqual(p.y, 0, accuracy: 0.0001)
    }

    func testNonRetinaBottomRight() {
        let p = CoordinateMapper.toGlobalPoint(
            normX: 1000, normY: 1000,
            imagePixelWidth: 1920, imagePixelHeight: 1080,
            backingScale: 1, displayOrigin: .zero)
        XCTAssertEqual(p.x, 1920, accuracy: 0.0001)
        XCTAssertEqual(p.y, 1080, accuracy: 0.0001)
    }
}
