import Foundation

enum AnnotationLinePattern: String, Codable, CaseIterable, Identifiable, Sendable {
    case solid, dashed, dotted
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum AnnotationEndpoint: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, arrow, circle, point
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// Presentation-only line styling. Nil on old annotations means the legacy
/// solid stroke; callers can use `resolved` when drawing persisted content.
struct AnnotationLineStyle: Codable, Equatable, Sendable {
    var pattern: AnnotationLinePattern = .solid
    var start: AnnotationEndpoint = .none
    var end: AnnotationEndpoint = .none

    static let `default` = Self()
    static let legacyArrow = Self(pattern: .solid, start: .none, end: .arrow)

    init(pattern: AnnotationLinePattern = .solid, start: AnnotationEndpoint = .none, end: AnnotationEndpoint = .none) {
        self.pattern = pattern
        self.start = start
        self.end = end
    }
}

extension AnnotationLineStyle {
    func dashLengths(for width: CGFloat) -> [CGFloat] {
        switch pattern {
        case .solid: []
        case .dashed: [max(4, width * 5), max(3, width * 3.5)]
        case .dotted: [max(1, width * 0.8), max(3, width * 3)]
        }
    }
}
