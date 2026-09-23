import SwiftData
import SwiftUI

// MARK: - Setup

/// Pick how the other phones take part, then start hosting.
struct MultiCamSetupView: View {
    let project: Project
    let start: (MultiCamMode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: MultiCamMode = .dualCamera

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text("Other phones join from Projects → Join a session. Keep everyone on the same Wi‑Fi, or close together for a direct link.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(MultiCamMode.allCases) { option in
                        Button { mode = option } label: { ModeCard(option: option, isSelected: mode == option) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("multicam-mode-\(option.rawValue)")
                    }
                    if mode == .switcher {
                        Text("The live cut is recorded at 720p. Every phone also keeps its own full-quality video.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Start session") { dismiss(); start(mode) }
                        .buttonStyle(.primary).padding(.top, Theme.Space.sm)
                        .accessibilityIdentifier("multicam-start")
                }
                .padding(Theme.Space.lg).readableWidth()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Multi-cam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private struct ModeCard: View {
        let option: MultiCamMode
        let isSelected: Bool
        var body: some View {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                Image(systemName: option.symbol).font(.title2).frame(width: 36)
                    .foregroundStyle(isSelected ? Theme.brand : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title).font(.headline)
                    Text(option.summary).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.brand : Color(.quaternaryLabel))
            }
            .padding(Theme.Space.md)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: Theme.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).stroke(isSelected ? Theme.brand : Color.clear, lineWidth: 1.5))
        }
    }
}

// MARK: - Host capture

/// The main phone for two-camera and switcher sessions: its own camera, every connected feed,
/// synced record/stop, event tags, and the transfers once the take ends.
struct MultiCamCaptureView: View {
    @StateObject private var host: MultiCamHost
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingStopConfirmation = false
    @State private var showingLeaveConfirmation = false
    @State private var enlargedFeed: UUID?
    /// Two-camera setup: show both views side by side so they can be aimed to overlap.
    @State private var aligning = false
    @StateObject private var alignment = MultiCamAlignmentCheck()

    init(project: Project, mode: MultiCamMode, appState: AppState) {
        _host = StateObject(wrappedValue: MultiCamHost(project: project, mode: mode, appState: appState))
    }

    private var engine: MultiCamCaptureEngine { host.engine }
    private var isBusy: Bool { engine.isRecording || engine.isFinishing || host.awaitingTransfers > 0 }

    var body: some View {
        AdaptiveLayout { layout in
            ZStack {
                Color.black.ignoresSafeArea()
                stage(landscape: layout.isLandscape)
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 0)
                    dock(landscape: layout.isLandscape)
                }
            }
        }
        .preferredColorScheme(.dark).tint(.white).statusBarHidden().persistentSystemOverlays(.hidden)
        .interactiveDismissDisabled(isBusy)
        .task {
            host.start(modelContext: modelContext)
            await engine.prepare(quality: .hd)
        }
        .onDisappear { host.end(); alignment.stop() }
        .onChange(of: aligning) { _, isAligning in
            guard isAligning, let peer = host.cameras.first, let feed = host.feed(for: peer) else { alignment.stop(); return }
            alignment.start(local: { engine.latestFrame }, remote: { feed.latestFrame.value })
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, engine.isRecording { host.stopRecording() }
        }
        .alert("Stop recording?", isPresented: $showingStopConfirmation) {
            Button("Stop and save", role: .destructive) { host.stopRecording() }
            Button("Keep recording", role: .cancel) {}
        } message: { Text("Every connected camera stops too, then sends its video to this phone.") }
        .alert("Leave the session?", isPresented: $showingLeaveConfirmation) {
            Button("Leave", role: .destructive) { dismiss() }
            Button("Stay", role: .cancel) {}
        } message: { Text(host.awaitingTransfers > 0 ? "Videos are still arriving. Leaving now keeps them on the other phones." : "Connected phones will be disconnected.") }
        .task(id: host.statusMessage) {
            guard let message = host.statusMessage, message.hasPrefix("Saved") || message.hasPrefix("All ") else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, host.statusMessage == message { host.statusMessage = nil }
        }
    }

    // MARK: Stage

    @ViewBuilder private func stage(landscape: Bool) -> some View {
        switch host.mode {
        case .switcher: switcherStage(landscape: landscape)
        default: dualStage(landscape: landscape)
        }
    }

    /// Own camera full screen; the other camera as a picture-in-picture that can be swapped.
    @ViewBuilder private func dualStage(landscape: Bool) -> some View {
        if aligning, let peer = host.cameras.first, let feed = host.feed(for: peer) {
            alignStage(peer: peer, feed: feed, landscape: landscape)
        } else {
            pipStage(landscape: landscape)
        }
    }

    /// Both cameras at equal size with the seam in the middle: turn the phones until the readout
    /// says the views share enough to be joined into one wide picture.
    private func alignStage(peer: MultiCamSession.Peer, feed: MultiCamFeed, landscape: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                let mine = MultiCamPreview(engine: engine).overlay(alignment: .bottom) { sourceLabel("This phone") }
                let theirs = MultiCamFeedView(feed: feed).overlay(alignment: .bottom) { sourceLabel(peer.name) }
                if alignment.cameraOnRight {
                    mine; seam; theirs
                } else {
                    theirs; seam; mine
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            alignmentReadout
        }
        .padding(.top, 52).padding(.bottom, landscape ? 96 : 150)
        .accessibilityIdentifier("multicam-align-stage")
    }

    private var seam: some View {
        Rectangle().fill(alignment.verdict.isGood ? Theme.signal : Color.white.opacity(0.5)).frame(width: 2)
    }

    private func sourceLabel(_ name: String) -> some View {
        Text(name).font(.caption2.bold()).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.6), in: Capsule()).padding(6)
    }

    /// The same measurement the stitcher will make later, so there are no surprises afterwards.
    private var alignmentReadout: some View {
        HStack(spacing: 8) {
            Image(systemName: alignment.verdict.isGood ? "checkmark.circle.fill" : "arrow.left.and.right")
                .foregroundStyle(alignment.verdict.isGood ? Theme.signal : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(alignment.verdict.message).font(.system(size: 13, weight: .medium)).lineLimit(2)
                if abs(alignment.verticalDrift) > 0.05 {
                    Text(alignment.verticalDrift > 0 ? "The other phone is aimed lower — level them" : "The other phone is aimed higher — level them")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .padding(.horizontal, Theme.Space.md)
        .accessibilityIdentifier("multicam-align-readout")
        .accessibilityValue(alignment.verdict.message)
    }

    private func pipStage(landscape: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let enlargedFeed, let feed = host.feeds[enlargedFeed] {
                MultiCamFeedView(feed: feed).ignoresSafeArea()
                pip { MultiCamPreview(engine: engine) } label: { "This phone" } tap: { self.enlargedFeed = nil }
            } else {
                MultiCamPreview(engine: engine).ignoresSafeArea()
                if let peer = host.cameras.first, let feed = host.feed(for: peer) {
                    pip { MultiCamFeedView(feed: feed) } label: { peer.name } tap: { enlargedFeed = feed.id }
                        .overlay(alignment: .topLeading) { if !peer.hasVideo { waitingBadge } }
                }
            }
            notReadyOverlay
        }
        .padding(.bottom, landscape ? 96 : 150)
    }

    private func pip<Content: View>(@ViewBuilder _ content: () -> Content, label: () -> String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            content()
                .frame(width: 168, height: 96)
                .clipShape(.rect(cornerRadius: Theme.Radius.small))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).stroke(.white.opacity(0.35), lineWidth: 1))
                .overlay(alignment: .bottomLeading) {
                    Text(label()).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: .capsule).padding(6)
                }
        }
        .buttonStyle(.plain).padding(Theme.Space.md)
        .accessibilityLabel("Swap cameras")
    }

    /// Program monitor on top, one thumbnail per source underneath; tap a thumbnail to cut.
    private func switcherStage(landscape: Bool) -> some View {
        OrientationStack(isLandscape: landscape, spacing: 0) {
            ZStack {
                if let source = engine.programSource, let feed = host.feeds[source] { MultiCamFeedView(feed: feed) }
                else { MultiCamPreview(engine: engine) }
                notReadyOverlay
            }
            .overlay(alignment: .topLeading) { liveBadge(engine.programSource == nil ? "This phone" : host.cameras.first { host.cameraIDs[$0.id] == engine.programSource }?.name ?? "Camera").padding(8) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView(landscape ? .vertical : .horizontal, showsIndicators: false) {
                OrientationStack(isLandscape: !landscape, spacing: 8) {
                    sourceThumbnail(id: nil, name: "This phone") { MultiCamFramePreview(pixelBuffer: { engine.latestFrame }) }
                    ForEach(host.cameras) { peer in
                        if let feed = host.feed(for: peer) {
                            sourceThumbnail(id: feed.id, name: peer.name) {
                                MultiCamFeedView(feed: feed).overlay(alignment: .topLeading) { if !peer.hasVideo { waitingBadge } }
                            }
                        }
                    }
                    if host.cameras.isEmpty {
                        Text("Waiting for cameras…").font(.caption).foregroundStyle(.white.opacity(0.6)).frame(width: 150, height: 84)
                    }
                }.padding(8)
            }
            .frame(width: landscape ? 174 : nil, height: landscape ? nil : 104)
            .background(Theme.inkPanel)
        }
        .padding(.top, 52).padding(.bottom, landscape ? 96 : 150)
    }

    private func sourceThumbnail<Content: View>(id: UUID?, name: String, @ViewBuilder _ content: () -> Content) -> some View {
        let isLive = engine.programSource == id
        return Button { host.switchProgram(to: id) } label: {
            content()
                .frame(width: 150, height: 84)
                .clipShape(.rect(cornerRadius: Theme.Radius.small))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).stroke(isLive ? Color.red : .white.opacity(0.25), lineWidth: isLive ? 2 : 1))
                .overlay(alignment: .bottomLeading) {
                    Text(name).font(.caption2.bold()).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: .capsule).padding(5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cut to \(name)").accessibilityValue(isLive ? "Live" : "Preview")
        .accessibilityIdentifier("multicam-source-\(id?.uuidString ?? "local")")
    }

    private func liveBadge(_ name: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 7, height: 7)
            Text("LIVE · \(name)").font(.caption.bold()).lineLimit(1)
        }.padding(.horizontal, 8).padding(.vertical, 5).background(.black.opacity(0.55), in: .capsule)
    }

    private var waitingBadge: some View {
        Text("Connecting…").font(.caption2).padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.6), in: .capsule).padding(6)
    }

    @ViewBuilder private var notReadyOverlay: some View {
        if !engine.isReady {
            VStack(spacing: 12) {
                if engine.isConfiguring { ProgressView().tint(.white) } else { Image(systemName: "camera").font(.title2) }
                Text(engine.statusMessage ?? "Preparing camera…").font(.subheadline).multilineTextAlignment(.center)
                if !engine.isConfiguring, !engine.permissionDenied {
                    Button("Try again") { Task { await engine.prepare(quality: .hd) } }.buttonStyle(EditorActionStyle())
                }
            }.padding(20).background(.black.opacity(0.8), in: .rect(cornerRadius: Theme.Radius.medium)).padding(20)
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Button { if isBusy { showingLeaveConfirmation = true } else { dismiss() } } label: { Image(systemName: "chevron.down").frame(width: 20) }
                .accessibilityLabel("Close multi-cam").disabled(engine.isRecording || engine.isFinishing)
            if engine.isRecording {
                CameraTimerCapsule(elapsed: engine.elapsed)
            } else {
                Text(host.project.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 10).frame(height: 34).background(.black.opacity(0.35), in: .capsule)
            }
            Spacer(minLength: 0)
            if host.mode == .dualCamera, !host.cameras.isEmpty {
                Button { aligning.toggle() } label: {
                    Image(systemName: aligning ? "rectangle.inset.filled" : "rectangle.split.2x1").frame(width: 20)
                }
                .buttonStyle(CameraChromeButtonStyle(isActive: aligning))
                .accessibilityLabel("Align cameras")
                .accessibilityValue(aligning ? "Side by side" : "Picture in picture")
                .accessibilityIdentifier("multicam-align-toggle")
            }
            peersChip
        }
        .buttonStyle(CameraChromeButtonStyle()).foregroundStyle(.white)
        .padding(.horizontal, Theme.Space.md).frame(height: 48)
        .background { LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .top) }
    }

    /// Top-right: who is connected. Lime once at least one phone joined.
    private var peersChip: some View {
        let cameras = host.cameras.count, remotes = host.remotes.count
        let text = cameras + remotes == 0 ? "Waiting for phones" : [cameras > 0 ? "\(cameras) camera\(cameras == 1 ? "" : "s")" : nil, remotes > 0 ? "\(remotes) remote\(remotes == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: " · ")
        return Label(text, systemImage: host.mode.symbol).labelStyle(.titleAndIcon)
            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, 10).frame(height: 34)
            .foregroundStyle(cameras + remotes > 0 ? Color.black : .white)
            .background(cameras + remotes > 0 ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(.black.opacity(0.35)), in: .capsule)
            .accessibilityIdentifier("multicam-peers")
    }

    private func dock(landscape: Bool) -> some View {
        VStack(spacing: 6) {
            if let message = host.statusMessage ?? engine.statusMessage, engine.isReady {
                Text(message).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8).background(.black.opacity(0.75), in: .rect(cornerRadius: Theme.Radius.small))
            }
            if host.session.peers.isEmpty, let address = host.session.manualAddress {
                Text("Can't see this session on the other phone? Enter \(address)")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .accessibilityIdentifier("multicam-manual-address")
            }
            if !host.transfers.isEmpty { transferList }
            CameraCaptureDock(isRecording: engine.isRecording, isFinishing: engine.isFinishing,
                canRecord: engine.isReady && !engine.isFinishing && host.awaitingTransfers == 0,
                mode: .full, tagCounts: host.eventCounts, lastTag: host.lastTag, savedCount: host.savedCount, lastSavedDuration: nil,
                bufferProgress: 0, isLandscape: landscape,
                record: { if engine.isRecording { showingStopConfirmation = true } else { host.startRecording() } },
                mark: host.addEvent)
        }
    }

    private var transferList: some View {
        VStack(spacing: 4) {
            ForEach(host.transfers) { transfer in
                HStack(spacing: 8) {
                    Image(systemName: transfer.isDone ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(transfer.isDone ? Theme.signal : .white)
                    Text(transfer.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    if transfer.isDone { Text("Received").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)) }
                    else { ProgressView(value: transfer.fraction).frame(width: 90).tint(Theme.signal); Text("\(Int(transfer.fraction * 100))%").font(.system(size: 11)).monospacedDigit() }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8).background(.black.opacity(0.75), in: .rect(cornerRadius: Theme.Radius.small))
        .padding(.horizontal, Theme.Space.md)
        .accessibilityIdentifier("multicam-transfers")
    }
}
