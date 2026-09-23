import Foundation
import SwiftData
import UIKit

#if DEBUG
/// Test hooks for the Squad tab, safe on a phone with real data: they only create or delete players
/// whose name starts with "UITest " in the team "UITest", and their photos.
/// `-seedUITestSquad` adds fourteen players with generated photos (skipped when they already exist).
/// `-removeUITestSquad` deletes only those players.
enum SquadDebugSeeding {
    static let prefix = "UITest "
    static let team = "UITest"

    @MainActor static func run(arguments: [String], modelContext: ModelContext) {
        if arguments.contains("-removeUITestSquad") { remove(modelContext: modelContext) }
        if arguments.contains("-seedUITestSquad") { seed(modelContext: modelContext) }
    }

    @MainActor static func remove(modelContext: ModelContext) {
        let players = (try? modelContext.fetch(FetchDescriptor<SquadPlayer>())) ?? []
        // Both the name prefix and the team must match, so a real player can never be deleted.
        for player in players where player.name.hasPrefix(prefix) && player.team == team {
            do { try player.delete(from: modelContext) } catch { report("remove", error) }
        }
    }

    @MainActor static func seed(modelContext: ModelContext) {
        let players = (try? modelContext.fetch(FetchDescriptor<SquadPlayer>())) ?? []
        guard !players.contains(where: { $0.name.hasPrefix(prefix) }) else { return }
        let roster: [(String, Int, SquadPosition, String)] = [
            ("Alex Moreno", 1, .goalkeeper, "GK"), ("Ben Carter", 2, .defender, "RB"), ("Chris Diaz", 4, .defender, "CB"),
            ("Dan Okafor", 5, .defender, "CB"), ("Eli Novak", 3, .defender, "LB"), ("Finn Walsh", 6, .midfielder, "CDM"),
            ("Gabe Silva", 8, .midfielder, "CM"), ("Hugo Laurent", 10, .midfielder, "CAM"), ("Ivan Petrov", 7, .forward, "RW"),
            ("Jonah Reed", 9, .forward, "ST"), ("Kai Tanaka", 11, .forward, "LW"), ("Leo Brandt", 13, .goalkeeper, "GK"),
            ("Max Keller", 14, .midfielder, "CM"), ("Nico Rossi", 17, .forward, "ST"),
        ]
        var photos: [(UUID, Data)] = []
        for (index, entry) in roster.enumerated() {
            let player = SquadPlayer(name: prefix + entry.0, number: entry.1, position: entry.2, role: entry.3, team: team,
                                     preferredFoot: index % 3 == 0 ? .left : .right, birthYear: 2012 + index % 3, heightCm: 150 + index * 2)
            // Every fourth player has no photo, so initials avatars are covered too.
            if index % 4 != 3, let data = photo(index: index, name: entry.0) {
                photos.append((player.id, data))
                player.photoVersion = 1
            }
            modelContext.insert(player)
        }
        // Photos follow the save: a failed seed leaves no files behind for players that do not exist.
        do { try modelContext.save() } catch { return report("seed", error) }
        for (id, data) in photos {
            do { try SquadPhotoStore.save(data, for: id) } catch { report("photo", error) }
        }
    }

    private static func report(_ step: String, _ error: any Error) {
        print("SquadDebugSeeding \(step) failed: \(error)")
        assertionFailure("SquadDebugSeeding \(step) failed: \(error)")
    }

    /// A simple generated portrait: coloured backdrop, head and shoulders.
    static func photo(index: Int, name: String) -> Data? {
        let hues: [CGFloat] = [0.58, 0.02, 0.33, 0.12, 0.75, 0.48, 0.9]
        let background = UIColor(hue: hues[index % hues.count], saturation: 0.45, brightness: 0.8, alpha: 1)
        let skins = [UIColor(red: 0.96, green: 0.8, blue: 0.66, alpha: 1), UIColor(red: 0.78, green: 0.56, blue: 0.4, alpha: 1), UIColor(red: 0.48, green: 0.32, blue: 0.22, alpha: 1)]
        let skin = skins[index % skins.count]
        let size = CGSize(width: 900, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [background.cgColor, background.withAlphaComponent(0.6).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor(white: 0.12, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 150, y: 820, width: 600, height: 600)).fill()
            skin.setFill()
            UIBezierPath(roundedRect: CGRect(x: 390, y: 700, width: 120, height: 160), cornerRadius: 40).fill()
            UIBezierPath(ovalIn: CGRect(x: 300, y: 380, width: 300, height: 370)).fill()
            UIColor(white: 0.15, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 290, y: 350, width: 320, height: 130), cornerRadius: 60).fill()
            let initials = SquadPlayerSnapshot.initials(of: name)
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 110, weight: .heavy), .foregroundColor: UIColor.white.withAlphaComponent(0.85)]
            let text = NSString(string: initials)
            let measured = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - measured.width) / 2, y: 1000), withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.9)
    }
}
#endif
