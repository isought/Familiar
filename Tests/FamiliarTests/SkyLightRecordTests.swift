import Foundation
import CoreGraphics
import Testing
@testable import Familiar

@Suite
struct SkyLightRecordTests {
    /// Offsets the record is allowed to touch; everything else must stay zero.
    private static let touched: Set<Int> = [0x04, 0x08, 0x3c, 0x3d, 0x3e, 0x3f, 0x8a]

    @Test
    func activateRecordLayout() {
        let b = SkyLightClick.record(windowID: 0x0102_0304, activate: true)
        #expect(b.count == 0xf8)
        #expect(b[0x04] == 0xf8)
        #expect(b[0x08] == 0x0d)
        #expect(b[0x8a] == 0x01)
        #expect(Array(b[0x3c..<0x40]) == [0x04, 0x03, 0x02, 0x01])   // little-endian window id
        #expect(b.enumerated().allSatisfy { Self.touched.contains($0.offset) || $0.element == 0 })
    }

    @Test
    func deactivateRecordLayout() {
        let b = SkyLightClick.record(windowID: 10454, activate: false)
        #expect(b.count == 0xf8)
        #expect(b[0x04] == 0xf8)
        #expect(b[0x08] == 0x0d)
        #expect(b[0x8a] == 0x02)
        #expect(Array(b[0x3c..<0x40]) == [0xd6, 0x28, 0x00, 0x00])
        #expect(b.enumerated().allSatisfy { Self.touched.contains($0.offset) || $0.element == 0 })
    }

    @Test
    func windowIDZeroAndMax() {
        #expect(Array(SkyLightClick.record(windowID: 0, activate: true)[0x3c..<0x40]) == [0, 0, 0, 0])
        #expect(Array(SkyLightClick.record(windowID: CGWindowID.max, activate: true)[0x3c..<0x40]) == [0xff, 0xff, 0xff, 0xff])
    }

    @Test
    func supportedOSBounds() {
        func v(_ major: Int, _ minor: Int) -> OperatingSystemVersion { OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0) }
        #expect(!SkyLightClick.supportedOS(v(13, 6)))
        #expect(SkyLightClick.supportedOS(v(14, 0)))
        #expect(SkyLightClick.supportedOS(v(15, 4)))
        #expect(SkyLightClick.supportedOS(v(26, 6)))
        #expect(!SkyLightClick.supportedOS(v(27, 0)))
        #expect(!SkyLightClick.supportedOS(v(0, 0)))
    }
}
