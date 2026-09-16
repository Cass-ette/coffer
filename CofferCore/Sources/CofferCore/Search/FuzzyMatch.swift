import Foundation

/// Fuzzy string matching with configurable scoring.
/// Returns nil if no match, otherwise a score where higher is better.
public enum FuzzyMatch {
    /// Score a query against a target string.
    /// - Returns: nil if no match, otherwise a score (substring ≥1000, subsequence <1000)
    public static func score(query: String, target: String) -> Int? {
        let q = query.lowercased()
        let t = target.lowercased()

        guard !q.isEmpty else { return nil }

        // Try substring match first
        if let range = t.range(of: q) {
            let position = t.distance(from: t.startIndex, to: range.lowerBound)
            let prefixBonus = position == 0 ? 200 : 0
            let lengthPenalty = t.count
            return 1000 + prefixBonus - lengthPenalty
        }

        // Try subsequence match
        var tIndex = t.startIndex
        var streak = 0
        var maxStreak = 0
        var gaps = 0
        var lastMatchIndex = t.startIndex

        for char in q {
            guard let matchIndex = t[tIndex...].firstIndex(of: char) else {
                return nil // No match
            }

            // Check if contiguous
            if tIndex == t.startIndex || t.index(after: lastMatchIndex) == matchIndex {
                streak += 1
            } else {
                maxStreak = max(maxStreak, streak)
                streak = 1
                gaps += t.distance(from: lastMatchIndex, to: matchIndex) - 1
            }

            lastMatchIndex = matchIndex
            tIndex = t.index(after: matchIndex)
        }
        maxStreak = max(maxStreak, streak)

        // Subsequence score: max streak bonus, gap penalty
        return 500 + maxStreak * 10 - gaps * 5
    }
}
