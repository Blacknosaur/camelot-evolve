import CoreGraphics
import SwiftUI

/// A non-editable field guide shown over the analysis canvas. It deliberately
/// owns no calibration state: the saved calibration is the source of truth and
/// `frozen(at:)` determines whether the camera is covered at the playhead.
struct AnalysisFieldPreview: View {
    let calibration: GroundCalibration?
    let time: Double
    let frame: CGRect
    let bounds: CGRect

    var body: some View {
        let geometry = AnalysisFieldPreviewGeometry.make(calibration: calibration, time: time, frame: frame)
        Canvas { context, _ in
            context.clip(to: Path(frame))
            if !geometry.referencePath.isEmpty {
                context.stroke(Path(geometry.referencePath), with: .color(.white.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
            if !geometry.calibratedPath.isEmpty {
                context.stroke(Path(geometry.calibratedPath), with: .color(.cyan.opacity(0.95)),
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }
        .overlay(alignment: .topLeading) {
            if let status = geometry.status {
                Label(status, systemImage: "exclamationmark.triangle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.72), in: .capsule)
                    .frame(maxWidth: max(1, bounds.width - 16), alignment: .leading)
                    .padding(.leading, bounds.minX + 8)
                    .padding(.top, bounds.minY + 8)
                    .accessibilityIdentifier("analysis-field-preview-status")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("analysis-field-preview")
        .accessibilityLabel("Field preview")
        .accessibilityValue(geometry.status ?? "Calibrated field lines")
    }
}

struct AnalysisFieldPreviewGeometry {
    let referencePath: CGPath
    let calibratedPath: CGPath
    let status: String?

    static func make(calibration: GroundCalibration?, time: Double, frame: CGRect) -> Self {
        guard let calibration, calibration.valid else {
            return .init(referencePath: CGMutablePath(), calibratedPath: CGMutablePath(),
                         status: "Set up field calibration in Measure")
        }
        guard let current = calibration.frozen(at: time) else {
            return .init(referencePath: CGMutablePath(), calibratedPath: CGMutablePath(),
                         status: "Field preview unavailable · camera tracking is not covering this time")
        }
        return .init(referencePath: GroundFieldOverlay.referencePath(calibration: current, frame: frame),
                     calibratedPath: GroundFieldOverlay.path(calibration: current, frame: frame),
                     status: nil)
    }
}
