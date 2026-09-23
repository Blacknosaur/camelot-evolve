import SwiftUI

/// Joining another phone's session: find it, then become a camera or an event remote.
struct MultiCamJoinView: View {
    @StateObject private var controller: MultiCamPeerController
    /// Called after the controller has left the session (dismiss, or restart in the companion app).
    let onLeave: () -> Void

    init(controller: @autoclosure @escaping () -> MultiCamPeerController, onLeave: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: controller())
        self.onLeave = onLeave
    }

    var body: some View {
        Group {
            if controller.session.state == .connected, let role = controller.role {
                switch role {
                case .camera: MultiCamCameraView(controller: controller, leave: leave)
                default: MultiCamRemoteView(controller: controller, leave: leave)
                }
            } else {
                browser
            }
        }
        .task { controller.start() }
        .onDisappear { controller.leave() }
    }

    private func leave() { controller.leave(); onLeave() }

    private var browser: some View {
        NavigationStack {
            List {
                Section {
                    if controller.session.hosts.isEmpty {
                        HStack(spacing: Theme.Space.md) {
                            ProgressView()
                            Text("Looking for a session nearby…").foregroundStyle(.secondary)
                        }.padding(.vertical, Theme.Space.xs)
                    }
                    ForEach(controller.session.hosts) { host in
                        Button { controller.join(host) } label: {
                            HStack(spacing: Theme.Space.md) {
                                Image(systemName: host.mode?.symbol ?? "iphone").font(.title3).foregroundStyle(Theme.brand).frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.projectName.isEmpty ? host.name : host.projectName).font(.headline)
                                    Text([host.name, host.mode.map { "join as \($0.peerRole == .camera ? "camera" : "event remote")" }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if controller.session.state == .connecting, controller.session.hostPeer == host.id { ProgressView() }
                            }
                        }
                        .disabled(controller.session.state == .connecting)
                        .accessibilityIdentifier("multicam-host-\(host.id.displayName)")
                    }
                } footer: {
                    Text("On the main phone, open the project and choose Multi-cam session. Both phones need Wi‑Fi and Bluetooth on.")
                }
                if let error = controller.session.lastError {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Join a session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { leave() } } }
        }
    }
}

// MARK: - Camera

/// A camera phone: framed by whoever holds it, started and stopped by the host.
struct MultiCamCameraView: View {
    @ObservedObject var controller: MultiCamPeerController
    let leave: () -> Void
    @State private var showingLeaveConfirmation = false
    private var engine: MultiCamCaptureEngine { controller.engine }
    private var isBusy: Bool { engine.isRecording || engine.isFinishing || controller.transferState == .sending }

    var body: some View {
        AdaptiveLayout { layout in
            ZStack {
                Color.black.ignoresSafeArea()
                MultiCamPreview(engine: engine).ignoresSafeArea()
                if !engine.isReady { notReady }
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 0)
                    footer(landscape: layout.isLandscape)
                }
            }
        }
        .preferredColorScheme(.dark).tint(.white).statusBarHidden().persistentSystemOverlays(.hidden)
        .interactiveDismissDisabled(isBusy)
        .alert("Leave the session?", isPresented: $showingLeaveConfirmation) {
            Button("Leave", role: .destructive, action: leave)
            Button("Stay", role: .cancel) {}
        } message: { Text(isBusy ? "This phone is still recording or sending its video." : "The host will lose this camera.") }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Button { if isBusy { showingLeaveConfirmation = true } else { leave() } } label: { Image(systemName: "chevron.down").frame(width: 20) }
                .accessibilityLabel("Leave session").disabled(engine.isRecording || engine.isFinishing)
            if engine.isRecording { CameraTimerCapsule(elapsed: engine.elapsed) }
            else {
                Text(controller.session.projectName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 10).frame(height: 34).background(.black.opacity(0.35), in: Capsule())
            }
            Spacer(minLength: 0)
            Label(controller.session.hostName, systemImage: "dot.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 10).frame(height: 34)
                .foregroundStyle(.black).background(Theme.signal, in: Capsule())
                .accessibilityIdentifier("multicam-camera-host")
        }
        .buttonStyle(CameraChromeButtonStyle()).foregroundStyle(.white)
        .padding(.horizontal, Theme.Space.md).frame(height: 48)
        .background { LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .top) }
    }

    private func footer(landscape: Bool) -> some View {
        VStack(spacing: 8) {
            if let message = controller.statusMessage ?? engine.statusMessage {
                Text(message).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            switch controller.transferState {
            case .sending:
                HStack(spacing: 8) {
                    ProgressView(value: controller.transfer?.fractionCompleted ?? 0).tint(Theme.signal)
                    Text("\(Int((controller.transfer?.fractionCompleted ?? 0) * 100))%").font(.system(size: 12)).monospacedDigit()
                }
                Text("Keep both phones open until the video has arrived.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            case .received:
                Label("Video delivered to \(controller.session.hostName)", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.signal)
            case let .failed(reason):
                Label(reason, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
            case .none:
                HStack(spacing: 8) {
                    Circle().fill(engine.isRecording ? .red : controller.session.clock.isSynced ? Theme.signal : .orange).frame(width: 8, height: 8)
                    Text(engine.isRecording ? "Recording · the host stops this camera" : controller.session.clock.isSynced ? "Ready · the host starts recording" : "Syncing clocks…")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
            }
            if engine.isRecording {
                EventTagStrip(counts: controller.eventCounts, lastTag: controller.lastTag, accessibilityPrefix: "multicam-camera", mark: controller.tag)
            }
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .foregroundStyle(.white)
        .background { LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .bottom) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("multicam-camera-status")
    }

    private var notReady: some View {
        VStack(spacing: 12) {
            if engine.isConfiguring { ProgressView().tint(.white) } else { Image(systemName: "camera").font(.title2) }
            Text(engine.statusMessage ?? "Preparing camera…").font(.subheadline).multilineTextAlignment(.center)
        }.foregroundStyle(.white).padding(20).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: Theme.Radius.medium)).padding(20)
    }
}

// MARK: - Remote

/// An event remote: a full-screen pad of tag targets plus a low-bandwidth host preview. This
/// phone never records or uploads video; it only receives the preview and sends timed taps.
struct MultiCamRemoteView: View {
    @ObservedObject var controller: MultiCamPeerController
    let leave: () -> Void
    @State private var showingCameraControls = false
    @State private var focusPoint: CGPoint?
    /// Two columns in portrait, three in landscape, so every target stays thumb-sized.
    private func rows(_ isLandscape: Bool) -> [[EventKind]] {
        let columns = isLandscape ? 3 : 2
        return stride(from: 0, to: EventKind.allCases.count, by: columns).map {
            Array(EventKind.allCases[$0..<min($0 + columns, EventKind.allCases.count)])
        }
    }

    var body: some View {
        AdaptiveLayout { layout in
            VStack(spacing: Theme.Space.md) {
                header
                hostPreview(height: layout.isLandscape ? 96 : 160)
                cameraControls
                status
                VStack(spacing: Theme.Space.sm) {
                    ForEach(Array(rows(layout.isLandscape).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: Theme.Space.sm) {
                            ForEach(row) { kind in pad(kind) }
                        }.frame(maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
                .disabled(!controller.hostIsRecording)
                .opacity(controller.hostIsRecording ? 1 : 0.5)
                clockLine
            }
            .padding(Theme.Space.md)
        }
        .foregroundStyle(.white)
        .background(Theme.ink.ignoresSafeArea())
        .preferredColorScheme(.dark).tint(.white)
        .accessibilityIdentifier("multicam-remote")
    }

    private func hostPreview(height: CGFloat) -> some View {
        MultiCamFeedView(feed: controller.hostFeed)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay(alignment: .topLeading) {
                Label("Host camera", systemImage: "video.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(8)
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).stroke(.white.opacity(0.12)))
            .overlay {
                GeometryReader { geometry in
                    if let focusPoint {
                        Circle().stroke(.yellow, lineWidth: 2).frame(width: 44, height: 44)
                            .position(x: focusPoint.x * geometry.size.width, y: focusPoint.y * geometry.size.height)
                    }
                    Color.clear.contentShape(Rectangle()).gesture(
                        SpatialTapGesture().onEnded { value in
                            guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                            let point = CGPoint(x: min(1, max(0, value.location.x / geometry.size.width)),
                                                y: min(1, max(0, value.location.y / geometry.size.height)))
                            focusPoint = point
                            controller.controlHostCamera(focus: point)
                        }
                    )
                }
            }
            .accessibilityLabel("Host camera preview")
            .accessibilityHint("Tap to set focus and exposure point")
            .accessibilityIdentifier("multicam-remote-host-preview")
    }

    private var cameraControls: some View {
        VStack(spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showingCameraControls.toggle() } } label: {
                HStack {
                    Label("Camera controls", systemImage: "camera.aperture")
                    Spacer()
                    Image(systemName: showingCameraControls ? "chevron.up" : "chevron.down")
                }
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("multicam-remote-camera-controls")

            if showingCameraControls {
                VStack(spacing: 10) {
                    controlRow(title: "Zoom", value: String(format: "%.1f×", controller.hostZoom)) {
                        Slider(value: Binding(get: { controller.hostZoom }, set: { controller.controlHostCamera(zoom: $0) }),
                               in: 1...max(1.01, controller.hostMaximumZoom))
                            .accessibilityIdentifier("multicam-remote-zoom")
                    }
                    controlRow(title: "Exposure", value: String(format: "%+.1f", controller.hostExposure)) {
                        Slider(value: Binding(get: { Double(controller.hostExposure) }, set: { controller.controlHostCamera(exposure: Float($0)) }),
                               in: Double(controller.hostExposureRange.lowerBound)...max(Double(controller.hostExposureRange.lowerBound) + 0.01,
                                                                                       Double(controller.hostExposureRange.upperBound)))
                            .accessibilityIdentifier("multicam-remote-exposure")
                    }
                    Text("Tap the preview to set focus. Exposure replaces aperture control because iPhone camera apertures are fixed.")
                        .font(.caption2).foregroundStyle(.white.opacity(0.65)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }

    private func controlRow<Control: View>(title: String, value: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.caption.weight(.medium)).frame(width: 62, alignment: .leading)
            control()
            Text(value).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
        }
    }

    private var header: some View {
        HStack {
            Button(action: leave) { Image(systemName: "chevron.down").frame(width: 20) }.buttonStyle(CameraChromeButtonStyle())
                .accessibilityLabel("Leave session")
            Spacer(minLength: 8)
            Text(controller.session.projectName).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Label(controller.session.hostName, systemImage: "dot.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 10).frame(height: 34).foregroundStyle(.black).background(Theme.signal, in: Capsule())
        }
    }

    /// The whole point of the pad: is the other phone actually recording right now?
    private var status: some View {
        HStack(spacing: Theme.Space.sm) {
            if controller.hostIsRecording {
                CameraTimerCapsule(elapsed: .seconds(controller.hostElapsed))
                Text("\(controller.taggedEvents.count) sent").font(.footnote).foregroundStyle(.white.opacity(0.7)).monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
                Text("Waiting for \(controller.session.hostName) to start recording")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("multicam-remote-status")
    }

    private func pad(_ kind: EventKind) -> some View {
        let justSent = controller.lastTag == kind
        return Button { controller.tag(kind) } label: {
            VStack(spacing: 6) {
                Image(systemName: justSent ? "checkmark" : kind.symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(justSent ? Color.black : kind.tint)
                Text(kind.rawValue).font(.system(size: 17, weight: .semibold, design: .rounded))
                let count = controller.eventCounts[kind] ?? 0
                Text(count > 0 ? "\(count)" : " ")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(justSent ? .black.opacity(0.7) : .white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(RemotePadStyle(tint: kind.tint, isSending: justSent))
        .accessibilityLabel("Tag \(kind.rawValue.lowercased())")
        .accessibilityValue("\(controller.eventCounts[kind] ?? 0) sent")
        .accessibilityIdentifier("multicam-remote-tag-\(kind.rawValue.lowercased())")
    }

    private var clockLine: some View {
        HStack(spacing: 8) {
            Circle().fill(controller.session.clock.isSynced ? Theme.signal : .orange).frame(width: 8, height: 8)
            Text(controller.session.clock.isSynced
                 ? String(format: "Clock synced · ±%.0f ms", controller.session.clock.uncertainty * 1000)
                 : "Syncing clocks…")
                .font(.footnote).foregroundStyle(.white.opacity(0.7))
            if let message = controller.statusMessage { Text("· \(message)").font(.footnote).foregroundStyle(.orange).lineLimit(1) }
            Spacer(minLength: 0)
        }
    }
}

/// A large, flat target that flashes in the event's own colour when the tap is sent.
private struct RemotePadStyle: ButtonStyle {
    let tint: Color
    let isSending: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(isSending ? AnyShapeStyle(tint) : AnyShapeStyle(.white.opacity(configuration.isPressed ? 0.22 : 0.09)),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).stroke(tint.opacity(isSending ? 0 : 0.35), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.snappy(duration: 0.18), value: isSending)
    }
}
