import XCTest
@testable import Camelot

/// The painted pitch must sit exactly where the projection puts the field, so it is
/// centred on screen and elements line up with the markings.
final class BoardSurfaceCentringTests: XCTestCase {
    /// Horizontal and vertical extent of the green surface in an image.
    private func greenBounds(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in stride(from: 0, to: h, by: 2) {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if g > r + 20 && g > b + 20 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func testPitchIsCentredInPortraitAndLandscape() throws {
        for (size, reserved) in [(CGSize(width: 440, height: 760), CGSize(width: 0, height: 52)),
                                 (CGSize(width: 800, height: 380), CGSize(width: 56, height: 0))] {
            let cached = try XCTUnwrap(BoardSurfaceCache.shared.canvas(field: .footballFull, style: .grass, size: size, inset: 10, reserved: reserved, scale: 1))
            let bounds = try XCTUnwrap(greenBounds(cached))
            let frame = BoardProjection(field: .footballFull, size: size, inset: 10, reserved: reserved).surfaceFrame
            XCTAssertEqual(bounds.midX, frame.midX, accuracy: 3, "Pitch centred horizontally at \(size)")
            XCTAssertEqual(bounds.midY, frame.midY, accuracy: 3, "Pitch centred vertically at \(size)")
            XCTAssertEqual(bounds.width, frame.width, accuracy: 4, "Painted pitch fills its frame at \(size)")
        }
    }
}
