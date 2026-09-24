import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// MARK: - Retention

extension CostUsageStore {
    @discardableResult
    func retainDayWindow(
        sinceDay: String,
        untilDay: String,
        calendar: Calendar = .current) -> CostUsageStoreRetentionResult
    {
        guard sinceDay <= untilDay else {
            return CostUsageStoreRetentionResult(
                deletedFiles: 0,
                deletedTokenSnapshots: 0,
                deletedFileDayAggregates: 0,
                deletedDayAggregates: 0)
        }
        let fallback = CostUsageStoreRetentionResult(
            deletedFiles: 0,
            deletedTokenSnapshots: 0,
            deletedFileDayAggregates: 0,
            deletedDayAggregates: 0)
        return self.withDatabase(default: fallback) { database in
            try Self.prune(
                database,
                sinceDay: sinceDay,
                untilDay: untilDay,
                metadataWindow: (sinceDay: sinceDay, untilDay: untilDay),
                calendar: calendar)
        }
    }

    @discardableResult
    func deleteFile(path: String) -> Bool {
        self.withDatabase(default: false) { database in
            let statement = try Self.prepare(database, "DELETE FROM files WHERE path = ?")
            defer { sqlite3_finalize(statement) }
            Self.bind(path, to: statement, at: 1)
            try Self.stepDone(statement, database: database)
            return sqlite3_changes(database) > 0
        }
    }

    /// Deletes files and aggregates outside `sinceDay...untilDay`; `metadataWindow` is the scan
    /// window recorded in `scan_metadata`, which budget enforcement may keep narrower than the
    /// protected range.
    private static func prune(
        _ database: OpaquePointer,
        sinceDay: String,
        untilDay: String,
        metadataWindow: (sinceDay: String, untilDay: String),
        calendar: Calendar) throws -> CostUsageStoreRetentionResult
    {
        try self.inTransaction(database) {
            let beforeFiles = try self.scalarInt(database, "SELECT COUNT(*) FROM files")
            let beforeSnapshots = try self.scalarInt(database, "SELECT COUNT(*) FROM token_snapshots")
            let beforeFileAggregates = try self.scalarInt(database, "SELECT COUNT(*) FROM file_day_aggregates")
            let beforeAggregates = try self.scalarInt(database, "SELECT COUNT(*) FROM day_aggregates")

            let activeWindow = self.activeWindowMs(sinceDay: sinceDay, untilDay: untilDay, calendar: calendar)
            let deleteFile = try self.prepare(database, "DELETE FROM files WHERE path = ?")
            defer { sqlite3_finalize(deleteFile) }
            var candidates: [RetentionCandidate] = []
            // Iterate to a fixpoint: deleting a stale child releases the fork protection on
            // its stale parent, which must then be pruned in the same pass instead of
            // lingering as an unreferenced out-of-window row.
            while true {
                let round = try self.retentionCandidates(
                    database,
                    sinceDay: sinceDay,
                    untilDay: untilDay,
                    activeWindow: activeWindow)
                guard !round.isEmpty else { break }
                for candidate in round {
                    sqlite3_reset(deleteFile)
                    sqlite3_clear_bindings(deleteFile)
                    self.bind(candidate.path, to: deleteFile, at: 1)
                    try self.stepDone(deleteFile, database: database)
                }
                candidates += round
            }

            let deleteFileAggregates = try self.prepare(
                database,
                "DELETE FROM file_day_aggregates WHERE day < ? OR day > ?")
            defer { sqlite3_finalize(deleteFileAggregates) }
            self.bind(sinceDay, to: deleteFileAggregates, at: 1)
            self.bind(untilDay, to: deleteFileAggregates, at: 2)
            try self.stepDone(deleteFileAggregates, database: database)

            let deleteAggregates = try self.prepare(
                database,
                "DELETE FROM day_aggregates WHERE day < ? OR day > ?")
            defer { sqlite3_finalize(deleteAggregates) }
            self.bind(sinceDay, to: deleteAggregates, at: 1)
            self.bind(untilDay, to: deleteAggregates, at: 2)
            try self.stepDone(deleteAggregates, database: database)

            try self.pruneDiscovery(database, candidates: candidates)
            var metadata = try self.readSingleton(
                CostUsageStoreMetadata.self,
                database: database,
                table: "scan_metadata") ?? .empty
            // An unchanged window must not count as a write: any row change invalidates every retained
            // decoded baseline and forces the next save/load to re-decode the whole cache.
            if metadata.scanSinceDay != metadataWindow.sinceDay || metadata.scanUntilDay != metadataWindow.untilDay {
                metadata.scanSinceDay = metadataWindow.sinceDay
                metadata.scanUntilDay = metadataWindow.untilDay
                try self.writeSingleton(metadata, database: database, table: "scan_metadata")
            }

            let afterFiles = try self.scalarInt(database, "SELECT COUNT(*) FROM files")
            let afterSnapshots = try self.scalarInt(database, "SELECT COUNT(*) FROM token_snapshots")
            let afterFileAggregates = try self.scalarInt(database, "SELECT COUNT(*) FROM file_day_aggregates")
            let afterAggregates = try self.scalarInt(database, "SELECT COUNT(*) FROM day_aggregates")
            return CostUsageStoreRetentionResult(
                deletedFiles: Int(beforeFiles - afterFiles),
                deletedTokenSnapshots: Int(beforeSnapshots - afterSnapshots),
                deletedFileDayAggregates: Int(beforeFileAggregates - afterFileAggregates),
                deletedDayAggregates: Int(beforeAggregates - afterAggregates))
        }
    }

    private struct RetentionCandidate {
        var path: String
        var sessionID: String?
    }

    /// Milliseconds spanned by the scan window's local days; a session file whose mtime
    /// falls inside it is still active (it may hold unscanned in-window rows) even when its
    /// scanned coverage is entirely out of window, so retention must not drop it.
    static func activeWindowMs(
        sinceDay: String?,
        untilDay: String?,
        calendar: Calendar) -> Range<Int64>?
    {
        let scanCalendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar(matching: calendar)
        guard let sinceDay, let untilDay,
              let since = Self.dayStart(sinceDay, calendar: scanCalendar),
              let until = Self.dayStart(untilDay, calendar: scanCalendar)
        else { return nil }
        let end = scanCalendar.date(byAdding: .day, value: 1, to: until) ?? until
        let lower = Int64(since.timeIntervalSince1970 * 1000)
        let upper = Int64(end.timeIntervalSince1970 * 1000)
        guard lower < upper else { return nil }
        return lower..<upper
    }

    private static func dayStart(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day))
    }

    private static func retentionCandidates(
        _ database: OpaquePointer,
        sinceDay: String,
        untilDay: String,
        activeWindow: Range<Int64>?) throws -> [RetentionCandidate]
    {
        // Fork parents stay protected only while a surviving child still needs the parent's
        // baseline; lineage-only children (dependency key "not required") never resolve
        // inherited totals, so they do not keep a stale parent alive.
        let statement = try self.prepare(database, """
        SELECT f.path, f.session_id, f.mtime_ms
        FROM files f
        WHERE f.scan_complete = 1
          AND f.coverage_since_day IS NOT NULL
          AND f.coverage_until_day IS NOT NULL
          AND (f.coverage_until_day < ? OR f.coverage_since_day > ?)
          AND NOT EXISTS (SELECT 1 FROM buffered_lines b WHERE b.file_id = f.id)
          AND (
              f.session_id IS NULL OR NOT EXISTS (
                  SELECT 1 FROM fork_lineage l
                  WHERE l.forked_from_id = f.session_id AND l.file_id != f.id
                    AND (l.dependency_key IS NULL OR l.dependency_key != ?)
              )
          )
        ORDER BY f.updated_at_ms, f.path
        """)
        defer { sqlite3_finalize(statement) }
        self.bind(sinceDay, to: statement, at: 1)
        self.bind(untilDay, to: statement, at: 2)
        self.bind(CostUsageScanner.codexForkDependencyNotRequiredKey, to: statement, at: 3)
        var values: [RetentionCandidate] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let path = self.columnText(statement, at: 0) else { throw StoreError.invalidData }
            let mtime = sqlite3_column_int64(statement, 2)
            if activeWindow?.contains(mtime) != true {
                values.append(RetentionCandidate(path: path, sessionID: self.columnText(statement, at: 1)))
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.sqlite(result) }
        return values
    }

    private static func pruneDiscovery(
        _ database: OpaquePointer,
        candidates: [RetentionCandidate]) throws
    {
        guard !candidates.isEmpty,
              var state = try self.readSingleton(
                  CostUsageStoreDiscoveryState.self,
                  database: database,
                  table: "discovery_state")
        else { return }
        let paths = Set(candidates.map(\.path))
        let sessionIDs = Set(candidates.compactMap(\.sessionID))
        state.filePaths.removeAll(where: paths.contains)
        state.pendingSessionIDs.removeAll(where: sessionIDs.contains)
        state.missingSessionIDs.removeAll(where: sessionIDs.contains)
        state.filePathBySessionID = state.filePathBySessionID.filter {
            !sessionIDs.contains($0.key) && !paths.contains($0.value)
        }
        // Cursors may point past the shortened arrays, and pruned coverage is no longer
        // complete; reset both so the next discovery pass re-enqueues remaining files
        // instead of trusting stale coverage.
        state.nextFileIndex = 0
        state.nextDirectoryIndex = 0
        state.validationDirectoryIndex = 0
        state.isComplete = false
        // The scanner round-trips discovery through the opaque payload, so the payload must
        // be pruned in lockstep with the typed columns or the deleted files resurface on the
        // next load.
        if let payload = state.payload,
           var discovery = try? JSONDecoder().decode(CostUsageCodexSessionDiscovery.self, from: payload)
        {
            discovery.filePaths.removeAll { paths.contains($0) }
            discovery.fileStamps = discovery.fileStamps.filter { !paths.contains($0.key) }
            discovery.filePathBySessionId = discovery.filePathBySessionId.filter {
                !sessionIDs.contains($0.key) && !paths.contains($0.value)
            }
            discovery.missingSessionIds.removeAll { sessionIDs.contains($0) }
            discovery.pendingSessionIds.removeAll { sessionIDs.contains($0) }
            if let head = discovery.headScan, paths.contains(head.path) {
                discovery.headScan = nil
            }
            discovery.nextFileIndex = 0
            discovery.nextDirectoryIndex = 0
            discovery.validationDirectoryIndex = 0
            discovery.isComplete = false
            state.payload = (try? JSONEncoder().encode(discovery)) ?? state.payload
        }
        try self.writeSingleton(state, database: database, table: "discovery_state")
    }
}

// MARK: - Budgets and vacuum

extension CostUsageStore {
    /// The row budget is the SQLite equivalent of the former 25k cache-entry cap: one
    /// retained session file is one entry. Dependent token and usage rows are bounded by
    /// the independent 256 MiB database cap, so active append/fork state is not discarded
    /// merely because a single session contains many events.
    ///
    /// One cache can serve several history windows (30-day menu refreshes, 365-day Usage & Spend
    /// catch-up). A file evicted inside a window that another caller still requests is rediscovered and
    /// re-parsed by that caller's next scan, so budgets also protect the widest window requested in the
    /// last `retentionFloorLifetimeDays` (capped at the 365-day history horizon). Caches that only ever
    /// serve one window keep the previous behavior.
    func enforceBudgets(
        maxRows: Int,
        maxFileBytes: Int64,
        requestedSinceDay: String? = nil,
        requestedUntilDay: String? = nil,
        calendar: Calendar = .current,
        now: Date = Date()) -> CostUsageStoreBudgetResult
    {
        let fallback = CostUsageStoreBudgetResult(deletedRows: 0, rowCount: 0, fileBytes: 0)
        return self.withDatabase(default: fallback) { database in
            let initialRows = try Self.rowCount(database)
            let initialBytes = Self.fileSize(at: self.databaseURL)
            let metadata = try Self.readSingleton(
                CostUsageStoreMetadata.self,
                database: database,
                table: "scan_metadata")
            let windowSinceDay = requestedSinceDay ?? metadata?.scanSinceDay
            let untilDay = requestedUntilDay ?? metadata?.scanUntilDay
            let floor = try windowSinceDay.map {
                try Self.retentionFloorSinceDay(database, windowSinceDay: $0, now: now, calendar: calendar)
            }
            let sinceDay = floor?.sinceDay
            let rowLimit = max(0, maxRows)
            let byteLimit = max(0, maxFileBytes)
            if initialRows > Int64(rowLimit) || initialBytes > byteLimit,
               let windowSinceDay, let sinceDay, let untilDay, windowSinceDay <= untilDay
            {
                _ = try Self.prune(
                    database,
                    sinceDay: sinceDay,
                    untilDay: untilDay,
                    metadataWindow: (sinceDay: windowSinceDay, untilDay: untilDay),
                    calendar: calendar)
            }

            var catchUpRequired = false
            // The row and byte budgets only remove files outside the requested window. Once
            // only protected data remains, preserving report fidelity takes precedence over
            // forcing the database under its best-effort byte cap.
            while try Self.rowCount(database) > Int64(rowLimit) {
                guard try Self.deleteOldestRetainedFile(
                    database,
                    sinceDay: sinceDay,
                    untilDay: untilDay,
                    calendar: calendar,
                    protectRequestedWindow: true) else { break }
                catchUpRequired = true
            }
            try Self.reclaimFreePages(database)

            var fileBytes = Self.fileSize(at: self.databaseURL)
            while fileBytes > byteLimit {
                guard try Self.deleteOldestRetainedFile(
                    database,
                    sinceDay: sinceDay,
                    untilDay: untilDay,
                    calendar: calendar,
                    protectRequestedWindow: true)
                else { break }
                catchUpRequired = true
                try Self.reclaimFreePages(database)
                fileBytes = Self.fileSize(at: self.databaseURL)
            }
            if catchUpRequired {
                try Self.rebuildDayAggregates(database)
                try Self.markCatchUpRequired(database)
            }
            let finalRows = try Self.rowCount(database)
            return CostUsageStoreBudgetResult(
                deletedRows: Int(max(0, initialRows - finalRows)),
                rowCount: Int(finalRows),
                fileBytes: fileBytes,
                catchUpRequired: catchUpRequired,
                retentionFloorWrites: floor?.writes ?? 0)
        }
    }

    func fileSizeBytes() -> Int64 {
        self.withDatabase(default: 0) { database in
            try Self.reclaimFreePages(database)
            return Self.fileSize(at: self.databaseURL)
        }
    }

    private static func deleteOldestRetainedFile(
        _ database: OpaquePointer,
        sinceDay: String?,
        untilDay: String?,
        calendar: Calendar,
        protectRequestedWindow: Bool) throws -> Bool
    {
        let statement = try self.prepare(database, """
        SELECT f.id, f.path, f.mtime_ms, f.coverage_since_day, f.coverage_until_day
        FROM files f
        WHERE f.scan_complete = 1
          AND NOT EXISTS (SELECT 1 FROM buffered_lines b WHERE b.file_id = f.id)
          AND NOT EXISTS (
              SELECT 1 FROM fork_lineage child
              JOIN fork_lineage parent ON parent.session_id = child.forked_from_id
              WHERE parent.file_id = f.id
                AND child.file_id != f.id
                AND (child.dependency_key IS NULL OR child.dependency_key != ?)
          )
        ORDER BY f.updated_at_ms, f.id
        """)
        defer { sqlite3_finalize(statement) }
        self.bind(CostUsageScanner.codexForkDependencyNotRequiredKey, to: statement, at: 1)
        let activeWindow = self.activeWindowMs(sinceDay: sinceDay, untilDay: untilDay, calendar: calendar)
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let mtime = sqlite3_column_int64(statement, 2)
            let coverageSince = self.columnText(statement, at: 3)
            let coverageUntil = self.columnText(statement, at: 4)
            let recentlyActive = activeWindow?.contains(mtime) == true
            let zeroDayRecentlyActive = coverageSince == nil && coverageUntil == nil && recentlyActive
            let touchesWindow: Bool = if let sinceDay, let untilDay,
                                         let coverageSince, let coverageUntil
            {
                coverageUntil >= sinceDay && coverageSince <= untilDay
            } else {
                false
            }
            let protected = zeroDayRecentlyActive
                || (protectRequestedWindow && (touchesWindow || recentlyActive))
            if !protected {
                let fileID = sqlite3_column_int64(statement, 0)
                try self.execute(database, "DELETE FROM files WHERE id = \(fileID)")
                return sqlite3_changes(database) > 0
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw StoreError.sqlite(result) }
        return false
    }

    static let retentionFloorLifetimeDays = 7
    private static let retentionFloorSinceKey = "retention_floor_since_day"
    private static let retentionFloorRequestedKey = "retention_floor_requested_day"

    /// Earliest day budget enforcement keeps for this save: the requested window, widened to the
    /// widest window requested within `retentionFloorLifetimeDays`. A request at least as wide as that
    /// floor records itself (at most one `meta` write per day), so a narrower refresh between wider
    /// scans cannot evict history the wider scan would parse again. An expired floor stops protecting.
    private static func retentionFloorSinceDay(
        _ database: OpaquePointer,
        windowSinceDay: String,
        now: Date,
        calendar: Calendar) throws -> (sinceDay: String, writes: Int)
    {
        let dayCalendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar(matching: calendar)
        let today = CostUsageScanner.CostUsageDayRange.dayKey(from: now, calendar: dayCalendar)
        let expiry = CostUsageScanner.CostUsageDayRange.dayKey(
            from: dayCalendar.date(byAdding: .day, value: -self.retentionFloorLifetimeDays, to: now) ?? now,
            calendar: dayCalendar)
        let storedSince = try self.metaValue(database, key: self.retentionFloorSinceKey)
        let storedRequested = try self.metaValue(database, key: self.retentionFloorRequestedKey)
        let liveFloor: String? = if let storedSince, let storedRequested, storedRequested >= expiry {
            max(storedSince, self.historyHorizonSinceDay(now: now, calendar: calendar))
        } else {
            nil
        }
        var writes = 0
        if liveFloor.map({ windowSinceDay <= $0 }) ?? true,
           storedSince != windowSinceDay || storedRequested != today
        {
            try self.setMetaValue(database, key: self.retentionFloorSinceKey, value: windowSinceDay)
            try self.setMetaValue(database, key: self.retentionFloorRequestedKey, value: today)
            writes = 2
        }
        return (min(windowSinceDay, liveFloor ?? windowSinceDay), writes)
    }

    private static func metaValue(_ database: OpaquePointer, key: String) throws -> String? {
        let statement = try self.prepare(database, "SELECT value FROM meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        self.bind(key, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return self.columnText(statement, at: 0)
    }

    private static func setMetaValue(_ database: OpaquePointer, key: String, value: String) throws {
        let statement = try self.prepare(database, """
        INSERT INTO meta(key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """)
        defer { sqlite3_finalize(statement) }
        self.bind(key, to: statement, at: 1)
        self.bind(value, to: statement, at: 2)
        try self.stepDone(statement, database: database)
    }

    /// Scan-window start of the longest history any caller requests (365 days, clamped in
    /// `CostUsageFetcher`), including the scan's one-day margin.
    static func historyHorizonSinceDay(now: Date, calendar: Calendar) -> String {
        let since = calendar.date(byAdding: .day, value: -(Self.maximumHistoryDays - 1), to: now) ?? now
        return CostUsageScanner.CostUsageDayRange(since: since, until: now, calendar: calendar).scanSinceKey
    }

    static let maximumHistoryDays = 365

    private static func rowCount(_ database: OpaquePointer) throws -> Int64 {
        try self.scalarInt(database, "SELECT COUNT(*) FROM files")
    }

    private static func rebuildDayAggregates(_ database: OpaquePointer) throws {
        try self.execute(database, "DELETE FROM day_aggregates")
        try self.execute(database, """
        INSERT INTO day_aggregates (
            day, model, input_tokens, cached_tokens, output_tokens, reasoning_tokens,
            request_count, authoritative_cost_nanos,
            standard_input_tokens, standard_cached_tokens, standard_output_tokens,
            priority_input_tokens, priority_cached_tokens, priority_output_tokens,
            standard_tokens, priority_tokens
        )
        SELECT day, model, SUM(input_tokens), SUM(cached_tokens), SUM(output_tokens),
               SUM(reasoning_tokens), SUM(request_count), SUM(authoritative_cost_nanos),
               SUM(standard_input_tokens), SUM(standard_cached_tokens), SUM(standard_output_tokens),
               SUM(priority_input_tokens), SUM(priority_cached_tokens), SUM(priority_output_tokens),
               SUM(standard_tokens), SUM(priority_tokens)
        FROM file_day_aggregates
        GROUP BY day, model
        """)
    }

    private static func markCatchUpRequired(_ database: OpaquePointer) throws {
        var metadata = try self.readSingleton(
            CostUsageStoreMetadata.self,
            database: database,
            table: "scan_metadata") ?? .empty
        metadata.catchUpPending = true
        metadata.lastScanUnixMs = 0
        metadata.scanInventoryPaths = nil
        try self.writeSingleton(metadata, database: database, table: "scan_metadata")
    }

    private static func reclaimFreePages(_ database: OpaquePointer) throws {
        try self.execute(database, "PRAGMA incremental_vacuum(1000000)")
        try self.execute(database, "PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - Singleton write helper

extension CostUsageStore {
    private static func writeSingleton(
        _ value: some Encodable,
        database: OpaquePointer,
        table: String) throws
    {
        let payload = try JSONEncoder().encode(value)
        let statement = try self.prepare(database, """
        INSERT INTO \(table)(id, payload) VALUES (1, ?)
        ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
        """)
        defer { sqlite3_finalize(statement) }
        self.bind(payload, to: statement, at: 1)
        try self.stepDone(statement, database: database)
    }
}
