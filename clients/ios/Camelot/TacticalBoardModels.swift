import Foundation
import SwiftData
import SwiftUI

// MARK: - Persistence

/// A standalone tactical/drill board (the Boards tab). The editable content is a versioned
/// `BoardDocument` stored as JSON so the schema can evolve without migrations.
/// Boards used to belong to a project (`projectID`); that column was dropped, which SwiftData
/// migrates automatically (see `TacticalBoardTests.testLegacyStoreWithProjectIDMigrates`).
@Model
final class TacticalBoard {
    @Attribute(.unique) var id: UUID
    var name: String
    var fieldType: String
    var viewAngle: String
    var createdAt: Date
    var updatedAt: Date
    var document: Data

    init(name: String, document: BoardDocument = BoardDocument()) {
        id = UUID()
        self.name = name
        fieldType = document.fieldType.rawValue
        viewAngle = document.viewAngle.rawValue
        createdAt = .now
        updatedAt = .now
        self.document = (try? JSONEncoder().encode(document)) ?? Data()
    }

    /// The stored document. Throws when the bytes cannot be read: corrupt or truncated JSON, a key
    /// this build does not know, an unknown enum value, or a document from a newer app version.
    /// A board that cannot be read must never be overwritten, so `store` refuses to write over one.
    func load() throws -> BoardDocument {
        if let memoised = BoardDocumentMemo.shared.document(id: id, data: document) { return memoised }
        let decoded: BoardDocument
        do {
            decoded = try JSONDecoder().decode(BoardDocument.self, from: document)
        } catch {
            throw BoardLoadError.unreadable
        }
        guard decoded.version <= BoardDocument.currentVersion else { throw BoardLoadError.newerVersion(decoded.version) }
        let migrated = decoded.migratingLegacyPaths()
        BoardDocumentMemo.shared.store(id: id, data: document, document: migrated)
        return migrated
    }

    /// The stored document, or nil when it cannot be read.
    var loadedDocument: BoardDocument? { try? load() }

    /// Whether the stored bytes can be read back (and therefore safely replaced).
    var isReadable: Bool { loadedDocument != nil }

    /// Read-only convenience for callers that can live with an empty board (previews, counts).
    /// Never use it to decide what to save: it hides an unreadable board as an empty one.
    var decodedDocument: BoardDocument { loadedDocument ?? BoardDocument() }

    /// Stores a new document version and bumps `updatedAt`. Returns false (and writes nothing) when the
    /// board's current bytes cannot be read, so an editor that fell back to an empty document — or any
    /// other caller working from one — can never overwrite a real board.
    @discardableResult
    func store(_ document: BoardDocument) -> Bool {
        guard isReadable, let data = try? JSONEncoder().encode(document) else { return false }
        self.document = data
        // What was just written is known-good, so the next save's readability check is a memcmp.
        BoardDocumentMemo.shared.store(id: id, data: data, document: document)
        fieldType = document.fieldType.rawValue
        viewAngle = document.viewAngle.rawValue
        updatedAt = .now
        return true
    }

    static var folder: URL { URL.documentsDirectory.appending(path: "TacticalBoards", directoryHint: .isDirectory) }
    /// Versioned so thumbnails drawn by an older renderer are regenerated.
    var thumbnailURL: URL { Self.folder.appending(path: "\(id.uuidString)-v2.png") }
    /// Every thumbnail file this board may have written, including older renderer versions.
    var allThumbnailURLs: [URL] { [thumbnailURL, Self.folder.appending(path: "\(id.uuidString).png")] }

    var field: BoardFieldType { BoardFieldType(rawValue: fieldType) ?? .footballFull }

    /// Removes the board and its thumbnails.
    @MainActor func delete(from modelContext: ModelContext) {
        for url in allThumbnailURLs { try? FileManager.default.removeItem(at: url) }
        modelContext.delete(self)
    }

    /// Inserts a copy of this board, carrying its thumbnail over so the new card is not blank.
    /// Throws (and inserts nothing) when this board cannot be read, rather than copying an empty one.
    @MainActor @discardableResult
    func duplicate(into modelContext: ModelContext) throws -> TacticalBoard {
        let copy = TacticalBoard(name: "\(name) copy", document: try load())
        modelContext.insert(copy)
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: thumbnailURL, to: copy.thumbnailURL)
        return copy
    }
}

/// Remembers the last board decoded, keyed by its exact bytes. Decoding is by far the most expensive
/// thing the editor's `init` does, and SwiftUI re-creates that view whenever the boards list re-queries —
/// which every autosave does, by bumping `updatedAt`. A re-open of the same bytes is then a memcmp.
private final class BoardDocumentMemo: @unchecked Sendable {
    static let shared = BoardDocumentMemo()
    private let lock = NSLock()
    private var entry: (id: UUID, data: Data, document: BoardDocument)?

    func document(id: UUID, data: Data) -> BoardDocument? {
        lock.withLock {
            guard let entry, entry.id == id, entry.data == data else { return nil }
            return entry.document
        }
    }

    func store(id: UUID, data: Data, document: BoardDocument) {
        lock.withLock { entry = (id, data, document) }
    }
}

/// Why a stored board could not be opened.
enum BoardLoadError: Error, Equatable {
    /// The JSON is corrupt, truncated, or holds a value this build does not understand.
    case unreadable
    /// Written by a newer version of the app; opening it here would drop what it does not know.
    case newerVersion(Int)

    /// Message shown to the user in the editor and the board list.
    var message: String {
        switch self {
        case .unreadable: "This board could not be opened."
        case .newerVersion: "This board was made with a newer version of Camelot."
        }
    }
}

// MARK: - Document

struct BoardPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    static let center = BoardPoint(0.5, 0.5)

    func offset(dx: Double, dy: Double) -> BoardPoint { BoardPoint(x + dx, y + dy) }
    func clamped() -> BoardPoint { BoardPoint(min(1, max(0, x)), min(1, max(0, y))) }
    func lerp(to other: BoardPoint, _ t: Double) -> BoardPoint { BoardPoint(x + (other.x - x) * t, y + (other.y - y) * t) }
}

enum BoardFieldType: String, Codable, CaseIterable, Sendable {
    case footballFull, footballHalf, futsal, basketball, blank

    var title: String {
        switch self {
        case .footballFull: "Full pitch"
        case .footballHalf: "Half pitch"
        case .futsal: "Futsal"
        case .basketball: "Basketball"
        case .blank: "Blank grid"
        }
    }

    var symbol: String {
        switch self {
        case .footballFull, .footballHalf: "sportscourt"
        case .futsal: "rectangle"
        case .basketball: "basketball"
        case .blank: "grid"
        }
    }

    /// Playing-surface size in metres: x is the length axis (u), y is the width axis (v).
    /// The half pitch is defined with its goal line at v = 0 so it never needs rotating.
    var meters: CGSize {
        switch self {
        case .footballFull: CGSize(width: 105, height: 68)
        case .footballHalf: CGSize(width: 68, height: 52.5)
        case .futsal: CGSize(width: 40, height: 20)
        case .basketball: CGSize(width: 28, height: 15)
        case .blank: CGSize(width: 30, height: 20)
        }
    }

    /// Base size of drawn elements: 1% of the field's shorter side. 2D and 3D both size
    /// players, balls and equipment in these units so they match and trim lines alike.
    var elementUnitMeters: Double { 0.01 * Double(min(meters.width, meters.height)) }

    /// Whether the length axis turns to run down the screen in a portrait view.
    var rotatesInPortrait: Bool { self != .footballHalf }
    var usesBasketball: Bool { self == .basketball }
}

enum BoardViewAngle: String, Codable, CaseIterable, Sendable {
    case top, tilted, broadcast

    var title: String {
        switch self {
        case .top: "Top"
        case .tilted: "Tilted"
        case .broadcast: "Broadcast"
        }
    }

    var symbol: String {
        switch self {
        case .top: "square"
        case .tilted: "perspective"
        case .broadcast: "tv"
        }
    }

    /// Tilted and Broadcast render the board as a real 3D scene (see `TacticalBoard3DView`).
    var is3D: Bool { self != .top }

    /// Default orbit camera for this preset.
    var defaultCamera: BoardCamera {
        switch self {
        case .top: BoardCamera(azimuthDegrees: 0, elevationDegrees: 89, distanceScale: 1)
        case .tilted: BoardCamera(azimuthDegrees: 0, elevationDegrees: 38, distanceScale: 1)
        case .broadcast: BoardCamera(azimuthDegrees: 14, elevationDegrees: 22, distanceScale: 1)
        }
    }
}

/// Orbit camera for 3D views, stored in the document so exports match the screen.
/// Azimuth is relative to the viewport, like the 2D top view: 0 tilts the top view towards the
/// viewer, so the field's long axis runs along the screen's long axis (across a landscape
/// screen, from the v = 1 touchline; down a portrait screen, from behind the u = 1 goal line).
/// Positive azimuth turns the camera around the target. Distance 1 fits the projected field
/// snugly into the viewport.
struct BoardCamera: Codable, Equatable, Sendable {
    var azimuthDegrees: Double
    var elevationDegrees: Double
    var distanceScale: Double
    /// Field point the camera orbits (normalised 0…1).
    var target = BoardPoint.center
    // Everything below is Optional so boards saved before camera modes still decode (as orbit cameras).
    // The orbit fields above are kept in every mode: they are where "Orbit" returns to and the
    // fallback when a point-of-view subject no longer exists.
    /// nil is `.orbit`.
    var mode: BoardCameraMode? = nil
    /// Free camera: eye position on the field (normalised; may lie a little outside 0…1).
    var eye: BoardPoint? = nil
    /// Free camera: eye height above the ground in metres.
    var eyeHeightMeters: Double? = nil
    /// Free camera: look direction, degrees clockwise on the top view (0 looks towards u = 1),
    /// the same convention as element rotation.
    var yawDegrees: Double? = nil
    /// Free camera: degrees above the horizon; negative looks down.
    var pitchDegrees: Double? = nil
    /// Free and point-of-view cameras: angle across the shorter side of the view (nil: 55° free, 65° POV).
    var fieldOfViewDegrees: Double? = nil
    /// Point of view: the element whose eyes the camera looks through.
    var subjectID: UUID? = nil
    /// Point of view: where the subject looks (nil is `.facing`).
    var lookAt: BoardCameraLookAt? = nil

    var resolvedMode: BoardCameraMode { mode ?? .orbit }
    var isOrbit: Bool { resolvedMode == .orbit }
    /// True when free fields are present (used as the fallback for a lost point-of-view subject).
    var hasFreePose: Bool { eye != nil && yawDegrees != nil }

    /// This camera with orbit mode and no subject: returns to the stored orbit.
    var orbiting: BoardCamera {
        var copy = self
        copy.mode = nil
        copy.subjectID = nil
        return copy
    }

    /// A point-of-view camera on `subject`, keeping this camera's orbit and free fields as fallbacks.
    func pointOfView(subject: UUID, lookAt: BoardCameraLookAt = .facing) -> BoardCamera {
        var copy = self
        copy.mode = .pointOfView
        copy.subjectID = subject
        copy.lookAt = lookAt
        return copy
    }

    /// Interpolates two cameras; azimuth takes the shortest way round.
    static func lerp(_ a: BoardCamera, _ b: BoardCamera, _ t: Double) -> BoardCamera {
        let delta = (b.azimuthDegrees - a.azimuthDegrees + 540).truncatingRemainder(dividingBy: 360) - 180
        var azimuth = (a.azimuthDegrees + delta * t).truncatingRemainder(dividingBy: 360)
        if azimuth < 0 { azimuth += 360 }
        return BoardCamera(azimuthDegrees: azimuth,
                           elevationDegrees: a.elevationDegrees + (b.elevationDegrees - a.elevationDegrees) * t,
                           distanceScale: a.distanceScale + (b.distanceScale - a.distanceScale) * t,
                           target: a.target.lerp(to: b.target, t))
    }
}

/// How a 3D camera is placed: orbiting a target, walking freely, or through an element's eyes.
enum BoardCameraMode: String, Codable, CaseIterable, Sendable { case orbit, free, pointOfView }

/// Where a point-of-view camera looks.
enum BoardCameraLookAt: Codable, Equatable, Sendable {
    /// Along the subject's rotation.
    case facing
    /// At the nearest ball.
    case ball
    /// At another element.
    case element(UUID)
    /// A fixed direction, degrees clockwise on the top view.
    case fixed(yawDegrees: Double)
}

/// Visual theme for the playing surface and markings, shared by 2D, 3D and exports.
enum BoardFieldStyle: String, Codable, CaseIterable, Sendable {
    case grass, night, classic, chalk, court

    var title: String {
        switch self {
        case .grass: "Natural grass"
        case .night: "Floodlit"
        case .classic: "Classic"
        case .chalk: "Chalkboard"
        case .court: "Indoor court"
        }
    }

    /// Sensible default per field: wooden floor indoors, grass outside.
    static func defaultStyle(for field: BoardFieldType) -> BoardFieldStyle {
        field == .basketball || field == .futsal ? .court : .grass
    }
}

enum BoardElementKind: String, Codable, CaseIterable, Sendable {
    case player, goalkeeper, opponent, ball, cone, marker, miniGoal, mannequin, text, arrow, zone, polygon, line, polyline
    // Training library (all point elements).
    case tallCone, domeCone, pole, hurdle, ladder, ring, wall, goal, popUpGoal, rebounder, flag, ballCart, coach, referee, stepMarker

    /// Elements anchored at a single field point (players, equipment, text). Lines can attach to these.
    var isPoint: Bool { ![.arrow, .zone, .polygon, .line, .polyline].contains(self) }
    var isPerson: Bool { [.player, .goalkeeper, .opponent].contains(self) }
    /// Staff figures drawn like players (no team number).
    var isStaff: Bool { self == .coach || self == .referee }
    /// `line` is a straight or curved 2-point line (legacy freehand lines have more points and draw as
    /// polylines); `polyline` has any number of vertices; legacy `arrow` draws as a line with caps.
    var isLineLike: Bool { [.arrow, .line, .polyline].contains(self) }
    var isArea: Bool { self == .zone || self == .polygon }

    /// Painting order: areas first, then lines, then upright objects.
    var zOrder: Int {
        switch self {
        case .zone, .polygon: 0
        case .line, .arrow, .polyline: 1
        case .marker, .domeCone, .ring, .ladder, .stepMarker: 2
        case .miniGoal, .cone, .mannequin, .tallCone, .pole, .hurdle, .wall, .goal, .popUpGoal, .rebounder, .flag, .ballCart: 3
        case .ball: 4
        case .player, .goalkeeper, .opponent, .coach, .referee: 5
        case .text: 6
        }
    }
}

enum BoardArrowStyle: String, Codable, CaseIterable, Sendable {
    case pass, run, dribble

    var title: String {
        switch self {
        case .pass: "Pass"
        case .run: "Run"
        case .dribble: "Dribble"
        }
    }
}

enum BoardZoneShape: String, Codable, Sendable { case rectangle, ellipse }

enum BoardLinePattern: String, Codable, CaseIterable, Sendable { case solid, dashed, dotted }
enum BoardLineShape: String, Codable, CaseIterable, Sendable { case straight, wavy, zigzag }
enum BoardLineCap: String, Codable, CaseIterable, Sendable { case none, arrow, bar, dot }

/// Appearance of a line, polyline or legacy arrow.
struct BoardLineStyle: Codable, Equatable, Sendable {
    var pattern: BoardLinePattern = .solid
    var shape: BoardLineShape = .straight
    var startCap: BoardLineCap = .none
    var endCap: BoardLineCap = .arrow
    /// Multiplier of the default stroke width (0.8 element units).
    var width: Double = 1
    /// Stroke opacity 0…1; nil is fully opaque. Optional so styles without it decode.
    var opacity: Double? = nil

    var strokeOpacity: Double { min(1, max(0.05, opacity ?? 1)) }

    static let pass = BoardLineStyle()
    static let run = BoardLineStyle(pattern: .dashed)
    static let dribble = BoardLineStyle(shape: .wavy)
    static let plain = BoardLineStyle(endCap: .none)
}

/// Every position an element owns. Keyframes store one pose per element.
struct BoardPose: Codable, Equatable, Sendable {
    var position: BoardPoint
    var points: [BoardPoint] = []
    /// Degrees. Nil in keyframes saved before rotation was animatable: keep the element's value.
    var rotation: Double? = nil
    /// Scale multiplier. Nil in older keyframes: keep the element's value.
    var size: Double? = nil
    /// Line or shape this element sits on in this keyframe. Between two keyframes on the same path the element
    /// travels along it; otherwise it moves in a straight line between the resolved points.
    var pathID: UUID? = nil
    /// Arc-length progress along `pathID`, 0…1. On closed shapes values past 1 (or below 0) are extra laps;
    /// decreasing progress travels backwards.
    var pathProgress: Double? = nil
    /// Turn to face the direction of travel along the path.
    var facesPath: Bool? = nil

    func lerp(to other: BoardPose, _ t: Double) -> BoardPose {
        var result = BoardPose(position: position.lerp(to: other.position, t))
        result.points = other.points.indices.map { index in
            points.indices.contains(index) ? points[index].lerp(to: other.points[index], t) : other.points[index]
        }
        switch (rotation, other.rotation) {
        case let (from?, to?):
            // Shortest way round, so 350° → 10° turns 20°, not 340°.
            let delta = (to - from + 540).truncatingRemainder(dividingBy: 360) - 180
            result.rotation = from + delta * t
        case let (from, to): result.rotation = to ?? from
        }
        switch (size, other.size) {
        case let (from?, to?): result.size = from + (to - from) * t
        case let (from, to): result.size = to ?? from
        }
        return result
    }

    func translated(dx: Double, dy: Double) -> BoardPose {
        var moved = self
        moved.position = position.offset(dx: dx, dy: dy)
        moved.points = points.map { $0.offset(dx: dx, dy: dy) }
        return moved
    }
}

/// One thing on the board. `position` is the anchor; `points` are the other
/// coordinates: arrow end (and curve control), zone opposite corner, or vertices.
/// All coordinates are normalised to the field (0…1) so any field size works.
struct BoardElement: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: BoardElementKind
    var position: BoardPoint
    var points: [BoardPoint] = []
    var colorHex: String = BoardPalette.white
    var number: Int? = nil
    var label = ""
    var size: Double = 1
    /// Fill opacity of zones and polygons.
    var opacity: Double = 0.3
    /// Degrees, clockwise on the top view. 0 faces +x (along the length axis towards x = 1).
    /// Point elements and zones draw rotated; for lines and polygons the rotation is already applied
    /// to their points and this only tracks the accumulated angle for the inspector.
    var rotation: Double = 0
    var arrowStyle: BoardArrowStyle = .pass
    var isCurved = false
    var isDoubleHeaded = false
    var hasBlockEnd = false
    var zoneShape: BoardZoneShape = .rectangle
    // Everything below is Optional so documents saved before it existed still decode.
    /// Line appearance; nil derives it from the legacy arrow flags (see `resolvedLineStyle`).
    var lineStyle: BoardLineStyle? = nil
    /// Point element the first / last vertex is connected to. The vertex follows that element's centre.
    var startAttachment: UUID? = nil
    var endAttachment: UUID? = nil
    /// Zone/polygon border pattern; nil is solid.
    var borderPattern: BoardLinePattern? = nil
    /// Zone/polygon border visibility; nil shows the border.
    var showsBorder: Bool? = nil
    /// Mannequins in a `wall` (2…6); nil is 4.
    var count: Int? = nil
    /// Lines and polylines: label the length in metres.
    var showsLength: Bool? = nil
    /// Lines and polylines: peak height above the ground in metres (a lofted pass or shot). nil/0 is flat.
    var arcHeightMeters: Double? = nil
    /// Height in metres where the line starts and ends; nil is ground level.
    var startHeightMeters: Double? = nil
    var endHeightMeters: Double? = nil
    /// Runtime only: height in metres of an element following an aerial line at the drawn moment.
    /// `elements(at:)` sets it on the copies it returns; it is never stored on the board's own elements.
    var heightMeters: Double? = nil
    /// Runtime only: direction of travel where that height was sampled, so 2D lifts the element the same
    /// way it bows the line (perpendicular to the path, towards the top of the screen).
    var heightDirectionDegrees: Double? = nil
    /// Squad player this person is linked to (`SquadPlayer.id`); number and label refresh from it.
    var playerID: UUID? = nil

    static let wallCountRange = 2...6
    var wallCount: Int { min(Self.wallCountRange.upperBound, max(Self.wallCountRange.lowerBound, count ?? 4)) }

    var pose: BoardPose {
        get { BoardPose(position: position, points: points, rotation: rotation, size: size) }
        set {
            position = newValue.position; points = newValue.points
            if let value = newValue.rotation { rotation = value }
            if let value = newValue.size { size = value }
        }
    }

    /// Anchor plus every editable point, in handle order.
    var allPoints: [BoardPoint] { [position] + points }

    var arrowEnd: BoardPoint { points.first ?? position }
    var arrowControl: BoardPoint? { curveControl }
    var opposite: BoardPoint { points.first ?? position }

    var isLineLike: Bool { kind.isLineLike }

    /// True when this line leaves the ground anywhere.
    var isAerial: Bool { (arcHeightMeters ?? 0) > 0.01 || (startHeightMeters ?? 0) > 0.01 || (endHeightMeters ?? 0) > 0.01 }

    /// Height in metres at an arc-length fraction: a quadratic through the start, the peak and the end.
    /// The peak equals `arcHeightMeters` when it clears the line between the two ends.
    func lineHeightMeters(at fraction: Double) -> Double {
        let start = startHeightMeters ?? 0, end = endHeightMeters ?? 0, peak = arcHeightMeters ?? 0
        let f = min(1, max(0, fraction))
        let chord = start + (end - start) * f
        let bump = max(0, peak - (start + end) / 2)
        return chord + 4 * bump * f * (1 - f)
    }

    static let arcHeightRange = 0.0...20.0

    /// Whether this is a 2-vertex line (`position` → `points[0]`, optional control in `points[1]`).
    /// Legacy freehand lines with more points are polylines.
    private var isTwoPointLine: Bool {
        kind == .arrow || (kind == .line && (isCurved || points.count <= 1))
    }

    /// Vertices from start to end.
    var lineVertices: [BoardPoint] {
        guard isLineLike else { return [] }
        return isTwoPointLine ? [position, arrowEnd] : allPoints
    }

    /// Quadratic Bézier control of a curved 2-vertex line.
    var curveControl: BoardPoint? {
        isTwoPointLine && isCurved && points.count >= 2 ? points[1] : nil
    }

    /// Segments a curved line is sampled into. Drawing, the length label and follow-path geometry all
    /// measure the same polyline, so the "12.4 m" pill matches the drawn stroke and a follower sits on it.
    static let curveSampleCount = 64

    /// A quadratic Bézier as a polyline, in the parameter steps every part of the app agrees on.
    static func curveSamples(from start: BoardPoint, control: BoardPoint, to end: BoardPoint, count: Int = curveSampleCount) -> [BoardPoint] {
        let steps = max(1, count)
        return (0...steps).map { index in
            let t = Double(index) / Double(steps), u = 1 - t
            return BoardPoint(u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                              u * u * start.y + 2 * u * t * control.y + t * t * end.y)
        }
    }

    /// The line's geometry as a polyline: a curved 2-vertex line sampled, anything else its vertices.
    func lineGeometry(sampleCount: Int = curveSampleCount) -> [BoardPoint] {
        let vertices = lineVertices
        guard vertices.count >= 2, let control = curveControl else { return vertices }
        return Self.curveSamples(from: vertices[0], control: control, to: vertices[1], count: sampleCount)
    }

    /// Index in `allPoints` of the last vertex.
    var lastVertexIndex: Int { isTwoPointLine ? 1 : points.count }

    var resolvedLineStyle: BoardLineStyle {
        if let lineStyle { return lineStyle }
        switch kind {
        case .arrow:
            return BoardLineStyle(pattern: arrowStyle == .run ? .dashed : .solid, shape: arrowStyle == .dribble ? .wavy : .straight,
                                  startCap: isDoubleHeaded ? .arrow : .none, endCap: hasBlockEnd ? .bar : .arrow, width: size)
        default:
            return BoardLineStyle(endCap: .none, width: size)
        }
    }

    var resolvedBorderPattern: BoardLinePattern? { showsBorder == false ? nil : (borderPattern ?? .solid) }

    /// Moves the first or last vertex (keeping a curve's control roughly in place relative to the ends).
    mutating func setEndpoint(start: Bool, to point: BoardPoint) {
        if start {
            if let control = curveControl { points[1] = control.offset(dx: (point.x - position.x) / 2, dy: (point.y - position.y) / 2) }
            position = point
        } else if isTwoPointLine {
            let end = arrowEnd
            if points.isEmpty { points = [point] } else { points[0] = point }
            if let control = curveControl { points[1] = control.offset(dx: (point.x - end.x) / 2, dy: (point.y - end.y) / 2) }
        } else if points.isEmpty {
            points = [point]
        } else {
            points[points.count - 1] = point
        }
    }

    /// Centre for rotating and scaling: the zone centre, else the mean of all points.
    var pivot: BoardPoint {
        if kind == .zone { return position.lerp(to: opposite, 0.5) }
        if kind.isPoint { return position }
        let list = isLineLike ? lineVertices : allPoints
        guard !list.isEmpty else { return position }
        return BoardPoint(list.map(\.x).reduce(0, +) / Double(list.count), list.map(\.y).reduce(0, +) / Double(list.count))
    }

    static let sizeRange = 0.4...3.0

    /// A copy turned to `rotation` degrees and scaled by `scale` relative to this element.
    /// Point elements store rotation and size (clamped to `sizeRange`). Zones store rotation and scale
    /// their corners. Lines and polygons rotate and scale their points around `pivot` in metres
    /// (normalised coordinates are not square) and accumulate `rotation` for the inspector.
    func transformed(rotation newRotation: Double, scale: Double, field: BoardFieldType) -> BoardElement {
        var copy = self
        copy.rotation = newRotation
        if kind.isPoint {
            copy.size = min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, size * scale))
            return copy
        }
        let center = pivot
        let delta = kind == .zone ? 0 : (newRotation - rotation) * .pi / 180
        let w = Double(field.meters.width), h = Double(field.meters.height)
        let move: (BoardPoint) -> BoardPoint = { p in
            let dx = (p.x - center.x) * w * scale, dy = (p.y - center.y) * h * scale
            return BoardPoint(center.x + (dx * cos(delta) - dy * sin(delta)) / w, center.y + (dx * sin(delta) + dy * cos(delta)) / h)
        }
        copy.position = move(position)
        copy.points = points.map(move)
        return copy
    }

    /// Screen-independent radius of a point element in metres, used to trim attached line ends.
    func visualRadiusMeters(field: BoardFieldType) -> Double {
        let unit = field.elementUnitMeters
        switch kind {
        case .player, .goalkeeper, .opponent: return 3.1 * unit * size
        case .ball: return 1.5 * unit * size
        case .cone: return 2.0 * unit * size
        case .marker: return 1.6 * unit * size
        case .miniGoal: return 2.6 * unit * size
        case .mannequin: return 2.8 * unit * size
        case .text: return 2.2 * unit * size
        case .tallCone: return 2.2 * unit * size
        case .domeCone: return 1.5 * unit * size
        case .pole: return 1.3 * unit * size
        case .hurdle: return 3.0 * unit * size
        // Long elements: radius is half their length along the local x axis.
        case .ladder: return 10 * unit * size
        case .ring: return 2.6 * unit * size
        case .wall: return (1.4 * Double(wallCount) + 0.4) * unit * size
        /// A real 7.32 m goal on football pitches; smaller surfaces keep it proportionate.
        case .goal: return min(3.66, 8 * unit) * size
        case .popUpGoal: return 3.4 * unit * size
        case .rebounder: return 3.6 * unit * size
        case .flag: return 2.1 * unit * size
        case .ballCart: return 2.6 * unit * size
        case .coach, .referee: return 3.1 * unit * size
        case .stepMarker: return 2.3 * unit * size
        default: return 0
        }
    }
}

struct BoardKeyframe: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    /// Seconds spent moving to the next frame (or holding, for the last frame).
    var duration: Double = 1
    var poses: [UUID: BoardPose] = [:]
    /// How elements travel from this keyframe to the next along a line or shape, keyed by the moving
    /// element's id. Optional so older boards decode.
    var paths: [UUID: BoardFollowPath]? = nil
    /// This stage's 3D view; nil = no camera key. Optional so older boards decode.
    var camera: BoardCamera? = nil
}

/// A move along another element: a line-like element (open path) or a zone/polygon outline (closed loop).
/// `startFraction`/`endFraction` are positions along the path geometry (0 = its first vertex, 1 = its last,
/// or once round a loop). On open paths `reversed` swaps them (travel from end to start); on loops it
/// travels counter-clockwise, fractions may wrap, and `laps` adds full loops.
struct BoardFollowPath: Codable, Equatable, Sendable {
    var pathID: UUID
    var reversed = false
    var startFraction: Double = 0
    var endFraction: Double = 1
    var laps: Int? = nil
    var facesDirection: Bool? = nil
}

struct BoardDocument: Codable, Equatable, Sendable {
    /// Schema version this build writes and is willing to read. Bump it only for a change older builds
    /// must not silently drop; `TacticalBoard.load()` then refuses anything higher instead of opening a
    /// board it would save back incomplete.
    static let currentVersion = 1

    var version = BoardDocument.currentVersion
    var fieldType: BoardFieldType = .footballFull
    var viewAngle: BoardViewAngle = .top
    var homeColorHex = BoardPalette.home
    var awayColorHex = BoardPalette.away
    var elements: [BoardElement] = []
    var keyframes: [BoardKeyframe] = []
    /// Optional so documents saved before these existed still decode.
    var style: BoardFieldStyle? = nil
    var camera: BoardCamera? = nil
    /// Show translucent previous/next keyframes while editing an animation.
    var showsOnionSkin: Bool? = nil

    var fieldStyle: BoardFieldStyle {
        get { style ?? BoardFieldStyle.defaultStyle(for: fieldType) }
        set { style = newValue }
    }
    var cameraOrDefault: BoardCamera {
        get { camera ?? viewAngle.defaultCamera }
        set { camera = newValue }
    }

    var animatesCamera: Bool { keyframes.contains { $0.camera != nil } }

    /// The stage camera keys around `time` and the eased fraction between them (0 while holding
    /// before the first or after the last key); nil when no stage has a camera key.
    /// Keys in different modes (or any non-orbit key) blend in world space in the 3D view
    /// (`BoardCameraResolver`), which needs the viewport and element positions.
    func cameraBlend(at time: Double) -> (from: BoardCamera, to: BoardCamera, fraction: Double)? {
        let keys = keyframes.indices.compactMap { index in keyframes[index].camera.map { (time: frameStart(index), camera: $0) } }
        guard let first = keys.first, let last = keys.last else { return nil }
        if time <= first.time { return (first.camera, first.camera, 0) }
        if time >= last.time { return (last.camera, last.camera, 0) }
        guard let upper = keys.firstIndex(where: { $0.time > time }) else { return (last.camera, last.camera, 0) }
        let a = keys[upper - 1], b = keys[upper]
        let linear = min(1, max(0, (time - a.time) / max(1e-9, b.time - a.time)))
        return (a.camera, b.camera, linear * linear * (3 - 2 * linear))
    }

    /// The camera at a playback time: eases between stages that have a camera key (orbit keys: shortest
    /// azimuth arc, target and distance lerped, same smoothstep easing as elements), holds the nearest key
    /// before the first and after the last key, and returns `cameraOrDefault` when no stage has a key.
    /// Between keys that are not both orbit cameras it returns the nearer key; the rendered camera blends
    /// them in world space (see `cameraBlend(at:)`).
    func camera(at time: Double) -> BoardCamera {
        guard let blend = cameraBlend(at: time) else { return cameraOrDefault }
        if blend.fraction == 0 { return blend.from }
        if blend.from.isOrbit && blend.to.isOrbit { return BoardCamera.lerp(blend.from, blend.to, blend.fraction) }
        return blend.fraction < 0.5 ? blend.from : blend.to
    }

    /// The camera shown when editing stage `index` (its own key, else the interpolated value at its start time).
    func camera(atStage index: Int) -> BoardCamera {
        guard keyframes.indices.contains(index) else { return cameraOrDefault }
        return keyframes[index].camera ?? camera(at: frameStart(index))
    }

    var isAnimated: Bool { !keyframes.isEmpty }
    var duration: Double { keyframes.reduce(0) { $0 + max(0.1, $1.duration) } }

    func frameStart(_ index: Int) -> Double {
        keyframes.prefix(index).reduce(0) { $0 + max(0.1, $1.duration) }
    }

    /// Frame index and eased progress towards the next frame at `time`.
    func frameProgress(at time: Double) -> (index: Int, fraction: Double) {
        guard !keyframes.isEmpty else { return (0, 0) }
        var start = 0.0
        for (index, frame) in keyframes.enumerated() {
            let length = max(0.1, frame.duration)
            if time < start + length || index == keyframes.count - 1 {
                let linear = min(1, max(0, (time - start) / length))
                return (index, linear * linear * (3 - 2 * linear))
            }
            start += length
        }
        return (keyframes.count - 1, 1)
    }

    /// The pose an element has in a frame: its own entry or the latest earlier one.
    /// Elements only exist from the first frame that records them.
    func pose(of id: UUID, atFrame index: Int) -> BoardPose? {
        guard index >= 0 else { return nil }
        for frame in keyframes.prefix(index + 1).reversed() {
            if let pose = frame.poses[id] { return pose }
        }
        return nil
    }

    func visualRadiusMeters(of element: BoardElement) -> Double { element.visualRadiusMeters(field: fieldType) }

    /// Elements as they appear at `time` (or the static layout when `time` is nil or the board is not
    /// animated), with attached line ends moved to the centre of the element they are connected to.
    func elements(at time: Double?) -> [BoardElement] {
        if keyframes.contains(where: { $0.paths?.isEmpty == false }) { return migratingLegacyPaths().elements(at: time) }
        let layout = Self.resolvingAttachments(posedElements(at: time))
        guard let time, isAnimated else { return layout }
        let (index, fraction) = frameProgress(at: time)
        var moved = false
        let followed = layout.map { element -> BoardElement in
            guard element.kind.isPoint, let from = pose(of: element.id, atFrame: index) else { return element }
            let to = index + 1 < keyframes.count ? pose(of: element.id, atFrame: index + 1) : nil
            guard from.pathID != nil || to?.pathID != nil else { return element }
            var copy = element
            if let pathID = from.pathID, let start = from.pathProgress, to == nil || (to?.pathID == pathID && to?.pathProgress != nil),
               let sample = Self.pathSample(pathID: pathID, progress: start + ((to?.pathProgress ?? start) - start) * (to == nil ? 0 : fraction), in: layout, field: fieldType) {
                let end = to?.pathProgress ?? start
                copy.position = sample.point
                if sample.heightMeters > 0.01 {
                    copy.heightMeters = sample.heightMeters
                    copy.heightDirectionDegrees = sample.tangentDegrees
                }
                if (to?.facesPath ?? from.facesPath) == true { copy.rotation = end < start ? normalizedDegrees(sample.tangentDegrees + 180) : sample.tangentDegrees }
            } else {
                // Only one side on a path (or a different one): a straight move between the resolved points.
                let a = Self.resolvedPosition(from, in: layout, field: fieldType)
                let b = to.map { Self.resolvedPosition($0, in: layout, field: fieldType) } ?? a
                copy.position = a.lerp(to: b, to == nil ? 0 : fraction)
            }
            moved = true
            return copy
        }
        return moved ? Self.resolvingAttachments(followed) : layout
    }

    private func posedElements(at time: Double?) -> [BoardElement] {
        guard let time, isAnimated else { return elements }
        let (index, fraction) = frameProgress(at: time)
        return elements.compactMap { element in
            guard let from = pose(of: element.id, atFrame: index) else { return nil }
            var resolved = element
            if index + 1 < keyframes.count, let to = pose(of: element.id, atFrame: index + 1) {
                resolved.pose = from.lerp(to: to, fraction)
            } else {
                resolved.pose = from
            }
            return resolved
        }
    }

    static func resolvingAttachments(_ list: [BoardElement]) -> [BoardElement] {
        guard list.contains(where: { $0.startAttachment != nil || $0.endAttachment != nil }) else { return list }
        var centers: [UUID: BoardPoint] = [:]
        for element in list where element.kind.isPoint { centers[element.id] = element.position }
        return list.map { element in
            guard element.isLineLike else { return element }
            var resolved = element
            if let id = element.startAttachment, let center = centers[id] { resolved.setEndpoint(start: true, to: center) }
            if let id = element.endAttachment, let center = centers[id] { resolved.setEndpoint(start: false, to: center) }
            return resolved
        }
    }

    /// Stores resolved attachment positions into the editable elements, so detaching keeps the line where it is drawn.
    mutating func settleAttachments() {
        elements = Self.resolvingAttachments(elements)
    }

    /// Point element whose centre is nearest `point` within `radius` (normalised, measured in metres), excluding `excluded`.
    func attachmentTarget(near point: BoardPoint, withinMeters radius: Double, excluding excluded: UUID? = nil) -> UUID? {
        let w = Double(fieldType.meters.width), h = Double(fieldType.meters.height)
        return elements
            .filter { $0.kind.isPoint && $0.id != excluded }
            .map { ($0.id, hypot(($0.position.x - point.x) * w, ($0.position.y - point.y) * h)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }

    /// Inserts a vertex halfway between polyline vertices `index` and `index + 1`, in the layout and every keyframe.
    mutating func insertVertex(in id: UUID, after index: Int) {
        func insert(_ pose: inout BoardPose) {
            let all = [pose.position] + pose.points
            guard all.indices.contains(index + 1) else { return }
            pose.points.insert(all[index].lerp(to: all[index + 1], 0.5), at: index)
        }
        guard let element = elements.first(where: { $0.id == id }), element.kind == .polyline || (element.kind == .line && element.lineVertices.count > 2) else { return }
        update(id) { element in var pose = element.pose; insert(&pose); element.pose = pose }
        for frame in keyframes.indices { if var pose = keyframes[frame].poses[id] { insert(&pose); keyframes[frame].poses[id] = pose } }
    }

    /// Removes polyline vertex `index` (keeping at least two), in the layout and every keyframe.
    /// Removing an end vertex drops that end's attachment.
    mutating func removeVertex(in id: UUID, at index: Int) {
        guard let element = elements.first(where: { $0.id == id }), element.kind == .polyline || (element.kind == .line && element.lineVertices.count > 2),
              element.allPoints.count > 2, element.allPoints.indices.contains(index) else { return }
        let last = element.allPoints.count - 1
        func remove(_ pose: inout BoardPose) {
            guard pose.points.count >= 2 else { return }
            if index == 0 { pose.position = pose.points.removeFirst() } else if pose.points.indices.contains(index - 1) { pose.points.remove(at: index - 1) }
        }
        update(id) { element in
            var pose = element.pose; remove(&pose); element.pose = pose
            if index == 0 { element.startAttachment = nil }
            if index == last { element.endAttachment = nil }
        }
        for frame in keyframes.indices { if var pose = keyframes[frame].poses[id] { remove(&pose); keyframes[frame].poses[id] = pose } }
    }

    /// Adds, moves or (with nil) removes the curve control of a 2-point line in the layout and every keyframe.
    /// Frames get the same bend relative to their own endpoints.
    mutating func setCurveControl(of id: UUID, to control: BoardPoint?) {
        guard let element = elements.first(where: { $0.id == id }), element.kind == .line || element.kind == .arrow else { return }
        let start = element.position, end = element.arrowEnd, mid = start.lerp(to: end, 0.5)
        func apply(_ pose: inout BoardPose) {
            let poseEnd = pose.points.first ?? pose.position
            if let control {
                let poseMid = pose.position.lerp(to: poseEnd, 0.5)
                pose.points = [poseEnd, BoardPoint(poseMid.x + control.x - mid.x, poseMid.y + control.y - mid.y)]
            } else {
                pose.points = [poseEnd]
            }
        }
        update(id) { element in
            element.isCurved = control != nil
            var pose = element.pose; apply(&pose); element.pose = pose
        }
        for frame in keyframes.indices { if var pose = keyframes[frame].poses[id] { apply(&pose); keyframes[frame].poses[id] = pose } }
    }

    /// Loads a frame's poses into the editable elements.
    mutating func showFrame(_ index: Int) {
        guard keyframes.indices.contains(index) else { return }
        elements = elements.map { element in
            var copy = element
            if let pose = pose(of: element.id, atFrame: index) { copy.pose = pose }
            return copy
        }
        // Elements on a path sit at their progress point on the path as it is laid out now.
        let layout = Self.resolvingAttachments(elements)
        for i in elements.indices {
            guard let pose = pose(of: elements[i].id, atFrame: index), let pathID = pose.pathID, let progress = pose.pathProgress,
                  let sample = Self.pathLocation(pathID: pathID, progress: progress, in: layout, field: fieldType) else { continue }
            elements[i].position = sample.point
            if pose.facesPath == true { elements[i].rotation = sample.tangentDegrees }
        }
    }

    /// Records the current pose of `id` in `frame` (all elements when `id` is nil).
    mutating func recordPoses(in frame: Int, only id: UUID? = nil) {
        guard keyframes.indices.contains(frame) else { return }
        for element in elements where id == nil || element.id == id {
            var pose = element.pose
            // Keep path membership; dragging along a path updates progress through `setPathProgress`.
            if let previous = keyframes[frame].poses[element.id] ?? self.pose(of: element.id, atFrame: frame) {
                pose.pathID = previous.pathID; pose.pathProgress = previous.pathProgress; pose.facesPath = previous.facesPath
            }
            keyframes[frame].poses[element.id] = pose
        }
    }

    /// Adds a frame after `index` (or at the end) that copies the current layout. Returns its index.
    @discardableResult
    mutating func insertKeyframe(after index: Int?) -> Int {
        var frame = BoardKeyframe()
        let source = index ?? keyframes.count - 1
        for element in elements {
            var pose = element.pose
            if keyframes.indices.contains(source), let previous = self.pose(of: element.id, atFrame: source) {
                pose.pathID = previous.pathID; pose.pathProgress = previous.pathProgress; pose.facesPath = previous.facesPath
            }
            frame.poses[element.id] = pose
        }
        // A new stage starts from its source stage's camera key.
        if keyframes.indices.contains(source) { frame.camera = keyframes[source].camera }
        let target = min(keyframes.count, (index ?? keyframes.count - 1) + 1)
        keyframes.insert(frame, at: target)
        return target
    }

    /// Moves a keyframe. Every frame first records the poses it inherits, so reordering never changes
    /// where elements are in the other frames.
    mutating func moveKeyframe(from source: Int, to destination: Int) {
        guard keyframes.indices.contains(source), keyframes.indices.contains(destination), source != destination else { return }
        var materialised = keyframes
        for index in keyframes.indices {
            for element in elements where materialised[index].poses[element.id] == nil {
                if let pose = pose(of: element.id, atFrame: index) { materialised[index].poses[element.id] = pose }
            }
        }
        let frame = materialised.remove(at: source)
        materialised.insert(frame, at: destination)
        keyframes = materialised
    }

    /// Removes a frame without losing elements whose pose was only recorded there: the pose moves
    /// to the next frame, or to the previous one when deleting the last frame.
    mutating func removeKeyframe(at index: Int) {
        guard keyframes.indices.contains(index) else { return }
        let removed = keyframes.remove(at: index)
        guard !keyframes.isEmpty else { return }
        if index < keyframes.count {
            for (id, pose) in removed.poses where keyframes[index].poses[id] == nil {
                keyframes[index].poses[id] = pose
            }
        } else {
            for (id, pose) in removed.poses where self.pose(of: id, atFrame: index - 1) == nil {
                keyframes[index - 1].poses[id] = pose
            }
        }
    }

    /// Removes an element. Lines connected to it keep their end where the element was (per keyframe).
    mutating func removeElement(_ id: UUID) {
        if let removed = elements.first(where: { $0.id == id }) {
            for index in elements.indices where elements[index].startAttachment == id || elements[index].endAttachment == id {
                let lineID = elements[index].id
                let start = elements[index].startAttachment == id, end = elements[index].endAttachment == id
                if start { elements[index].setEndpoint(start: true, to: removed.position); elements[index].startAttachment = nil }
                if end { elements[index].setEndpoint(start: false, to: removed.position); elements[index].endAttachment = nil }
                for frame in keyframes.indices {
                    guard let pose = keyframes[frame].poses[lineID] else { continue }
                    let anchor = self.pose(of: id, atFrame: frame)?.position ?? removed.position
                    var line = elements[index]
                    line.pose = pose
                    if start { line.setEndpoint(start: true, to: anchor) }
                    if end { line.setEndpoint(start: false, to: anchor) }
                    keyframes[frame].poses[lineID] = BoardPose(position: line.position, points: line.points, rotation: pose.rotation, size: pose.size)
                }
            }
        }
        elements.removeAll { $0.id == id }
        for index in keyframes.indices {
            keyframes[index].poses[id] = nil
            keyframes[index].paths?[id] = nil
        }
        clearCameraReferences(to: id)
    }

    /// Drops point-of-view cameras that looked through or at a deleted element, in the base camera and
    /// every stage key. The 3D view copes with a dangling subject at runtime; this keeps it out of the
    /// saved JSON, where it would outlive the element for good.
    private mutating func clearCameraReferences(to id: UUID) {
        func clear(_ camera: inout BoardCamera) {
            if camera.subjectID == id {
                camera.subjectID = nil
                camera.lookAt = nil
                // Without a subject a point-of-view camera has nothing to look through: back to orbit.
                if camera.resolvedMode == .pointOfView { camera.mode = nil }
            }
            if camera.lookAt == .element(id) { camera.lookAt = nil }
        }
        if var base = camera {
            clear(&base)
            camera = base
        }
        for index in keyframes.indices {
            guard var key = keyframes[index].camera else { continue }
            clear(&key)
            keyframes[index].camera = key
        }
    }

    /// Mutates one element in place.
    mutating func update(_ id: UUID, _ change: (inout BoardElement) -> Void) {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
        change(&elements[index])
    }

    func nextNumber(for kind: BoardElementKind, colorHex: String) -> Int {
        (elements.filter { $0.kind == kind && $0.colorHex == colorHex }.compactMap(\.number).max() ?? 0) + 1
    }
}

// MARK: - History

/// Bounded undo/redo over whole document snapshots. Documents are small value types,
/// so copying them is cheaper and simpler than reversible commands.
struct BoardHistory: Equatable {
    private(set) var past: [BoardDocument] = []
    private(set) var future: [BoardDocument] = []
    var limit = 80

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    mutating func record(_ before: BoardDocument) {
        past.append(before)
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
    }

    mutating func undo(current: BoardDocument) -> BoardDocument? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        return previous
    }

    mutating func redo(current: BoardDocument) -> BoardDocument? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }
}

// MARK: - Colours

enum BoardPalette {
    static let home = "2F80ED"
    static let away = "EB5757"
    static let keeper = "F2C94C"
    static let white = "FFFFFF"
    static let black = "111111"
    static let orange = "FF8A3D"
    static let green = "27AE60"
    static let purple = "9B51E0"
    static let pink = "FF6FB5"
    static let lime = "D1FF40"

    static let swatches = [home, away, keeper, white, black, orange, green, purple, pink, lime]

    static func rgb(_ hex: String) -> (Double, Double, Double) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return (1, 1, 1) }
        return (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
    }

    /// Six-digit hex of a SwiftUI colour (sRGB, clamped).
    static func hex(of color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        let clamp: (CGFloat) -> Int = { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }

    static func color(_ hex: String) -> Color {
        let (r, g, b) = rgb(hex)
        return Color(red: r, green: g, blue: b)
    }

    static func uiColor(_ hex: String, alpha: Double = 1) -> UIColor {
        let (r, g, b) = rgb(hex)
        return UIColor(red: r, green: g, blue: b, alpha: alpha)
    }
}

// MARK: - Follow paths and onion skin

extension BoardDocument {
    /// Geometry of a path element in metres: sampled points and whether it is a closed loop.
    static func pathGeometry(of element: BoardElement, field: BoardFieldType) -> (points: [BoardPoint], closed: Bool)? {
        if element.isLineLike {
            let geometry = element.lineGeometry()
            return geometry.count >= 2 ? (geometry, false) : nil
        }
        switch element.kind {
        case .polygon:
            return element.allPoints.count >= 3 ? (element.allPoints + [element.position], true) : nil
        case .zone:
            let w = Double(field.meters.width), h = Double(field.meters.height)
            let a = element.position, b = element.opposite
            let cx = (a.x + b.x) / 2 * w, cy = (a.y + b.y) / 2 * h
            let halfW = abs(b.x - a.x) / 2 * w, halfH = abs(b.y - a.y) / 2 * h
            guard halfW > 0, halfH > 0 else { return nil }
            let angle = element.rotation * .pi / 180
            // Clockwise on the top view, starting at the top-left corner (rectangle) or the right (ellipse).
            let local: [(Double, Double)] = element.zoneShape == .ellipse
                ? (0...96).map { (halfW * cos(Double($0) / 96 * 2 * .pi), halfH * sin(Double($0) / 96 * 2 * .pi)) }
                : [(-halfW, -halfH), (halfW, -halfH), (halfW, halfH), (-halfW, halfH), (-halfW, -halfH)]
            return (local.map { x, y in
                BoardPoint((cx + x * cos(angle) - y * sin(angle)) / w, (cy + x * sin(angle) + y * cos(angle)) / h)
            }, true)
        default:
            return nil
        }
    }

    /// Point and heading at a position `u` (0…1, wrapping on loops) along sampled geometry, by arc length in metres.
    static func geometryPoint(_ points: [BoardPoint], closed: Bool, at u: Double, field: BoardFieldType) -> (point: BoardPoint, tangentDegrees: Double)? {
        let w = Double(field.meters.width), h = Double(field.meters.height)
        var lengths: [Double] = [0]
        for (a, b) in zip(points, points.dropFirst()) { lengths.append(lengths[lengths.count - 1] + hypot((b.x - a.x) * w, (b.y - a.y) * h)) }
        guard let total = lengths.last, total > 0 else { return nil }
        var position = closed ? u - floor(u) : min(1, max(0, u))
        if closed, u > 0, position == 0, u == floor(u) { position = 1 }
        let target = position * total
        var index = 1
        while index < lengths.count - 1 && lengths[index] < target { index += 1 }
        // Skip zero-length segments so the heading is defined.
        while index < lengths.count - 1 && lengths[index] - lengths[index - 1] <= 0 { index += 1 }
        let a = points[index - 1], b = points[index]
        let segment = max(1e-12, lengths[index] - lengths[index - 1])
        let t = min(1, max(0, (target - lengths[index - 1]) / segment))
        // At the end of a path whose last segment is degenerate there is nothing ahead to skip to:
        // fall back to the last real segment behind, so the heading is the direction of travel, not 0°.
        var headingIndex = index
        while headingIndex > 1 && lengths[headingIndex] - lengths[headingIndex - 1] <= 0 { headingIndex -= 1 }
        let ha = points[headingIndex - 1], hb = points[headingIndex]
        let heading = atan2((hb.y - ha.y) * h, (hb.x - ha.x) * w) * 180 / .pi
        return (BoardPoint(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t), heading)
    }

    /// Where a legacy transition path (`BoardKeyframe.paths`) put an element after `fraction` (eased 0…1) of the move.
    static func legacyPathPoint(_ path: BoardFollowPath, at fraction: Double, in layout: [BoardElement], field: BoardFieldType) -> (point: BoardPoint, tangentDegrees: Double)? {
        guard let element = layout.first(where: { $0.id == path.pathID }), let geometry = pathGeometry(of: element, field: field) else { return nil }
        let (from, to) = legacyProgress(path, closed: geometry.closed)
        return geometryPoint(geometry.points, closed: geometry.closed, at: from + (to - from) * min(1, max(0, fraction)), field: field)
    }

    /// Start and end progress of a legacy transition path.
    static func legacyProgress(_ path: BoardFollowPath, closed: Bool) -> (from: Double, to: Double) {
        if closed {
            let laps = Double(max(0, path.laps ?? 0))
            var span = path.reversed ? path.startFraction - path.endFraction : path.endFraction - path.startFraction
            span -= floor(span)
            if span <= 1e-9 { span = 1 }
            let travel = span + laps
            return (path.startFraction, path.reversed ? path.startFraction - travel : path.startFraction + travel)
        }
        return path.reversed ? (path.endFraction, path.startFraction) : (path.startFraction, path.endFraction)
    }

    /// Converts `BoardKeyframe.paths` saved by older builds into path progress on the poses of frames k and k+1.
    func migratingLegacyPaths() -> BoardDocument {
        guard keyframes.contains(where: { $0.paths?.isEmpty == false }) else { return self }
        var copy = self
        for frame in copy.keyframes.indices {
            guard let paths = copy.keyframes[frame].paths else { continue }
            copy.keyframes[frame].paths = nil
            guard frame + 1 < copy.keyframes.count else { continue }
            for (id, path) in paths.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                guard let pathElement = copy.elements.first(where: { $0.id == path.pathID }),
                      let geometry = Self.pathGeometry(of: pathElement, field: fieldType) else { continue }
                let (from, to) = Self.legacyProgress(path, closed: geometry.closed)
                for (target, progress) in [(frame, from), (frame + 1, to)] {
                    guard var pose = copy.keyframes[target].poses[id] ?? copy.pose(of: id, atFrame: target) else { continue }
                    pose.pathID = path.pathID
                    pose.pathProgress = progress
                    pose.facesPath = path.facesDirection
                    copy.keyframes[target].poses[id] = pose
                }
            }
        }
        return copy
    }

    /// Point and heading at `progress` along a path element in `layout` (loops wrap, open paths clamp).
    static func pathLocation(pathID: UUID, progress: Double, in layout: [BoardElement], field: BoardFieldType) -> (point: BoardPoint, tangentDegrees: Double)? {
        pathSample(pathID: pathID, progress: progress, in: layout, field: field).map { ($0.point, $0.tangentDegrees) }
    }

    /// Point, heading and height above the ground at `progress` along a path element.
    static func pathSample(pathID: UUID, progress: Double, in layout: [BoardElement], field: BoardFieldType) -> (point: BoardPoint, tangentDegrees: Double, heightMeters: Double)? {
        guard let element = layout.first(where: { $0.id == pathID }), let geometry = pathGeometry(of: element, field: field),
              let sample = geometryPoint(geometry.points, closed: geometry.closed, at: progress, field: field) else { return nil }
        let fraction = geometry.closed ? progress - floor(progress) : min(1, max(0, progress))
        return (sample.point, sample.tangentDegrees, element.isAerial ? element.lineHeightMeters(at: fraction) : 0)
    }

    /// A pose's position, or its point on the path when it sits on one.
    static func resolvedPosition(_ pose: BoardPose, in layout: [BoardElement], field: BoardFieldType) -> BoardPoint {
        guard let pathID = pose.pathID, let progress = pose.pathProgress,
              let sample = pathLocation(pathID: pathID, progress: progress, in: layout, field: field) else { return pose.position }
        return sample.point
    }

    /// Projects `point` onto a path: geometry progress (0…1) of the nearest point and its distance in metres.
    static func projectOntoPath(pathID: UUID, point: BoardPoint, in layout: [BoardElement], field: BoardFieldType) -> (progress: Double, distanceMeters: Double)? {
        guard let element = layout.first(where: { $0.id == pathID }), let geometry = pathGeometry(of: element, field: field) else { return nil }
        let w = Double(field.meters.width), h = Double(field.meters.height)
        var lengths: [Double] = [0]
        for (a, b) in zip(geometry.points, geometry.points.dropFirst()) { lengths.append(lengths[lengths.count - 1] + hypot((b.x - a.x) * w, (b.y - a.y) * h)) }
        guard let total = lengths.last, total > 0 else { return nil }
        var best = (distance: Double.greatestFiniteMagnitude, along: 0.0)
        for index in 1..<geometry.points.count {
            let a = geometry.points[index - 1], b = geometry.points[index]
            let ax = a.x * w, ay = a.y * h, bx = b.x * w, by = b.y * h, px = point.x * w, py = point.y * h
            let lengthSquared = (bx - ax) * (bx - ax) + (by - ay) * (by - ay)
            let t = lengthSquared > 0 ? min(1, max(0, ((px - ax) * (bx - ax) + (py - ay) * (by - ay)) / lengthSquared)) : 0
            let distance = hypot(ax + (bx - ax) * t - px, ay + (by - ay) * t - py)
            if distance < best.distance { best = (distance, lengths[index - 1] + t * (lengths[index] - lengths[index - 1])) }
        }
        return (best.along / total, best.distance)
    }

    static func isClosedPath(_ pathID: UUID, in list: [BoardElement]) -> Bool {
        list.first { $0.id == pathID }?.kind.isArea == true
    }

    /// Layout of the board at keyframe `frame` (attachments resolved; the path elements' shapes at that moment).
    func layout(atFrame frame: Int) -> [BoardElement] {
        guard keyframes.indices.contains(frame) else { return Self.resolvingAttachments(elements) }
        return Self.resolvingAttachments(posedElements(at: frameStart(frame)))
    }

    /// Keyframes in which `id` sits on `pathID` (explicitly or inherited), in order.
    func pathFrames(of id: UUID, pathID: UUID) -> [Int] {
        keyframes.indices.filter { pose(of: id, atFrame: $0)?.pathID == pathID }
    }

    /// The path `id` sits on in `frame`, if any.
    func pathPose(of id: UUID, atFrame frame: Int) -> BoardPose? {
        guard let pose = pose(of: id, atFrame: frame), pose.pathID != nil else { return nil }
        return pose
    }

    /// Puts `id` on `pathID` in `frame` and every later keyframe until one that is on another path, starting at the
    /// nearest point and spreading progress evenly to the far end (one loop on closed shapes). Returns the frame count.
    @discardableResult
    mutating func attachToPath(_ id: UUID, pathID: UUID, fromFrame frame: Int) -> Int {
        guard keyframes.indices.contains(frame), let current = pose(of: id, atFrame: frame) else { return 0 }
        let layout = layout(atFrame: frame)
        let origin = Self.resolvedPosition(current, in: layout, field: fieldType)
        guard let projection = Self.projectOntoPath(pathID: pathID, point: origin, in: layout, field: fieldType) else { return 0 }
        var frames: [Int] = []
        for index in frame..<keyframes.count {
            let other = pose(of: id, atFrame: index)?.pathID
            if index > frame, let other, other != pathID { break }
            frames.append(index)
        }
        let start = projection.progress
        let end = Self.isClosedPath(pathID, in: elements) ? start + 1 : (start <= 0.5 ? 1 : 0)
        for (offset, index) in frames.enumerated() {
            guard var pose = keyframes[index].poses[id] ?? self.pose(of: id, atFrame: index) else { continue }
            pose.pathID = pathID
            pose.pathProgress = frames.count == 1 ? start : start + (end - start) * Double(offset) / Double(frames.count - 1)
            keyframes[index].poses[id] = pose
            snapPathPose(of: id, inFrame: index)
        }
        return frames.count
    }

    /// Sets progress along the path `id` sits on in `frame` (making the pose explicit there).
    mutating func setPathProgress(_ progress: Double, for id: UUID, inFrame frame: Int) {
        guard keyframes.indices.contains(frame), var pose = pathPose(of: id, atFrame: frame) else { return }
        pose.pathProgress = progress
        keyframes[frame].poses[id] = pose
        snapPathPose(of: id, inFrame: frame)
    }

    /// Turns facing on or off in every frame where `id` sits on `pathID`.
    mutating func setFacesPath(_ faces: Bool, for id: UUID, pathID: UUID) {
        for index in pathFrames(of: id, pathID: pathID) {
            guard var pose = keyframes[index].poses[id] ?? self.pose(of: id, atFrame: index) else { continue }
            pose.facesPath = faces ? true : nil
            keyframes[index].poses[id] = pose
            snapPathPose(of: id, inFrame: index)
        }
    }

    /// Takes `id` off its path in `frame`, leaving it where it was on the path.
    mutating func detachFromPath(_ id: UUID, inFrame frame: Int) {
        guard keyframes.indices.contains(frame), var pose = pathPose(of: id, atFrame: frame) else { return }
        pose.position = Self.resolvedPosition(pose, in: layout(atFrame: frame), field: fieldType)
        pose.pathID = nil
        pose.pathProgress = nil
        pose.facesPath = nil
        keyframes[frame].poses[id] = pose
    }

    /// Keeps the first and last progress on `pathID` and spaces the frames in between evenly.
    mutating func spreadPathEvenly(_ id: UUID, pathID: UUID) {
        let frames = pathFrames(of: id, pathID: pathID)
        guard frames.count > 2, let first = pose(of: id, atFrame: frames[0])?.pathProgress,
              let last = pose(of: id, atFrame: frames[frames.count - 1])?.pathProgress else { return }
        for (offset, index) in frames.enumerated() {
            guard var pose = keyframes[index].poses[id] ?? self.pose(of: id, atFrame: index) else { continue }
            pose.pathProgress = first + (last - first) * Double(offset) / Double(frames.count - 1)
            keyframes[index].poses[id] = pose
            snapPathPose(of: id, inFrame: index)
        }
    }

    /// Stores the path point (and heading) as the pose position, so editors reading raw poses agree.
    private mutating func snapPathPose(of id: UUID, inFrame frame: Int) {
        guard var pose = keyframes[frame].poses[id], let pathID = pose.pathID, let progress = pose.pathProgress,
              let sample = Self.pathLocation(pathID: pathID, progress: progress, in: layout(atFrame: frame), field: fieldType) else { return }
        pose.position = sample.point
        if pose.facesPath == true { pose.rotation = sample.tangentDegrees }
        keyframes[frame].poses[id] = pose
    }

    /// Points along the whole path (for previews), in the layout of `frame`.
    func pathSamples(pathID: UUID, frame: Int, count: Int = 96) -> [BoardPoint] {
        let layout = layout(atFrame: frame)
        guard let element = layout.first(where: { $0.id == pathID }), let geometry = Self.pathGeometry(of: element, field: fieldType) else { return [] }
        return (0...count).compactMap { Self.geometryPoint(geometry.points, closed: geometry.closed, at: Double($0) / Double(count), field: fieldType)?.point }
    }

    /// Resolved layouts of the keyframes before and after `index` (attachments and follow paths included),
    /// for translucent onion-skin ghosts. Empty where there is no such frame.
    func onionSkin(aroundFrame index: Int) -> (previous: [BoardElement], next: [BoardElement]) {
        guard keyframes.indices.contains(index) else { return ([], []) }
        let previous = index > 0 ? elements(at: frameStart(index - 1)) : []
        let next = index + 1 < keyframes.count ? elements(at: frameStart(index + 1)) : []
        return (previous, next)
    }
}

/// Degrees in (-180, 180].
func normalizedDegrees(_ degrees: Double) -> Double {
    let value = degrees.truncatingRemainder(dividingBy: 360)
    return value > 180 ? value - 360 : value <= -180 ? value + 360 : value
}
