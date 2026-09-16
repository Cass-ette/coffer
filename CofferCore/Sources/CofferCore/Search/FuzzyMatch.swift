import Foundation

/// Fuzzy string matching with configurable scoring.
/// Returns 0 for empty query, nil if no match, otherwise a score where higher is better.
public enum FuzzyMatch {
    /// Score a query against a target string.
    /// - Returns: 0 if query is empty, nil if no match, otherwise a score (substring ≥1000, subsequence <1000)
    public static func score(query: String, in target: String) -> Int? {
        let q = query.lowercased()
        let t = target.lowercased()

        guard !q.isEmpty else { return 0 }

        // Try substring match first
        if let range = t.range(of: q) {
            let position = t.distance(from: t.startIndex, to: range.lowerBound)
            let prefixBonus = position == 0 ? 50 : 0
            let lengthDiff = t.count - q.count
            return 1000 + max(0, 100 - lengthDiff) + prefixBonus
        }

        // Try subsequence match
        var tIndex = t.startIndex
        var streak = 0
        var bestStreak = 0
        var gaps = 0
        var matched = 0
        var lastMatchIndex: String.Index?

        for char in q {
            guard let matchIndex = t[tIndex...].firstIndex(of: char) else {
                return nil // No match
            }

            matched += 1

            // Check if contiguous with previous match
            if let prev = lastMatchIndex, t.index(after: prev) == matchIndex {
                streak += 1
            } else {
                bestStreak = max(bestStreak, streak)
                streak = 1
                if let prev = lastMatchIndex {
                    gaps += t.distance(from: prev, to: matchIndex) - 1
                }
            }

            lastMatchIndex = matchIndex
            tIndex = t.index(after: matchIndex)
        }
        bestStreak = max(bestStreak, streak)

        // Subsequence score: base + matched bonus + streak bonus - gap penalty
        return 100 + matched * 10 + bestStreak * 15 - gaps * 2
    }
}
