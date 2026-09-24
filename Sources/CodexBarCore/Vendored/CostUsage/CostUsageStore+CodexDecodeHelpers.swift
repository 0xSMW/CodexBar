import Foundation

/// Decoding and path helpers shared by full cache decodes, scanner rebaselining, and reconciliation.
extension CostUsageStore {
    struct StoredPriorityState: Codable {
        var turnKeys: [String: String]?
        var turnIDsByDay: [String: [String]]?
        var turnsCursor: CostUsageScanner.CodexPriorityTurnsPersistedCursor?
        var resolvedTurns: [String: CostUsageScanner.CodexPriorityTurnMetadata]?

        enum CodingKeys: String, CodingKey {
            case turnKeys
            case turnIDsByDay
            case turnsCursor
            case resolvedTurns
        }

        init(
            turnKeys: [String: String]?,
            turnIDsByDay: [String: [String]]?,
            turnsCursor: CostUsageScanner.CodexPriorityTurnsPersistedCursor?,
            resolvedTurns: [String: CostUsageScanner.CodexPriorityTurnMetadata]?)
        {
            self.turnKeys = turnKeys
            self.turnIDsByDay = turnIDsByDay
            self.turnsCursor = turnsCursor
            self.resolvedTurns = resolvedTurns
        }

        /// Cursor decode is best-effort so a malformed `turnsCursor` cannot drop load-bearing
        /// `turnKeys` / `turnIDsByDay`. `encode(to:)` stays synthesized.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.turnKeys = try container.decodeIfPresent([String: String].self, forKey: .turnKeys)
            self.turnIDsByDay = try container.decodeIfPresent([String: [String]].self, forKey: .turnIDsByDay)
            // Invalid optional evidence falls back to row pricing and hash-validated cursor days.
            self.resolvedTurns = try? container.decodeIfPresent(
                [String: CostUsageScanner.CodexPriorityTurnMetadata].self,
                forKey: .resolvedTurns)
            self.turnsCursor = try? container.decodeIfPresent(
                CostUsageScanner.CodexPriorityTurnsPersistedCursor.self,
                forKey: .turnsCursor)
        }
    }

    /// The decoded form of `scan_metadata.priorityTurnStatePayload`, shared by full decodes and
    /// by baseline re-stamping so both produce the same priority fields.
    static func applyPriorityTurnState(_ payload: Data?, to cache: inout CostUsageCache) {
        let defaults = CostUsageCache()
        guard let priority = payload.flatMap({ try? JSONDecoder().decode(StoredPriorityState.self, from: $0) })
        else {
            cache.codexPriorityTurnKeys = defaults.codexPriorityTurnKeys
            cache.codexPriorityTurnIDsByDay = defaults.codexPriorityTurnIDsByDay
            cache.codexPriorityTurnsCursor = defaults.codexPriorityTurnsCursor
            cache.codexResolvedPriorityTurns = defaults.codexResolvedPriorityTurns
            return
        }
        cache.codexPriorityTurnKeys = priority.turnKeys
        cache.codexPriorityTurnIDsByDay = priority.turnIDsByDay
        cache.codexPriorityTurnsCursor = priority.turnsCursor
        cache.codexResolvedPriorityTurns = priority.resolvedTurns
    }

    static func normalizedCodexPath(_ path: String) -> String {
        // Reconciliation normalizes every persisted path on every load. Canonical absolute paths
        // are already what standardization returns; building and standardizing a URL costs a
        // stat plus a reachability check per file.
        if self.isCanonicalAbsolutePath(path) {
            return path
        }
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        if path.hasPrefix("/private/var/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// True when `URL(fileURLWithPath:).standardizedFileURL.path` would return `path` unchanged:
    /// absolute, no empty/`.`/`..` components, no trailing slash, and no `/private` prefix
    /// (standardization may strip it). Anything else must take the Foundation route.
    static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.utf8.count > 1, path.hasPrefix("/"), !path.hasSuffix("/") else { return false }
        if path == "/private" || path.hasPrefix("/private/") { return false }
        var previous: UInt8 = 0
        var componentLength = 0
        var componentDots = 0
        for byte in path.utf8 {
            if byte == UInt8(ascii: "/") {
                if previous == UInt8(ascii: "/") { return false }
                if componentLength > 0, componentLength == componentDots, componentDots <= 2 { return false }
                componentLength = 0
                componentDots = 0
            } else {
                componentLength += 1
                if byte == UInt8(ascii: ".") { componentDots += 1 }
            }
            previous = byte
        }
        return !(componentLength == componentDots && componentDots <= 2)
    }
}
