import Observation
import SwiftData
import SwiftUI

/// A value-type description of an analysis workspace launch. The session and
/// save closure belong to the editor window that requested it.
struct AnalysisWindowLaunch {
    let request: AnalysisWorkspaceRequest
    let session: AnalysisSession
    let save: (CompositionClip) throws -> Void
}

/// Launch values for the field-calibration and visible-field placement windows.
struct CalibrationWindowLaunch {
    let url: URL
    let request: GroundCalibrationRequest
    let apply: (GroundCalibration?) -> Void
}

struct FieldPlacementWindowLaunch {
    let url: URL
    let request: AnalysisFieldPlacementRequest
    let apply: (AnalysisFieldLayout, [CGPoint]) -> Void
}

/// Drives the app's separate macOS windows. Each value is set by the library
/// before opening the matching window.
@MainActor
@Observable
final class AppWindows {
    var cameraProject: Project?
    var editorRecording: Recording?
    var editorComposition: VideoComposition?
    var editorStartsInClips = false
    var composition: VideoComposition?
    var remoteRecording: Recording?
    var analysis: AnalysisWindowLaunch?
    var calibration: CalibrationWindowLaunch?
    var fieldPlacement: FieldPlacementWindowLaunch?

    func openEditor(recording: Recording, composition: VideoComposition? = nil, startsInClips: Bool = false) {
        editorRecording = recording
        editorComposition = composition
        editorStartsInClips = startsInClips
    }

    func resetEditor() {
        editorRecording = nil
        editorComposition = nil
        editorStartsInClips = false
    }
}

enum AppWindowID {
    static let camera = "camera"
    static let editor = "editor"
    static let composition = "composition"
    static let remote = "remote"
    static let analysis = "analysis"
    static let calibration = "calibration"
    static let fieldPlacement = "field-placement"
}

struct CameraWindow: View {
    @Environment(AppWindows.self) private var windows
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let project = windows.cameraProject {
                CameraCaptureView(project: project, appState: appState) { close() }
                    .id(project.id)
            } else {
                ContentUnavailableView("No project selected", systemImage: "video")
                    .task { dismissWindow(id: AppWindowID.camera) }
            }
        }
    }

    private func close() {
        windows.cameraProject = nil
        dismissWindow(id: AppWindowID.camera)
    }
}

struct EditorWindow: View {
    @Environment(AppWindows.self) private var windows
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let recording = windows.editorRecording {
                RecordingEditorView(recording: recording, startsInClips: windows.editorStartsInClips,
                                    composition: windows.editorComposition) { close() }
                    .id(recording.id)
            } else {
                ContentUnavailableView("No video selected", systemImage: "film")
                    .task { dismissWindow(id: AppWindowID.editor) }
            }
        }
    }

    private func close() {
        windows.resetEditor()
        dismissWindow(id: AppWindowID.editor)
    }
}

struct CompositionWindow: View {
    @Environment(AppWindows.self) private var windows
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let composition = windows.composition {
                CompositionPlayerView(composition: composition, allowsDeletion: true) { close() }
                    .id(composition.id)
            } else {
                ContentUnavailableView("No video selected", systemImage: "film")
                    .task { dismissWindow(id: AppWindowID.composition) }
            }
        }
    }

    private func close() {
        windows.composition = nil
        dismissWindow(id: AppWindowID.composition)
    }
}

struct RemoteVideoWindow: View {
    @Environment(AppWindows.self) private var windows
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let recording = windows.remoteRecording {
                RemoteVideoPlayerView(recording: recording) { close() }
                    .id(recording.id)
            } else {
                ContentUnavailableView("No video selected", systemImage: "icloud")
                    .task { dismissWindow(id: AppWindowID.remote) }
            }
        }
    }

    private func close() {
        windows.remoteRecording = nil
        dismissWindow(id: AppWindowID.remote)
    }
}

struct AnalysisWindow: View {
    @Environment(AppWindows.self) private var windows
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let launch = windows.analysis {
                AnalysisWorkspaceView(request: launch.request, session: launch.session, save: launch.save) { close() }
                    .id(launch.request.id)
            } else {
                ContentUnavailableView("No analysis selected", systemImage: "pencil.and.outline")
                    .task { dismissWindow(id: AppWindowID.analysis) }
            }
        }
    }

    private func close() {
        windows.analysis = nil
        dismissWindow(id: AppWindowID.analysis)
    }
}

struct CalibrationWindow: View {
    @Environment(AppWindows.self) private var windows
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let launch = windows.calibration {
                GroundCalibrationSheet(url: launch.url, request: launch.request, apply: launch.apply) { close() }
                    .id(launch.request.id)
            } else {
                ContentUnavailableView("No field selected", systemImage: "sportscourt")
                    .task { dismissWindow(id: AppWindowID.calibration) }
            }
        }
    }

    private func close() {
        windows.calibration = nil
        dismissWindow(id: AppWindowID.calibration)
    }
}

struct FieldPlacementWindow: View {
    @Environment(AppWindows.self) private var windows
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let launch = windows.fieldPlacement {
                AnalysisFieldPlacementView(url: launch.url, request: launch.request, apply: launch.apply) { close() }
                    .id(launch.request.id)
            } else {
                ContentUnavailableView("No field selected", systemImage: "sportscourt")
                    .task { dismissWindow(id: AppWindowID.fieldPlacement) }
            }
        }
    }

    private func close() {
        windows.fieldPlacement = nil
        dismissWindow(id: AppWindowID.fieldPlacement)
    }
}