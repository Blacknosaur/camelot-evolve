import AVFoundation
import CoreImage
import XCTest
@testable import Camelot

/// Runs on a phone: two Multipeer sessions in one process talk to each other, the capture engine
/// writes real files, and the stitcher registers two synthetic overlapping clips.
final class MultiCamDeviceTests: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Needs a phone: local network, camera and Vision.")
        #endif
    }

    // MARK: Protocol over a real link

    @MainActor
    func testHostAndPeerDiscoverSyncClocksAndExchangeEventsAndVideo() async throws {
        let host = MultiCamSession(role: .host, displayName: "Test host", deviceID: UUID())
        let peer = MultiCamSession(role: .camera, displayName: "Test camera", deviceID: UUID())
        defer { host.end(); peer.end() }
        let projectID = UUID()
        host.startHosting(mode: .dualCamera, projectID: projectID, projectName: "Device test")
        peer.startBrowsing()
        try await wait("host discovered", timeout: 15) { peer.hosts.contains { $0.id == host.localPeer } }
        let found = try XCTUnwrap(peer.hosts.first { $0.id == host.localPeer })
        XCTAssertEqual(found.projectName, "Device test")
        XCTAssertEqual(found.mode, .dualCamera)
        peer.join(found)
        try await wait("welcome", timeout: 20) { peer.state == .connected && peer.mode == .dualCamera }
        XCTAssertEqual(peer.projectID, projectID)
        XCTAssertEqual(peer.hostName, "Test host")
        try await wait("host sees the camera", timeout: 5) { host.peers.contains { $0.role == .camera && $0.name == "Test camera" } }
        try await wait("clock synced", timeout: 10) { peer.clock.samples.count >= 3 }
        XCTAssertLessThan(peer.clock.uncertainty, 0.1, "Same-process round trips are short")
        // Same device, same clock: the estimated offset must be ~0.
        XCTAssertEqual(peer.clock.offset, 0, accuracy: 0.05)
        XCTAssertEqual(peer.hostNow(), host.hostNow(), accuracy: 0.1)

        let received = LockedValue<[MultiCamMessage]>([])
        host.onMessage = { message, _ in received.value.append(message) }
        let tapTime = peer.hostNow()
        peer.send(.event(kind: "Goal", hostTime: tapTime))
        try await wait("event delivered", timeout: 5) { received.value.contains { if case .event("Goal", _) = $0 { return true }; return false } }

        let packets = LockedValue<[MultiCamVideoPacket]>([])
        host.onVideoPacket = { packet, _ in packets.value.append(packet) }
        let packet = MultiCamVideoPacket(presentationHostTime: 12.5, isKeyframe: true, parameterSets: [Data([1, 2]), Data([3])], payload: Data(repeating: 7, count: 40_000))
        peer.sendVideo(packet)
        try await wait("video packet delivered", timeout: 5) { packets.value.first == packet }
        try await wait("video marked on the peer record", timeout: 5) { host.peers.first?.hasVideo == true }

        host.send(.startRecording(recordingID: UUID(), hostTime: host.hostNow()), to: [peer.localPeer])
        let peerReceived = LockedValue<[MultiCamMessage]>([])
        peer.onMessage = { message, _ in peerReceived.value.append(message) }
        host.send(.stopRecording(hostTime: host.hostNow()))
        try await wait("stop delivered", timeout: 5) { peerReceived.value.contains { if case .stopRecording = $0 { return true }; return false } }
    }

    // MARK: Capture engine

    @MainActor
    func testEngineRecordsLocalAndProgramFilesWithASwitch() async throws {
        let engine = MultiCamCaptureEngine()
        await engine.prepare(quality: .hd)
        try XCTSkipUnless(engine.isReady, "Camera unavailable: \(engine.statusMessage ?? "")")
        defer { engine.shutdown() }
        let packets = LockedValue<Int>(0)
        engine.startStreaming { _ in packets.value += 1 }
        let id = UUID(), projectID = UUID()
        engine.startRecording(id: id, projectID: projectID, program: true)
        XCTAssertTrue(engine.isRecording)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertNotNil(engine.firstFrameHostTime)
        // Cut to a "remote" source and feed it synthetic frames, then back to this phone.
        let remote = UUID()
        engine.switchProgram(to: remote)
        let frame = try makeFrame(width: 1280, height: 720, color: CIColor(red: 1, green: 0, blue: 0))
        for _ in 0..<15 { engine.appendRemoteFrame(frame, from: remote); try await Task.sleep(for: .milliseconds(33)) }
        engine.switchProgram(to: nil)
        try await Task.sleep(for: .seconds(1))
        let stopped = await engine.stopRecording()
        let finished = try XCTUnwrap(stopped)
        defer {
            try? FileManager.default.removeItem(at: finished.local.url)
            RecordingRecovery.removeJournal(for: finished.local.id)
            if let program = finished.program { try? FileManager.default.removeItem(at: program.url); RecordingRecovery.removeJournal(for: program.id) }
        }
        XCTAssertFalse(engine.isRecording)
        XCTAssertGreaterThan(packets.value, 30, "The stream kept encoding while recording")
        XCTAssertGreaterThan(finished.local.duration, 2.5)
        XCTAssertEqual(finished.switches.cuts.map(\.recordingID), [remote, nil])

        let local = AVURLAsset(url: finished.local.url)
        let localVideo = try await local.loadTracks(withMediaType: .video), localAudio = try await local.loadTracks(withMediaType: .audio)
        let localDuration = try await local.load(.duration).seconds
        XCTAssertEqual(localVideo.count, 1)
        XCTAssertEqual(localAudio.count, 1, "The local file carries microphone audio")
        XCTAssertEqual(localDuration, finished.local.duration, accuracy: 0.3)
        let localSize = try await localVideo[0].load(.naturalSize)
        XCTAssertEqual(max(localSize.width, localSize.height), 1920, "Local file keeps the session quality")

        let program = try XCTUnwrap(finished.program)
        let programAsset = AVURLAsset(url: program.url)
        let programTracks = try await programAsset.loadTracks(withMediaType: .video), programAudio = try await programAsset.loadTracks(withMediaType: .audio)
        let programTrack = try XCTUnwrap(programTracks.first)
        let programSize = try await programTrack.load(.naturalSize)
        XCTAssertEqual(max(programSize.width, programSize.height), 1280, "The program is 720p")
        XCTAssertEqual(programAudio.count, 1)
        XCTAssertGreaterThan(program.duration, 2)
        // The middle of the program was the red remote source.
        let generator = AVAssetImageGenerator(asset: programAsset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let cutAt = finished.switches.cuts[0].at
        let image = try await generator.image(at: CMTime(seconds: cutAt + 0.25, preferredTimescale: 600)).image
        let red = averageColor(of: image)
        XCTAssertGreaterThan(red.r, 0.7, "Program shows the remote frames after the cut (r=\(red.r) g=\(red.g) b=\(red.b))")
        XCTAssertLessThan(red.g, 0.3)
    }

    // MARK: Stitcher

    func testStitcherRegistersTwoOverlappingViewsOfTheSameScene() async throws {
        // One wide textured scene; the main camera sees the left 1920 px, the second the right 1920 px.
        let scene = try makeTexturedScene(width: 2880, height: 1080)
        let primaryURL = FileManager.default.temporaryDirectory.appending(path: "stitch-primary-\(UUID().uuidString).mov")
        let cameraURL = FileManager.default.temporaryDirectory.appending(path: "stitch-camera-\(UUID().uuidString).mov")
        let outputURL = FileManager.default.temporaryDirectory.appending(path: "stitch-output-\(UUID().uuidString).mov")
        defer { for url in [primaryURL, cameraURL, outputURL] { try? FileManager.default.removeItem(at: url) } }
        try await writeClip(scene: scene, cropX: 0, width: 1920, height: 1080, seconds: 1.5, to: primaryURL)
        try await writeClip(scene: scene, cropX: 960, width: 1920, height: 1080, seconds: 1.2, to: cameraURL)

        let stitcher = MultiCamStitcher(primaryURL: primaryURL, cameraURL: cameraURL, cameraOffset: 0.2)
        let progress = LockedValue<Double>(0)
        let result = try await stitcher.run(to: outputURL) { progress.value = $0 }
        XCTAssertTrue(result.registered, "Vision should find the 50% overlap")
        XCTAssertGreaterThan(progress.value, 0.9)
        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(size.width, 2880, accuracy: 60, "The canvas is the union of both views")
        XCTAssertEqual(size.height, 1080, accuracy: 30)
        XCTAssertEqual(duration, 1.5, accuracy: 0.2)
        // A frame after the second camera starts should match the scene on both sides of the seam.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let leftMatch = similarity(frame, scene, x: 300, y: 500, size: 200)
        let rightMatch = similarity(frame, scene, x: 2500, y: 500, size: 200)
        XCTAssertGreaterThan(leftMatch, 0.9, "Main camera region matches the scene")
        XCTAssertGreaterThan(rightMatch, 0.75, "Second camera region lands where the scene continues (\(rightMatch))")
    }

    // MARK: Helpers

    @MainActor
    private func wait(_ what: String, timeout: Double, until condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            if Date.now > deadline { XCTFail("Timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func makeFrame(width: Int, height: Int, color: CIColor) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
        let result = try XCTUnwrap(buffer)
        CIContext().render(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), to: result)
        return result
    }

    /// Random coloured rectangles and circles: rich enough for feature matching, cheap to draw.
    private func makeTexturedScene(width: Int, height: Int) throws -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        var generator = SystemRandomNumberGenerator()
        let image = renderer.image { context in
            UIColor(white: 0.35, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for index in 0..<900 {
                let color = UIColor(hue: CGFloat.random(in: 0...1, using: &generator), saturation: 0.8, brightness: CGFloat.random(in: 0.4...1, using: &generator), alpha: 1)
                color.setFill()
                let rect = CGRect(x: CGFloat.random(in: 0...CGFloat(width), using: &generator), y: CGFloat.random(in: 0...CGFloat(height), using: &generator),
                                  width: CGFloat.random(in: 12...90, using: &generator), height: CGFloat.random(in: 12...90, using: &generator))
                if index.isMultiple(of: 3) { context.cgContext.fillEllipse(in: rect) } else { context.fill(rect) }
            }
        }
        return try XCTUnwrap(image.cgImage)
    }

    private func writeClip(scene: CGImage, cropX: Int, width: Int, height: Int, seconds: Double, to url: URL) async throws {
        let cropped = try XCTUnwrap(scene.cropping(to: CGRect(x: cropX, y: 0, width: width, height: height)))
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let frame = try makeFrame(width: width, height: height, color: .black)
        CIContext().render(CIImage(cgImage: cropped), to: frame)
        let fps = 10
        for index in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertNil(writer.error)
    }

    private func averageColor(of image: CGImage) -> (r: Double, g: Double, b: Double) {
        let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: CIImage(cgImage: image), kCIInputExtentKey: CIVector(cgRect: CGRect(x: 0, y: 0, width: image.width, height: image.height))])!
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(filter.outputImage!, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    /// 1 − mean absolute difference of a square patch (top-left origin in both images).
    private func similarity(_ a: CGImage, _ b: CGImage, x: Int, y: Int, size: Int) -> Double {
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: size * size * 4)
            let context = CGContext(data: &data, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -x, y: -(image.height - y - size), width: image.width, height: image.height))
            return data
        }
        let pa = pixels(a), pb = pixels(b)
        let difference = zip(pa, pb).enumerated().filter { $0.offset % 4 != 3 }.map { abs(Double($0.element.0) - Double($0.element.1)) }.reduce(0, +)
        return 1 - difference / Double(size * size * 3) / 255
    }
}

