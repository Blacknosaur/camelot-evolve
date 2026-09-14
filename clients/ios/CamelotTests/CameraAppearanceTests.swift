import AVFoundation
import SwiftData
import SwiftUI
import XCTest
@testable import Camelot

final class CameraAppearanceTests: XCTestCase {
    @MainActor
    func testCameraQualityAndReopeningOnDevice() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("Camera and microphone permission must already be granted on the phone")
        }
        let recorder = CameraRecorder()
        defer { recorder.shutdown() }
        await recorder.prepare(quality: .hd)
        XCTAssertTrue(recorder.isReady, recorder.statusMessage ?? "Camera did not start")
        XCTAssertTrue(recorder.session.isRunning)
        XCTAssertEqual(recorder.session.inputs.count, 2)
        XCTAssertEqual(recorder.session.outputs.count, 1)
        let quality: CaptureQuality = recorder.availableQualities.contains(.ultraHD) ? .ultraHD : .hd
        recorder.setQuality(quality)
        for _ in 0..<50 {
            if !recorder.isConfiguring { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(recorder.isConfiguring)
        XCTAssertEqual(recorder.quality, quality)
        XCTAssertEqual(recorder.session.sessionPreset, quality.preset)
        if quality == .ultraHD {
            let camera = try XCTUnwrap(recorder.session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first { $0.device.hasMediaType(.video) }?.device)
            let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
            XCTAssertEqual(dimensions.width, 3840)
            XCTAssertEqual(dimensions.height, 2160)
        }
        recorder.shutdown()
        XCTAssertFalse(recorder.isReady)
        await recorder.prepare(quality: quality)
        XCTAssertTrue(recorder.isReady, recorder.statusMessage ?? "Camera did not reopen")
        XCTAssertTrue(recorder.session.isRunning)
        XCTAssertEqual(recorder.session.inputs.count, 2, "Reopening must reuse the configured inputs")
        XCTAssertEqual(recorder.session.outputs.count, 1)
        XCTAssertEqual(recorder.quality, quality)
    }

    @MainActor
    func testAppearanceUpdatesLiveAndSurvivesRecreation() async throws {
        let suite = "camera-appearance-tests-\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let container = try memoryContainer()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let oldWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; oldWindow?.makeKey() }
        let appState = AppState()
        let host = UIHostingController(rootView: SettingsView(appState: appState)
            .modelContainer(container).modifier(AppAppearanceModifier()).defaultAppStorage(store))
        window.rootViewController = host; window.makeKeyAndVisible()
        store.set(AppAppearance.dark.rawValue, forKey: AppAppearance.storageKey)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(host.view.traitCollection.userInterfaceStyle, .dark)
        capture(host.view, name: "Account — dark appearance")
        store.set(AppAppearance.light.rawValue, forKey: AppAppearance.storageKey)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(host.view.traitCollection.userInterfaceStyle, .light)
        capture(host.view, name: "Account — light appearance")
        let recreatedStore = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(recreatedStore.string(forKey: AppAppearance.storageKey), AppAppearance.light.rawValue)
        let recreatedHost = UIHostingController(rootView: SettingsView(appState: appState)
            .modelContainer(container).modifier(AppAppearanceModifier()).defaultAppStorage(recreatedStore))
        window.rootViewController = recreatedHost
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(recreatedHost.view.traitCollection.userInterfaceStyle, .light)
        recreatedStore.set(AppAppearance.system.rawValue, forKey: AppAppearance.storageKey)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(recreatedHost.view.traitCollection.userInterfaceStyle, scene.traitCollection.userInterfaceStyle)
    }

    @MainActor
    func testCameraControlsFitCompactOverlays() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let oldWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; oldWindow?.makeKey() }
        for sidebar in [false, true] {
            for state in ["Ready", "Recording", "Saving"] {
                let dock = CameraCaptureDock(isRecording: state != "Ready", isFinishing: state == "Saving", canRecord: state != "Saving",
                    mode: .full, tagCounts: state == "Ready" ? [:] : [.goal: 2, .shot: 12], lastTag: state == "Recording" ? .goal : nil,
                    savedCount: 2, lastSavedDuration: 72, bufferProgress: 0, isLandscape: sidebar, record: {}, mark: { _ in })
                    .preferredColorScheme(.dark)
                let host = UIHostingController(rootView: dock)
                host.safeAreaRegions = []
                window.rootViewController = host; window.makeKeyAndVisible()
                let width: CGFloat = sidebar ? 728 : 393
                let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
                XCTAssertLessThanOrEqual(size.height, sidebar ? 84 : 136, "Capture controls must leave room for the viewfinder")
                host.view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
                try await Task.sleep(for: .milliseconds(150))
                // Snapshot the real controls at the same width used by the camera layout.
                host.view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
                host.view.layoutIfNeeded()
                capture(host.view, name: "Camera \(sidebar ? "landscape overlay" : "portrait") — \(state)")
            }
        }
    }

    @MainActor
    func testCameraScreenLayout() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("Camera permissions must already be granted")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let oldWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; oldWindow?.makeKey() }
        let container = try memoryContainer()
        let host = UIHostingController(rootView: CameraCaptureView(project: Project(name: "Training session"), appState: AppState()).modelContainer(container))
        window.rootViewController = host; window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(900))
        let preview = try XCTUnwrap(descendants(host.view).first { $0.layer is AVCaptureVideoPreviewLayer })
        let layer = try XCTUnwrap(preview.layer as? AVCaptureVideoPreviewLayer)
        let session = try XCTUnwrap(layer.session)
        let connection = try XCTUnwrap(layer.connection)
        XCTAssertGreaterThan(preview.bounds.height / host.view.bounds.height, 0.8)
        capture(host.view, name: "Camera — portrait screen")
        host.view.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.view.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        XCTAssertTrue(descendants(host.view).first { $0.layer is AVCaptureVideoPreviewLayer } === preview,
                      "Rotation must retain the preview view instead of reconnecting the capture layer")
        XCTAssertTrue(layer.session === session)
        XCTAssertTrue(layer.connection === connection)
        XCTAssertGreaterThan(preview.bounds.width / host.view.bounds.width, 0.8)
        capture(host.view, name: "Camera — landscape screen")
        for size in [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393), CGSize(width: 393, height: 852)] {
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(descendants(host.view).first { $0.layer is AVCaptureVideoPreviewLayer } === preview)
            XCTAssertTrue(layer.connection === connection)
        }
        window.rootViewController = nil
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private func memoryContainer() throws -> ModelContainer {
        let schema = Schema([Project.self, Recording.self, MatchEvent.self, VideoComposition.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @MainActor private func capture(_ view: UIView, name: String) {
        view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let attachment = XCTAttachment(image: renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) })
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
