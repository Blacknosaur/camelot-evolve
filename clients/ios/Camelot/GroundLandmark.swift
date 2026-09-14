import Foundation

/// Common full-size football pitch references. Dimensions are editable in the
/// sheet because local competitions can use different field markings.
/// Source: IFAB Law 1, The Field of Play
/// https://www.theifab.com/laws/latest/the-field-of-play/
enum GroundLandmark: String, CaseIterable, Identifiable, Sendable {
    case custom
    case penaltyArea
    case goalArea
    case centreCircle
    case goalWidth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: "Custom"
        case .penaltyArea: "Penalty area"
        case .goalArea: "Goal area"
        case .centreCircle: "Centre circle"
        case .goalWidth: "Goal width"
        }
    }

    var mode: GroundCalibration.Mode {
        switch self {
        case .penaltyArea, .goalArea: .plane
        case .custom, .centreCircle, .goalWidth: .localScale
        }
    }

    var pointCount: Int { mode == .plane ? 4 : 2 }

    /// Side 1–2 in the sheet (the side parallel to the goal line).
    var defaultLengthMeters: Double {
        switch self {
        case .penaltyArea: 7.32 + 2 * 16.5
        case .goalArea: 7.32 + 2 * 5.5
        case .centreCircle: 2 * 9.15
        case .goalWidth: 7.32
        case .custom: 0
        }
    }

    /// Side 2–3 in the sheet (the depth away from the goal line).
    var defaultWidthMeters: Double {
        switch self {
        case .penaltyArea: 16.5
        case .goalArea: 5.5
        case .custom, .centreCircle, .goalWidth: 0
        }
    }

    var isApproximate: Bool { mode == .localScale }

    var guidance: String {
        switch self {
        case .custom: "Choose two points for a known distance, or four corners of a real ground rectangle."
        case .penaltyArea: "Points 1–2: the two corners on the goal line (40.32 m). Continue clockwise to corners 3–4 out on the field (16.5 m deep). Full-size football defaults; edit for your pitch."
        case .goalArea: "Points 1–2: the two corners on the goal line (18.32 m). Continue clockwise to corners 3–4 out on the field (5.5 m deep). Full-size football defaults; edit for your pitch."
        case .centreCircle: "Two opposite points where the centre circle meets the halfway line. Approximate local scale; no ground-plane homography."
        case .goalWidth: "Two inside edges of the goalposts on the ground. Approximate local scale; this does not model the vertical goal face."
        }
    }
}
