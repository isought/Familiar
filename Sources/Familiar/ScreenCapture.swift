import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

struct Screenshot {
    let data: Data
    let mediaType: String
    let width: Int
    let height: Int
    var sizeKB: Int { data.count / 1024 }
}

/// Full-resolution capture of one display plus the geometry needed to map screen points into it.
struct RawCapture {
    let image: CGImage
    let screen: NSScreen
    let pixelsPerPoint: CGFloat

    /// AppKit global point (bottom-left origin) -> pixel coordinates in `image` (top-left origin).
    func imagePoint(_ p: NSPoint) -> CGPoint {
        CGPoint(x: (p.x - screen.frame.minX) * pixelsPerPoint,
                y: (screen.frame.maxY - p.y) * pixelsPerPoint)
    }
}

enum ScreenCaptureError: LocalizedError {
    case noDisplay, encodeFailed, notPermitted
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found to capture."
        case .encodeFailed: return "Could not encode the screenshot."
        case .notPermitted: return "Screen Recording permission is not granted. Open System Settings → Privacy & Security → Screen Recording and enable Familiar, then relaunch."
        }
    }
}

enum ScreenCapture {
    /// Captures the display containing `point` (or the mouse) at native resolution, excluding Familiar's own windows.
    static func captureDisplay(containing point: NSPoint? = nil) async throws -> RawCapture {
        guard Permissions.screenRecordingGranted else { throw ScreenCaptureError.notPermitted }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let p = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let wantedID = screenNumber.map { CGDirectDisplayID($0.uint32Value) }
        guard let display = content.displays.first(where: { $0.displayID == wantedID }) ?? content.displays.first else {
            throw ScreenCaptureError.noDisplay
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let exclude = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingWindows: exclude)

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let ppp = CGFloat(image.width) / CGFloat(display.width)
        return RawCapture(image: image, screen: screen, pixelsPerPoint: ppp)
    }

    /// Convenience: one downscaled screenshot of the display under the mouse.
    static func capture(maxLongEdge: Int) async throws -> Screenshot {
        let raw = try await captureDisplay()
        guard let shot = encode(downscale(raw.image, maxLongEdge: maxLongEdge)) else { throw ScreenCaptureError.encodeFailed }
        return shot
    }

    static func downscale(_ image: CGImage, maxLongEdge: Int) -> CGImage {
        let long = max(image.width, image.height)
        guard long > maxLongEdge else { return image }
        let f = CGFloat(maxLongEdge) / CGFloat(long)
        let w = Int(CGFloat(image.width) * f), h = Int(CGFloat(image.height) * f)
        guard let ctx = context(w, h) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Draws a ring marker at `p` (pixel coords, top-left origin).
    static func annotate(_ image: CGImage, ringAt p: CGPoint) -> CGImage {
        guard let ctx = context(image.width, image.height) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let c = CGPoint(x: p.x, y: CGFloat(image.height) - p.y)
        let r = max(14, CGFloat(min(image.width, image.height)) * 0.02)
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.setLineWidth(r * 0.35); ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)); ctx.strokeEllipse(in: rect)
        ctx.setLineWidth(r * 0.18); ctx.setStrokeColor(CGColor(red: 0.55, green: 0.3, blue: 0.95, alpha: 1)); ctx.strokeEllipse(in: rect)
        return ctx.makeImage() ?? image
    }

    /// Crop of `size` pixels centered on `p` (pixel coords, top-left origin), clamped to the image.
    static func crop(_ image: CGImage, around p: CGPoint, size: CGSize) -> CGImage? {
        let w = min(size.width, CGFloat(image.width)), h = min(size.height, CGFloat(image.height))
        let x = min(max(0, p.x - w / 2), CGFloat(image.width) - w)
        let y = min(max(0, p.y - h / 2), CGFloat(image.height) - h)
        return image.cropping(to: CGRect(x: x, y: y, width: w, height: h))
    }

    static func encode(_ image: CGImage) -> Screenshot? {
        if let png = encode(image, type: .png), png.count < 4_000_000 {
            return Screenshot(data: png, mediaType: "image/png", width: image.width, height: image.height)
        }
        if let jpeg = encode(image, type: .jpeg, quality: 0.85) {
            return Screenshot(data: jpeg, mediaType: "image/jpeg", width: image.width, height: image.height)
        }
        return nil
    }

    /// JPEG bytes at the given quality (for images kept on disk, e.g. Watch me recordings).
    static func jpeg(_ image: CGImage, quality: Double = 0.8) -> Data? { encode(image, type: .jpeg, quality: quality) }

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double = 1.0) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
