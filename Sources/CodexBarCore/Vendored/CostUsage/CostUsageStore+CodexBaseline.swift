import Foundation

extension CostUsageStore {
    /// Only the actor can resolve this receipt. It carries no decoded state or SQLite handle.
    final class CodexBaselineReceipt: Sendable {
        fileprivate let id = UUID()
        private let store: CostUsageStore

        fileprivate init(store: CostUsageStore) {
            self.store = store
        }

        deinit {
            let store = self.store
            let id = self.id
            Task { await store.releaseCodexBaseline(id: id) }
        }
    }

    struct CodexPersistenceState {
        var metadata: CostUsageStoreMetadata
        var files: [CostUsageStoreFile]
        var snapshotCounts: [String: Int]
        var rowCounts: [String: Int]

        init(
            snapshot: CostUsageStoreSnapshot,
            snapshotCounts: [String: Int]? = nil,
            rowCounts: [String: Int]? = nil)
        {
            self.metadata = snapshot.metadata
            self.files = snapshot.files.map { file in
                var file = file
                // Detailed payloads already belong to the typed cache; unloaded snapshot
                // presence is carried separately from a genuinely absent history.
                file.scanState.resumePayload = nil
                file.scanState.detailsPayload = nil
                return file
            }
            self.snapshotCounts = snapshotCounts
                ?? snapshot.tokenSnapshots.reduce(into: [:]) { $0[$1.path, default: 0] += 1 }
            self.rowCounts = rowCounts ?? snapshot.usageRows.reduce(into: [:]) { $0[$1.path, default: 0] += 1 }
        }
    }

    struct CodexDecodedBaseline {
        var decoded: CostUsageCache
        var persistence: CodexPersistenceState
        var stamp: DatabaseStamp
        var unloadedTokenSnapshotPaths: Set<String>
        var tokenSnapshotsLoaded: Bool
        var hydratedTokenSnapshots: [String: [CostUsageCodexTokenSnapshot]] = [:]
    }

    struct RetainedCodexBaseline {
        var id: UUID
        var baseline: CodexDecodedBaseline
    }

    struct RetainedCodexRead {
        var decoded: CostUsageCache
        var persistence: CodexPersistenceState
        var stamp: DatabaseStamp
        var purpose: CostUsageStoreReadPurpose
    }

    func loadCodexScan(calendar: Calendar) -> CostUsageStoreLoad {
        self.retainedCodexBaseline = nil
        _ = self.removeLegacyCodexArtifactIfPresent()
        let receipt = CodexBaselineReceipt(store: self)
        if self.retainedCodexScan?.stamp != self.currentDatabaseStamp() {
            self.retainedCodexScan = nil
        }
        guard let baseline = self.retainedCodexScan ?? self.readCodexBaseline() else {
            // Keep a receipt even on failure so save cannot fall back to accepting unbased content.
            return CostUsageStoreLoad(store: self, cache: CostUsageCache(), receipt: receipt)
        }
        self.retainedCodexScan = baseline
        self.retainedCodexBaseline = RetainedCodexBaseline(id: receipt.id, baseline: baseline)
        let compatible = baseline.decoded.timeZoneIdentifier == nil
            || baseline.decoded.timeZoneIdentifier == calendar.timeZone.identifier
        let cache = compatible ? Self.reconciledCodexCache(
            baseline.decoded, persistence: baseline.persistence) : CostUsageCache()
        return CostUsageStoreLoad(
            store: self,
            cache: cache,
            receipt: receipt,
            unloadedTokenSnapshotPaths: compatible ? baseline.unloadedTokenSnapshotPaths : [])
    }

    func releaseCodexBaseline(_ receipt: CodexBaselineReceipt) {
        self.releaseCodexBaseline(id: receipt.id)
    }

    private func releaseCodexBaseline(id: UUID) {
        if self.retainedCodexBaseline?.id == id {
            self.retainedCodexBaseline = nil
            #if DEBUG
            let observer = self.codexBaselineReleaseObserverForTesting
            self.codexBaselineReleaseObserverForTesting = nil
            observer?()
            #endif
        }
    }

    func codexBaselineStamp(for receipt: CodexBaselineReceipt) -> DatabaseStamp? {
        guard self.retainedCodexBaseline?.id == receipt.id else { return nil }
        return self.retainedCodexBaseline?.baseline.stamp
    }

    func takeCodexBaseline(_ receipt: CodexBaselineReceipt?) -> CodexDecodedBaseline? {
        guard let receipt else {
            self.retainedCodexBaseline = nil
            return self.readCodexBaseline(loadTokenSnapshots: true)
        }
        guard self.retainedCodexBaseline?.id == receipt.id else { return nil }
        defer { self.retainedCodexBaseline = nil }
        return self.retainedCodexBaseline?.baseline
    }

    func readCodexBaseline(loadTokenSnapshots: Bool = false) -> CodexDecodedBaseline? {
        let baseline: CodexDecodedBaseline? = self.withDatabase(default: nil) { database in
            guard let before = try? self.databaseStamp(database) else {
                self.requiresReadReopen = true
                return nil
            }
            let snapshot = try? Self.inReadTransaction(database) {
                let snapshot = try Self.readSnapshot(
                    database,
                    loadTokenSnapshots: loadTokenSnapshots,
                    recorder: self.scopedReadWorkRecorderForTesting)
                #if DEBUG
                try self.runCodexReadCheckpointForTesting()
                #endif
                return snapshot
            }
            // data_version inside the read transaction can still describe its pinned snapshot.
            // Compare after COMMIT; never attach a newer version to the old decoded rows.
            guard let snapshot, let after = try? self.databaseStamp(database), before == after else { return nil }
            return self.makeCodexBaseline(
                snapshot: snapshot,
                stamp: after,
                tokenSnapshotsLoaded: loadTokenSnapshots)
        }
        if baseline == nil {
            // Uncertain reads may be racing schema changes. Preserve the database and drain any
            // failed read transaction; a fresh open still owns normal integrity/recovery checks.
            self.recoverConnectionAfterFailure()
        }
        return baseline
    }

    private func makeCodexBaseline(
        snapshot: CostUsageStoreSnapshot,
        stamp: DatabaseStamp,
        tokenSnapshotsLoaded: Bool) -> CodexDecodedBaseline
    {
        var unloadedTokenSnapshotPaths: Set<String> = []
        return CodexDecodedBaseline(
            decoded: Self.decodeCodexCache(
                from: snapshot,
                recorder: self.scopedReadWorkRecorderForTesting,
                tokenSnapshotsLoaded: tokenSnapshotsLoaded,
                unloadedTokenSnapshotPathRecorder: { unloadedTokenSnapshotPaths.insert($0) }),
            persistence: CodexPersistenceState(
                snapshot: snapshot,
                snapshotCounts: tokenSnapshotsLoaded ? nil :
                    Dictionary(uniqueKeysWithValues: snapshot.accumulators.map {
                        ($0.path, $0.eventCount)
                    })),
            stamp: stamp,
            unloadedTokenSnapshotPaths: unloadedTokenSnapshotPaths,
            tokenSnapshotsLoaded: tokenSnapshotsLoaded)
    }

    /// After an identical-content save committed only scan freshness and the priority-turn cursor
    /// (`scan_metadata` fields that Codex's live logs advance on nearly every pass), keep the
    /// scanner's decoded baseline instead of re-decoding the whole cache on the next pass.
    /// The retained value must equal a fresh `readCodexBaseline()`: this connection's own commit
    /// may move only `totalChanges`, and the stored metadata may differ only in those fields,
    /// which are re-derived with the same decoding a full read uses.
    func retainCodexScanAfterFreshnessOnlySave(_ baseline: CodexDecodedBaseline) {
        guard let current = self.currentDatabaseStamp() else { return }
        var expectedStamp = baseline.stamp
        expectedStamp.totalChanges = current.totalChanges
        // Any other connection's commit moves data_version; that content was never decoded here.
        guard expectedStamp == current else { return }
        let stored = self.fetchMetadata()
        var expectedMetadata = baseline.persistence.metadata
        expectedMetadata.lastScanUnixMs = stored.lastScanUnixMs
        expectedMetadata.priorityTurnStatePayload = stored.priorityTurnStatePayload
        guard expectedMetadata == stored else { return }
        var retained = baseline
        retained.decoded.lastScanUnixMs = stored.lastScanUnixMs
        Self.applyPriorityTurnState(stored.priorityTurnStatePayload, to: &retained.decoded)
        retained.persistence.metadata = stored
        retained.stamp = current
        // Hydration is per-receipt state; a fresh baseline starts without it.
        retained.hydratedTokenSnapshots = [:]
        self.retainedCodexScan = retained
    }

    /// After a changed save, rebuild the scanner's decoded baseline from the rows this save wrote
    /// instead of re-decoding every file on the next pass. Decoding is per file, and globals come
    /// from the same tables a full read uses, so the result equals a fresh `readCodexBaseline()`.
    /// It declines whenever that cannot be proven: retention or any later write on this connection
    /// (`expectedTotalChanges`), or another connection's commit (`data_version`).
    func retainCodexScanAfterChangedSave(
        _ baseline: CodexDecodedBaseline,
        changedPaths: Set<String>,
        rereadDiscovery: Bool,
        rereadLookback: Bool,
        expectedTotalChanges: Int64?)
    {
        guard !baseline.tokenSnapshotsLoaded,
              let expectedTotalChanges,
              self.connectionTotalChanges() == expectedTotalChanges,
              let current = self.currentDatabaseStamp()
        else { return }
        var expectedStamp = baseline.stamp
        expectedStamp.totalChanges = current.totalChanges
        guard expectedStamp == current else { return }
        let recorder = self.scopedReadWorkRecorderForTesting
        let snapshot: CostUsageStoreSnapshot? = self.withDatabase(default: nil) { database in
            let snapshot = try Self.inReadTransaction(database) {
                try Self.readScannerSnapshot(
                    database,
                    paths: Array(changedPaths),
                    includeDiscovery: rereadDiscovery,
                    includeLookback: rereadLookback,
                    recorder: recorder)
            }
            guard try self.databaseStamp(database) == current else { return nil }
            return snapshot
        }
        guard let snapshot else { return }

        var unloadedTokenSnapshotPaths = baseline.unloadedTokenSnapshotPaths.subtracting(changedPaths)
        var decoded = Self.decodeCodexCache(
            from: snapshot,
            recorder: recorder,
            tokenSnapshotsLoaded: false,
            unloadedTokenSnapshotPathRecorder: { unloadedTokenSnapshotPaths.insert($0) })
        decoded.files = baseline.decoded.files
            .filter { !changedPaths.contains($0.key) }
            .merging(decoded.files) { _, written in written }
        // Unwritten singletons still hold the rows the baseline decoded.
        if !rereadDiscovery {
            decoded.codexSessionDiscovery = baseline.decoded.codexSessionDiscovery
        }
        if !rereadLookback {
            decoded.codexActiveLookbackState = baseline.decoded.codexActiveLookbackState
        }

        let written = CodexPersistenceState(
            snapshot: snapshot,
            snapshotCounts: Dictionary(uniqueKeysWithValues: snapshot.accumulators.map { ($0.path, $0.eventCount) }))
        var persistence = baseline.persistence
        persistence.metadata = written.metadata
        persistence.files = (persistence.files.filter { !changedPaths.contains($0.path) } + written.files)
            .sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        persistence.snapshotCounts = persistence.snapshotCounts
            .filter { !changedPaths.contains($0.key) }
            .merging(written.snapshotCounts) { _, new in new }
        persistence.rowCounts = persistence.rowCounts
            .filter { !changedPaths.contains($0.key) }
            .merging(written.rowCounts) { _, new in new }

        self.retainedCodexScan = CodexDecodedBaseline(
            decoded: decoded,
            persistence: persistence,
            stamp: current,
            unloadedTokenSnapshotPaths: unloadedTokenSnapshotPaths,
            tokenSnapshotsLoaded: false)
    }

    /// Harness/test check that a retained scanner baseline equals a fresh full read of the current
    /// database. `nil` when nothing current is retained or the fresh read fails.
    func retainedCodexScanMatchesFreshRead() -> Bool? {
        guard let retained = self.retainedCodexScan, retained.stamp == self.currentDatabaseStamp(),
              let fresh = self.readCodexBaseline()
        else { return nil }
        return retained.decoded == fresh.decoded
            && retained.persistence.metadata == fresh.persistence.metadata
            && retained.persistence.files == fresh.persistence.files
            && retained.persistence.snapshotCounts == fresh.persistence.snapshotCounts
            && retained.persistence.rowCounts == fresh.persistence.rowCounts
            && retained.unloadedTokenSnapshotPaths == fresh.unloadedTokenSnapshotPaths
            && retained.tokenSnapshotsLoaded == fresh.tokenSnapshotsLoaded
    }

    func codexBaselineIsCurrent(_ baseline: CodexDecodedBaseline) -> Bool {
        self.currentDatabaseStamp() == baseline.stamp
    }

    /// Retention may rewrite identical metadata when a protected window exceeds the budget.
    /// Only those own writes permit a fresh locked semantic comparison; external changes retry.
    func codexBaselineAfterRetention(_ baseline: CodexDecodedBaseline) -> CodexDecodedBaseline? {
        self.withDatabase(default: nil) { database in
            guard let current = self.currentDatabaseStamp() else { return nil }
            if current == baseline.stamp {
                return baseline
            }
            var original = baseline.stamp
            original.totalChanges = current.totalChanges
            guard original == current else { return nil }
            let snapshot = try Self.readSnapshot(
                database,
                loadTokenSnapshots: baseline.tokenSnapshotsLoaded,
                recorder: self.scopedReadWorkRecorderForTesting)
            return self.makeCodexBaseline(
                snapshot: snapshot,
                stamp: current,
                tokenSnapshotsLoaded: baseline.tokenSnapshotsLoaded)
        }
    }

    #if DEBUG
    func runCodexReadCheckpointForTesting() throws {
        if let checkpoint = Self.codexBaselineReadCheckpointForTesting,
           checkpoint.databaseURL == self.databaseURL
        {
            try checkpoint.checkpoint()
        }
    }

    nonisolated(unsafe) static var codexBaselineReadCheckpointForTesting: (
        databaseURL: URL,
        checkpoint: () throws -> Void)?

    nonisolated(unsafe) static var codexTokenHydrationCheckpointForTesting: (
        databaseURL: URL,
        checkpoint: () throws -> Void)?

    var retainedCodexBaselineCountForTesting: Int {
        self.retainedCodexBaseline == nil ? 0 : 1
    }
    #endif
}
