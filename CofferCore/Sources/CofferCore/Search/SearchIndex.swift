import Foundation

/// In-memory search index with weighted field matching.
/// Sensitive fields (passwords, API keys, SSH keys, sensitive custom fields) are never searched.
public struct SearchIndex: Sendable {
    private let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// Search entries with optional filters.
    /// - Parameters:
    ///   - query: Search query (empty returns all entries sorted by updatedAt desc)
    ///   - groupID: Filter by group
    ///   - tag: Filter by tag (entry must have this tag)
    ///   - favoritesOnly: Filter favorites only
    /// - Returns: Matching entries sorted by relevance (or updatedAt desc if query is empty)
    public func search(
        query: String,
        groupID: UUID? = nil,
        tag: String? = nil,
        favoritesOnly: Bool = false
    ) -> [Entry] {
        // Apply filters
        var filtered = entries

        if let groupID = groupID {
            filtered = filtered.filter { $0.groupID == groupID }
        }

        if let tag = tag {
            filtered = filtered.filter { entry in
                entry.tags.contains(tag)
            }
        }

        if favoritesOnly {
            filtered = filtered.filter { $0.isFavorite }
        }

        // If query is empty, return all filtered entries sorted by updatedAt desc
        if query.isEmpty {
            return filtered.sorted { $0.updatedAt > $1.updatedAt }
        }

        // Score each entry
        let scored: [(entry: Entry, score: Int)] = filtered.compactMap { entry in
            guard let score = self.scoreEntry(entry, query: query) else {
                return nil
            }
            return (entry, score)
        }

        // Sort by score desc
        return scored.sorted { $0.score > $1.score }.map { $0.entry }
    }

    /// Score an entry against a query.
    /// Returns nil if no match.
    private func scoreEntry(_ entry: Entry, query: String) -> Int? {
        var maxScore = 0

        // Title (weight 100)
        if let s = FuzzyMatch.score(query: query, in: entry.title) {
            maxScore = max(maxScore, s * 100 / 100)
        }

        // Tags (weight 80)
        for tag in entry.tags {
            if let s = FuzzyMatch.score(query: query, in: tag) {
                maxScore = max(maxScore, s * 80 / 100)
            }
        }

        // Subtitle (weight 50)
        if !entry.subtitle.isEmpty {
            if let s = FuzzyMatch.score(query: query, in: entry.subtitle) {
                maxScore = max(maxScore, s * 50 / 100)
            }
        }

        // URLs and addresses from payload (weight 60)
        switch entry.payload {
        case .login(let payload):
            for url in payload.urls {
                if let s = FuzzyMatch.score(query: query, in: url) {
                    maxScore = max(maxScore, s * 60 / 100)
                }
            }
        case .access(let payload):
            for address in payload.addresses {
                if let s = FuzzyMatch.score(query: query, in: address) {
                    maxScore = max(maxScore, s * 60 / 100)
                }
            }
        case .apiKey(let payload):
            // Provider name only (secret is sensitive)
            if let s = FuzzyMatch.score(query: query, in: payload.provider) {
                maxScore = max(maxScore, s * 40 / 100)
            }
        case .sshKey(let payload):
            // Host only (user and privateKey are not searchable per spec)
            if let s = FuzzyMatch.score(query: query, in: payload.host) {
                maxScore = max(maxScore, s * 40 / 100)
            }
        case .totp, .secureNote:
            // No searchable non-sensitive fields in payload
            break
        }

        // Custom fields (weight 20 for non-sensitive fields)
        for field in entry.customFields where !field.isSensitive {
            // Field name
            if let s = FuzzyMatch.score(query: query, in: field.name) {
                maxScore = max(maxScore, s * 20 / 100)
            }
            // Field value
            if let s = FuzzyMatch.score(query: query, in: field.value) {
                maxScore = max(maxScore, s * 20 / 100)
            }
        }

        // Permission note (weight 25, lowest)
        if !entry.permissionNote.isEmpty {
            if let s = FuzzyMatch.score(query: query, in: entry.permissionNote) {
                maxScore = max(maxScore, s * 25 / 100)
            }
        }

        return maxScore > 0 ? maxScore : nil
    }
}
