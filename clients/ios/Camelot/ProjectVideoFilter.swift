import Foundation

/// One video reduced to what the library search needs: the event kinds it contains and a
/// folded haystack of its title, subtitle and event notes. Built once per list render so a
/// keystroke only compares strings that are already lowercased and diacritic-folded.
struct VideoSearchIndex: Identifiable, Equatable {
    let id: String
    let kinds: Set<String>
    let haystack: String

    init(id: String, title: String, subtitle: String, eventKinds: [String], eventNotes: [String]) {
        self.id = id
        kinds = Set(eventKinds)
        haystack = ([title, subtitle] + eventKinds + eventNotes)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .folded
    }
}

/// Text and event-kind filtering for a project's video library.
/// Pure value logic so it can be tested without the UI.
enum ProjectVideoFilter {
    /// True when every word of `query` appears somewhere in the video and, if kinds are
    /// selected, the video contains at least one event of those kinds.
    static func matches(_ index: VideoSearchIndex, query: String, kinds: Set<String>) -> Bool {
        if !kinds.isEmpty, index.kinds.isDisjoint(with: kinds) { return false }
        let words = query.folded.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { index.haystack.contains($0) }
    }

    static func matching(_ indexes: [VideoSearchIndex], query: String, kinds: Set<String>) -> [VideoSearchIndex] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty || !kinds.isEmpty else { return indexes }
        return indexes.filter { matches($0, query: query, kinds: kinds) }
    }

    /// Identifiers of the matching videos, for filtering a list of view models in place.
    static func matchingIDs(_ indexes: [VideoSearchIndex], query: String, kinds: Set<String>) -> Set<String> {
        Set(matching(indexes, query: query, kinds: kinds).map(\.id))
    }
}

private extension String {
    /// Case- and accent-insensitive form used on both sides of every comparison.
    var folded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}
