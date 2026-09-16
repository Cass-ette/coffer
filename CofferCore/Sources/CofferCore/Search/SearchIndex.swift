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
    ///   - tags: Filter by tags (entry must have all specified tags)
    ///   - favoritesOnly: Filter favorites only
    /// - Returns: Matching entries sorted by relevance (or updatedAt desc if query is empty)
    public func search(
        query: String,
        groupID: UUID? = nil,
        tags: [String] = [],
        favoritesOnly: Bool = false
    ) -> [Entry] {
        // Apply filters
        var filtered = entries

        if let groupID = groupID {
            filtered = filtered.filter { $0.groupID == groupID }
        }

        if !tags.isEmpty {
            filtered = filtered.filter { entry in
                tags.allSatisfy { entry.tags.contains($0) }
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
        if let s = FuzzyMatch.score(query: query, target: entry.title) {
            maxScore = max(maxScore, s * 100)
        }

        // Tags (weight 80)
        for tag in entry.tags {
            if let s = FuzzyMatch.score(query: query, target: tag) {
                maxScore = max(maxScore, s * 80)
            }
        }

        // Subtitle (weight 50)
        if !entry.subtitle.isEmpty {
            if let s = FuzzyMatch.score(query: query, target: entry.subtitle) {
                maxScore = max(maxScore, s * 50)
            }
        }

        // URLs and addresses from payload (weight 60)
        switch entry.payload {
        case .login(let payload):
            for url in payload.urls {
                if let s = FuzzyMatch.score(query: query, target: url) {
                    maxScore = max(maxScore, s * 60)
                }
            }
        case .access(let payload):
            for address in payload.addresses {
                if let s = FuzzyMatch.score(query: query, target: address) {
                    maxScore = max(maxScore, s * 60)
                }
            }
        case .apiKey(let payload):
            // Provider name only (secret is sensitive)
            if let s = FuzzyMatch.score(query: query, target: payload.provider) {
                maxScore = max(maxScore, s * 60)
            }
        case .sshKey(let payload):
            // Host and user only (privateKey is sensitive)
            if let s = FuzzyMatch.score(query: query, target: payload.host) {
                maxScore = max(maxScore, s * 60)
            }
            if let s = FuzzyMatch.score(query: query, target: payload.user) {
                maxScore = max(maxScore, s * 60)
            }
        case .totp, .secureNote:
            // No searchable non-sensitive fields in payload
            break
        }

        // Custom fields (weight 30 for non-sensitive fields)
        for field in entry.customFields where !field.isSensitive {
            // Field name
            if let s = FuzzyMatch.score(query: query, target: field.name) {
                maxScore = max(maxScore, s * 30)
            }
            // Field value
            if let s = FuzzyMatch.score(query: query, target: field.value) {
                maxScore = max(maxScore, s * 30)
            }
        }

        // Permission note (weight 20, lowest)
        if !entry.permissionNote.isEmpty {
            if let s = FuzzyMatch.score(query: query, target: entry.permissionNote) {
                maxScore = max(maxScore, s * 20)
            }
        }

        return maxScore > 0 ? maxScore : nil
    }
}
