import CoreVideo
import UIKit
import simd
import XCTest
@testable import Camelot

final class MultiCamProtocolTests: XCTestCase {
    func testControlMessagesRoundTripThroughTheWireFormat() throws {
        let id = UUID(), project = UUID()
        let messages: [MultiCamMessage] = [
            .hello(deviceName: "Ana's iPhone", deviceID: id),
            .welcome(sessionID: id, mode: .switcher, projectID: project, projectName: "U15 vs Rovers", hostName: "Coach"),
            .clockPong(id: id, sentAt: 1.5, hostReceivedAt: 100.25, hostSentAt: 100.26),
            .startRecording(recordingID: id, hostTime: 42),
            .event(kind: "Goal", hostTime: 88.5),
            .cameraCapabilities(maxZoom: 6, minExposure: -2, maxExposure: 2, zoom: 1.5, exposure: 0.3),
            .cameraControl(zoom: 2, focusX: 0.25, focusY: 0.75, exposure: -0.5),
            .transferReady(recordingID: id, byteCount: 1_234, durationSeconds: 12.5, firstFrameHostTime: 40.1, deviceName: "Ana's iPhone"),
        ]
        for message in messages {
            let wire = try message.wireData()
            XCTAssertEqual(wire.first, MultiCamWireTag.control.rawValue)
            XCTAssertEqual(try MultiCamMessage.decode(wire.dropFirst()), message)
        }
    }

    func testVideoPacketsKeepParameterSetsAndPayloadIntact() {
        let sps = Data([0x67, 0x42, 0x00, 0x1f]), pps = Data([0x68, 0xce, 0x3c, 0x80])
        let payload = Data((0..<5_000).map { UInt8($0 % 251) })
        let keyframe = MultiCamVideoPacket(presentationHostTime: 1234.5678, isKeyframe: true, parameterSets: [sps, pps], payload: payload)
        XCTAssertEqual(MultiCamVideoPacket.decode(keyframe.wireData()), keyframe)
        let delta = MultiCamVideoPacket(presentationHostTime: 1234.6, isKeyframe: false, parameterSets: [], payload: Data([1, 2, 3]))
        XCTAssertEqual(MultiCamVideoPacket.decode(delta.wireData()), delta)
        XCTAssertNil(MultiCamVideoPacket.decode(Data([MultiCamWireTag.video.rawValue, 1, 0])), "Truncated packets are rejected, not partially read")
        XCTAssertNil(MultiCamVideoPacket.decode(Data([MultiCamWireTag.control.rawValue]) + delta.wireData().dropFirst()), "A control tag is not a video packet")
    }

    func testClockSyncPrefersShortRoundTripsAndConvergesOnTheTrueOffset() {
        var clock = MultiCamClockSync()
        XCTAssertFalse(clock.isSynced)
        let trueOffset = 500.0
        // Symmetric 20 ms round trip: exact.
        clock.record(sentAt: 10, hostReceivedAt: 10.010 + trueOffset, hostSentAt: 10.011 + trueOffset, receivedAt: 10.021)
        XCTAssertEqual(clock.offset, trueOffset, accuracy: 1e-9)
        XCTAssertEqual(clock.uncertainty, 0.010, accuracy: 1e-9)
        // A congested 400 ms round trip with a skewed path would drag the estimate; it ranks last.
        clock.record(sentAt: 20, hostReceivedAt: 20.350 + trueOffset, hostSentAt: 20.351 + trueOffset, receivedAt: 20.401)
        XCTAssertEqual(clock.offset, trueOffset, accuracy: 0.2)
        for round in 0..<10 {
            let sent = 30.0 + Double(round)
            clock.record(sentAt: sent, hostReceivedAt: sent + 0.004 + trueOffset, hostSentAt: sent + 0.0045 + trueOffset, receivedAt: sent + 0.0085)
        }
        XCTAssertEqual(clock.offset, trueOffset, accuracy: 1e-6)
        XCTAssertEqual(clock.samples.count, clock.keeps, "Only the best samples are kept")
        XCTAssertLessThan(clock.samples.map(\.roundTrip).max() ?? 1, 0.05, "The congested sample was evicted")
        XCTAssertEqual(clock.hostTime(forLocal: 1), 1 + trueOffset, accuracy: 1e-6)
        XCTAssertEqual(clock.localTime(forHost: trueOffset), 0, accuracy: 1e-6)
        clock.record(sentAt: 50, hostReceivedAt: 49, hostSentAt: 49.1, receivedAt: 50.05)
        XCTAssertEqual(clock.samples.count, clock.keeps, "A negative round trip is impossible and ignored")
    }

    func testSwitchTimelineCollapsesRepeatsAndAnswersLookups() {
        var timeline = MultiCamSwitchTimeline()
        let camera = UUID()
        timeline.switchTo(nil, at: 0)
        timeline.switchTo(nil, at: 3)
        XCTAssertEqual(timeline.cuts.count, 1, "Selecting the live source again is not a cut")
        timeline.switchTo(camera, at: 5)
        timeline.switchTo(nil, at: 5) // Two cuts at the same instant keep only the last one.
        XCTAssertEqual(timeline.cuts.map(\.at), [0, 5])
        XCTAssertNil(timeline.source(at: 6))
        timeline.switchTo(camera, at: 9.5)
        XCTAssertEqual(timeline.source(at: 10), camera)
        XCTAssertNil(timeline.source(at: 4))
        let data = try! JSONEncoder().encode(timeline)
        XCTAssertEqual(try? JSONDecoder().decode(MultiCamSwitchTimeline.self, from: data), timeline)
    }

    func testAlignmentOffsetsAndSharedRange() {
        XCTAssertEqual(MultiCamAlignment.offsetSeconds(cameraFirstFrame: 1_000.75, hostFirstFrame: 1_000.25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MultiCamAlignment.sharedRange(hostDuration: 100, cameraDuration: 90, cameraOffset: 0.5), 0.5...90.5)
        XCTAssertEqual(MultiCamAlignment.sharedRange(hostDuration: 100, cameraDuration: 200, cameraOffset: -20), 0...100)
        XCTAssertNil(MultiCamAlignment.sharedRange(hostDuration: 10, cameraDuration: 10, cameraOffset: 12))
    }

    func testStitchLayoutFallsBackToSideBySideWithoutARegistration() {
        let layout = MultiCamStitchLayout.compute(primarySize: CGSize(width: 1920, height: 1080), cameraSize: CGSize(width: 1280, height: 720), homography: nil)
        XCTAssertFalse(layout.isRegistered)
        XCTAssertEqual(layout.canvasSize, CGSize(width: 3840, height: 1080))
        XCTAssertEqual(layout.primaryFrame, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(layout.cameraCorners[0], CGPoint(x: 1920, y: 0))
        XCTAssertEqual(layout.cameraCorners[2], CGPoint(x: 3840, y: 1080), "The second camera is scaled to the main camera's height")
        XCTAssertTrue(layout.cameraOnRight)
    }

    func testStitchLayoutPlacesARegisteredCameraAndFitsTheCanvasCap() {
        // Second camera shifted 1400 px right of the main camera: 520 px of overlap.
        let shift = simd_float3x3(rows: [simd_float3(1, 0, 1400), simd_float3(0, 1, 0), simd_float3(0, 0, 1)])
        let layout = MultiCamStitchLayout.compute(primarySize: CGSize(width: 1920, height: 1080), cameraSize: CGSize(width: 1920, height: 1080), homography: shift)
        XCTAssertTrue(layout.isRegistered)
        XCTAssertEqual(layout.canvasSize, CGSize(width: 3320, height: 1080))
        XCTAssertEqual(layout.scale, 1)
        XCTAssertEqual(layout.cameraCorners[0], CGPoint(x: 1400, y: 0))
        XCTAssertEqual(layout.feather?.maxX, 1920)
        XCTAssertEqual(layout.feather?.width ?? 0, 312, accuracy: 0.001, "The blend band is 60% of the overlap")
        let wide = MultiCamStitchLayout.compute(primarySize: CGSize(width: 3840, height: 2160), cameraSize: CGSize(width: 3840, height: 2160),
            homography: simd_float3x3(rows: [simd_float3(1, 0, 3000), simd_float3(0, 1, 0), simd_float3(0, 0, 1)]))
        XCTAssertEqual(wide.canvasSize.width, MultiCamStitchLayout.maximumWidth, accuracy: 2)
        XCTAssertLessThan(wide.scale, 1)
        XCTAssertEqual(wide.canvasSize.width.truncatingRemainder(dividingBy: 2), 0, "Encoders need even dimensions")
    }

    func testStitchLayoutRejectsImplausibleRegistrations() {
        let collapsed = simd_float3x3(rows: [simd_float3(0.1, 0, 0), simd_float3(0, 0.1, 0), simd_float3(0, 0, 1)])
        XCTAssertFalse(MultiCamStitchLayout.compute(primarySize: CGSize(width: 1920, height: 1080), cameraSize: CGSize(width: 1920, height: 1080), homography: collapsed).isRegistered)
        let farAway = simd_float3x3(rows: [simd_float3(1, 0, 9000), simd_float3(0, 1, 0), simd_float3(0, 0, 1)])
        XCTAssertFalse(MultiCamStitchLayout.compute(primarySize: CGSize(width: 1920, height: 1080), cameraSize: CGSize(width: 1920, height: 1080), homography: farAway).isRegistered)
        let mirrored = simd_float3x3(rows: [simd_float3(-1, 0, 1920), simd_float3(0, 1, 0), simd_float3(0, 0, 1)])
        XCTAssertFalse(MultiCamStitchLayout.compute(primarySize: CGSize(width: 1920, height: 1080), cameraSize: CGSize(width: 1920, height: 1080), homography: mirrored).isRegistered)
    }

    func testRescaledHomographyMapsFullResolutionPixels() {
        // Vision saw both frames at half size; a 100 px shift there is 200 px at full size.
        let small = simd_float3x3(rows: [simd_float3(1, 0, 100), simd_float3(0, 1, 0), simd_float3(0, 0, 1)])
        let full = MultiCamStitcher.rescale(small, floatingScale: 2, referenceScale: 2)
        let mapped = MultiCamStitchLayout.warp([CGPoint(x: 400, y: 300)], by: full)!
        XCTAssertEqual(mapped[0].x, 600, accuracy: 1e-3)
        XCTAssertEqual(mapped[0].y, 300, accuracy: 1e-3)
    }

    func testStreamSizeKeepsOrientationAndEvenDimensions() throws {
        let landscape = try pixelBuffer(width: 3840, height: 2160), portrait = try pixelBuffer(width: 1080, height: 1920)
        XCTAssertEqual(MultiCamFrameScaler.streamSize(for: landscape), CGSize(width: 1280, height: 720))
        XCTAssertEqual(MultiCamFrameScaler.streamSize(for: portrait), CGSize(width: 720, height: 1280))
        let scaled = MultiCamFrameScaler(size: CGSize(width: 1280, height: 720)).scale(landscape)
        XCTAssertEqual(scaled.map(CVPixelBufferGetWidth), 1280)
        XCTAssertEqual(scaled.map(CVPixelBufferGetHeight), 720)
    }

    func testEncoderAndDecoderRoundTripAFrame() async throws {
        let frames = expectation(description: "decoded frame")
        frames.assertForOverFulfill = false
        let decodedSize = LockedValue<CGSize?>(nil)
        let decoder = MultiCamVideoDecoder { pixelBuffer, _ in
            decodedSize.value = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            frames.fulfill()
        }
        let packets = LockedValue<[MultiCamVideoPacket]>([])
        let encoder = MultiCamVideoEncoder { packet in
            packets.value.append(packet)
            decoder.decode(packet)
        }
        let source = try pixelBuffer(width: 640, height: 360)
        for index in 0..<8 { encoder.encode(source, hostTime: Double(index) / 30) }
        encoder.flush() // The simulator's software encoder holds frames until asked to complete them.
        await fulfillment(of: [frames], timeout: 10)
        XCTAssertEqual(encoder.lastStatus.value, noErr, "VideoToolbox reported status \(encoder.lastStatus.value)")
        XCTAssertEqual(decodedSize.value, CGSize(width: 640, height: 360))
        XCTAssertTrue(packets.value.first?.isKeyframe == true, "The first packet must be a keyframe with parameter sets")
        XCTAssertGreaterThanOrEqual(packets.value.first?.parameterSets.count ?? 0, 2)
        encoder.invalidate(); decoder.invalidate()
    }

    private func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        if let base = CVPixelBufferGetBaseAddress(result) {
            let rowBytes = CVPixelBufferGetBytesPerRow(result)
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { row[x * 4] = UInt8((x + y) % 256); row[x * 4 + 1] = UInt8(x % 256); row[x * 4 + 2] = UInt8(y % 256); row[x * 4 + 3] = 255 }
            }
        }
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }
}

final class MultiCamRegistrationTests: XCTestCase {
    func testCoarseShiftFindsAHalfFrameOverlap() throws {
        let scene = try Self.texturedScene(width: 1440, height: 540)
        let reference = try XCTUnwrap(scene.cropping(to: CGRect(x: 0, y: 0, width: 960, height: 540)))
        let floating = try XCTUnwrap(scene.cropping(to: CGRect(x: 480, y: 30, width: 960, height: 500)))
        let shift = try XCTUnwrap(MultiCamRegistration.coarseShift(reference: reference, floating: floating))
        XCTAssertEqual(shift.dx, 480, accuracy: 3)
        XCTAssertEqual(shift.dy, 30, accuracy: 3)
        XCTAssertGreaterThan(shift.score, 0.9)
        let homography = try XCTUnwrap(MultiCamRegistration.homography(reference: reference, floating: floating))
        // Bottom-left convention: the floating image's bottom edge is 540 − (30 + 500) = 10 px up.
        let origin = try XCTUnwrap(MultiCamStitchLayout.warp([.zero], by: homography)).first!
        XCTAssertEqual(origin.x, 480, accuracy: 6)
        XCTAssertEqual(origin.y, 10, accuracy: 6)
        let layout = MultiCamStitchLayout.compute(primarySize: CGSize(width: 960, height: 540), cameraSize: CGSize(width: 960, height: 500), homography: homography)
        XCTAssertTrue(layout.isRegistered)
        XCTAssertEqual(layout.canvasSize.width, 1440, accuracy: 8)
    }

    func testCoarseShiftRejectsUnrelatedImages() throws {
        let a = try Self.texturedScene(width: 800, height: 450), b = try Self.texturedScene(width: 800, height: 450)
        let shift = MultiCamRegistration.coarseShift(reference: a, floating: b)
        XCTAssertLessThan(shift?.score ?? 0, 0.5, "Two different random scenes must not look aligned")
    }

    static func texturedScene(width: Int, height: Int) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor(white: 0.35, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for index in 0..<600 {
                UIColor(hue: CGFloat.random(in: 0...1), saturation: 0.8, brightness: CGFloat.random(in: 0.4...1), alpha: 1).setFill()
                let rect = CGRect(x: CGFloat.random(in: 0...CGFloat(width)), y: CGFloat.random(in: 0...CGFloat(height)), width: CGFloat.random(in: 8...60), height: CGFloat.random(in: 8...60))
                if index.isMultiple(of: 3) { context.cgContext.fillEllipse(in: rect) } else { context.fill(rect) }
            }
        }
        return try XCTUnwrap(image.cgImage)
    }
}
