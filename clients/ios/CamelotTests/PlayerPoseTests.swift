import CoreGraphics
import XCTest
@testable import Camelot

/// Foot correction and skeleton matching, tested off-device.
///
/// These decide where every ring and spotlight is drawn, and which body's shirt
/// the identity memory learns from, so they are worth checking exhaustively
/// rather than by eye on a clip.
final class PlayerPoseTests: XCTestCase {
    private func pose(ground: CGPoint?, extent: CGRect, torso: CGRect? = nil) -> PlayerPose {
        PlayerPose(ground: ground, torso: torso, shorts: nil, extent: extent, stature: nil)
    }

    func testFootLineMovesOntoTheAnkles() {
        // A box whose bottom sits above the feet, as happens when the detector
        // clips a leaning player.
        let box = CGRect(x: 0.4, y: 0.5, width: 0.05, height: 0.16)
        let corrected = pose(ground: CGPoint(x: 0.425, y: 0.68), extent: box).grounding(box)
        XCTAssertEqual(corrected.maxY, 0.68, accuracy: 0.0001, "the foot line should land on the ankles")
        XCTAssertEqual(corrected.minY, box.minY, accuracy: 0.0001, "only the bottom edge moves")
        XCTAssertEqual(corrected.minX, box.minX, accuracy: 0.0001)
        XCTAssertEqual(corrected.width, box.width, accuracy: 0.0001)
    }

    func testFootLineAlsoLiftsWhenTheBoxOvershoots() {
        let box = CGRect(x: 0.4, y: 0.5, width: 0.05, height: 0.16)
        let corrected = pose(ground: CGPoint(x: 0.425, y: 0.63), extent: box).grounding(box)
        XCTAssertEqual(corrected.maxY, 0.63, accuracy: 0.0001)
    }

    func testAWildlyDisagreeingSkeletonIsIgnored() {
        // A skeleton this far from the box belongs to somebody else; taking it
        // would teleport the ring rather than correct it.
        let box = CGRect(x: 0.4, y: 0.5, width: 0.05, height: 0.16)
        let corrected = pose(ground: CGPoint(x: 0.425, y: 0.9), extent: box).grounding(box)
        XCTAssertEqual(corrected, box, "a disagreement beyond tolerance must leave the box alone")
    }

    func testNoAnklesLeavesTheBoxAlone() {
        let box = CGRect(x: 0.4, y: 0.5, width: 0.05, height: 0.16)
        XCTAssertEqual(pose(ground: nil, extent: box).grounding(box), box)
    }

    func testCorrectionCannotCollapseTheBox() {
        let box = CGRect(x: 0.4, y: 0.5, width: 0.05, height: 0.16)
        // An ankle near the top would halve the body; refuse it.
        let corrected = pose(ground: CGPoint(x: 0.425, y: 0.52), extent: box).grounding(box, tolerance: 0.9)
        XCTAssertEqual(corrected, box)
    }

    func testMatchPrefersTheSkeletonInsideTheBox() {
        let box = CGRect(x: 0.40, y: 0.50, width: 0.05, height: 0.16)
        let mine = pose(ground: nil, extent: CGRect(x: 0.405, y: 0.505, width: 0.045, height: 0.15))
        let neighbour = pose(ground: nil, extent: CGRect(x: 0.44, y: 0.50, width: 0.05, height: 0.16))
        let chosen = PlayerPoseReader.match(box, among: [neighbour, mine])
        XCTAssertEqual(chosen?.extent, mine.extent,
                       "a box that has grown over a neighbour still belongs to its own player")
    }

    func testMatchRejectsSkeletonsElsewhereInTheFrame() {
        let box = CGRect(x: 0.40, y: 0.50, width: 0.05, height: 0.16)
        let far = pose(ground: nil, extent: CGRect(x: 0.8, y: 0.2, width: 0.05, height: 0.16))
        XCTAssertNil(PlayerPoseReader.match(box, among: [far]))
    }

    /// The sampling region override is what makes the kit signature describe the
    /// shirt instead of the grass around it.
    func testSampleRegionOverridesTheFixedBand() {
        let box = CGRect(x: 0.4, y: 0.5, width: 0.08, height: 0.20)
        let buffer = Self.buffer(width: 200, height: 200) { x, y in
            // Left half red, right half green: a region on one side must not
            // pick up the other.
            x < 100 ? (220, 30, 30) : (30, 200, 30)
        }
        let left = PlayerJerseySignature.sampleColors(buffer, box: box, orientation: .up, zone: .torso,
                                                      region: CGRect(x: 0.05, y: 0.4, width: 0.3, height: 0.2))
        let right = PlayerJerseySignature.sampleColors(buffer, box: box, orientation: .up, zone: .torso,
                                                       region: CGRect(x: 0.65, y: 0.4, width: 0.3, height: 0.2))
        XCTAssertFalse(left.isEmpty); XCTAssertFalse(right.isEmpty)
        let leftMean = PlayerJerseySignature.meanColor(left)!
        let rightMean = PlayerJerseySignature.meanColor(right)!
        XCTAssertGreaterThan(leftMean.x, rightMean.x, "the left region should read red")
        XCTAssertGreaterThan(rightMean.y, leftMean.y, "the right region should read green")
    }

    func testTheReaderStopsAskingWhenNothingIsEverFound() {
        let reader = PlayerPoseReader()
        let blank = Self.buffer(width: 64, height: 64) { _, _ in (20, 120, 40) }
        for _ in 0..<PlayerPoseReader.giveUpAfter {
            XCTAssertTrue(reader.poses(in: blank, orientation: .up).isEmpty)
        }
        XCTAssertTrue(reader.hasGivenUp,
                      "pose costs ~17 ms a frame; on footage where it never finds anyone it must stop")
    }

    private static func buffer(width: Int, height: Int,
                               color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let offset = y * stride + x * 4
                base[offset] = b; base[offset + 1] = g; base[offset + 2] = r; base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }
}
