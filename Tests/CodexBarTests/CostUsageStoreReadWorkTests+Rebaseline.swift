import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test
    func `changed save rebaselines the scanner from the rows it wrote`() throws {
        let fixture = try ReadWorkFixture(fileCount: 16, rowsPerFile: 64)
        defer { fixture.remove() }
        let first = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        var changed = first.cache
        let paths = changed.files.keys.sorted()
        let edited = try #require(paths.first)
        let removed = try #require(paths.last)
        changed.files[edited]?.lastModel = "gpt-5.4-edited"
        changed.files[removed] = nil
        #expect(!fixture.save(changed, load: first).catchUpRequired)
        first.release()
        #expect(fixture.store.syncRetainedCodexScanMatchesFreshReadForTesting() == true)

        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let warm = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { warm.release() }
        #expect(recorder.snapshot().scannerSnapshotReads == 0)
        #expect(recorder.snapshot().usageRowDecodeAttempts == 0)

        let fresh = CostUsageStore(cacheRoot: fixture.env.cacheRoot).syncLoadCodexScan(calendar: fixture.calendar)
        defer { fresh.release() }
        #expect(warm.cache == fresh.cache)
        #expect(warm.unloadedTokenSnapshotPaths == fresh.unloadedTokenSnapshotPaths)
        #expect(warm.cache.files[edited]?.lastModel == "gpt-5.4-edited")
        #expect(warm.cache.files[removed] == nil)
    }

    @Test
    func `freshness only save keeps the scanner baseline`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 4, rowsPerFile: 16)
        defer { fixture.remove() }
        let first = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        var fresher = first.cache
        fresher.lastScanUnixMs += 60000
        let changesBefore = await fixture.store.connectionTotalChanges()
        #expect(!fixture.save(fresher, load: first).catchUpRequired)
        first.release()
        // The freshness write happened, and the retained baseline still equals a full read.
        #expect(await fixture.store.connectionTotalChanges() != changesBefore)
        #expect(fixture.store.syncRetainedCodexScanMatchesFreshReadForTesting() == true)

        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let warm = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { warm.release() }
        #expect(recorder.snapshot().scannerSnapshotReads == 0)
        #expect(warm.cache.lastScanUnixMs == fresher.lastScanUnixMs)
    }

    @Test
    func `retention with an unchanged window leaves the database untouched`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 4, rowsPerFile: 4)
        defer { fixture.remove() }
        let metadata = await fixture.store.fetchMetadata()
        let changesBefore = await fixture.store.connectionTotalChanges()
        // Budgets far below the fixture force the retention pass while every file stays protected.
        let result = await fixture.store.enforceBudgets(
            maxRows: 1,
            maxFileBytes: 1,
            requestedSinceDay: metadata.scanSinceDay,
            requestedUntilDay: metadata.scanUntilDay,
            calendar: fixture.calendar)
        #expect(!result.catchUpRequired)
        #expect(result.deletedRows == 0)
        #expect(await fixture.store.connectionTotalChanges() == changesBefore)
    }

    @Test
    func `windowed report reads load rows only for files covering the window`() throws {
        let fixture = try ReadWorkFixture(fileCount: 4, rowsPerFile: 8)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let full = fixture.store.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .report)
        recorder.reset()
        let covering = fixture.store.syncLoadCodexReadView(
            calendar: fixture.calendar,
            purpose: .report,
            reportWindow: (sinceKey: "2026-07-31", untilKey: "2026-08-02"))
        #expect(recorder.snapshot().usageRows == fixture.rowCount)
        recorder.reset()
        let outside = fixture.store.syncLoadCodexReadView(
            calendar: fixture.calendar,
            purpose: .report,
            reportWindow: (sinceKey: "2026-09-01", untilKey: "2026-09-30"))
        #expect(recorder.snapshot().usageRows == 0)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let today = CostUsageScanner.CostUsageDayRange(
            since: fixture.now,
            until: fixture.now,
            calendar: fixture.calendar)
        let september = try CostUsageScanner.CostUsageDayRange(
            since: #require(fixture.calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))),
            until: #require(fixture.calendar.date(from: DateComponents(year: 2026, month: 9, day: 29))),
            calendar: fixture.calendar)
        let root = fixture.env.cacheRoot
        #expect(try encoder.encode(covering.dailyReport(range: today, cacheRoot: root))
            == encoder.encode(full.dailyReport(range: today, cacheRoot: root)))
        #expect(try encoder.encode(outside.dailyReport(range: september, cacheRoot: root))
            == encoder.encode(full.dailyReport(range: september, cacheRoot: root)))
    }

    @Test
    func `complete history publication skips detailed reads while catch-up is provably incomplete`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 4, rowsPerFile: 8, incomplete: true)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let result = await CostUsageFetcher.loadCachedCodexTokenSnapshotResult(
            now: fixture.now,
            historyDays: 1,
            includePiSessions: false,
            requireCompleteHistory: true,
            scannerOptions: fixture.options)
        #expect(result == nil)
        #expect(recorder.snapshot().usageRows == 0)
        #expect(recorder.snapshot().usageRowDecodeAttempts == 0)
    }
}

struct CostUsagePathFastPathTests {
    @Test
    func `canonical absolute paths skip standardization without changing the result`() {
        let canonical = [
            "/Users/someone/.codex/sessions/2026/09/01/rollout-2026-09-01T10-00-00-abc.jsonl",
            "/Users/someone/.codex/archived_sessions/rollout.jsonl",
            "/a/.hidden",
            "/a/...",
            "/a/name with spaces/b",
        ]
        for path in canonical {
            #expect(CostUsageStore.isCanonicalAbsolutePath(path))
            #expect(URL(fileURLWithPath: path).standardizedFileURL.path == path)
        }
        let rejected = [
            "", "/", "relative/path", "/a/", "/a//b", "/a/./b", "/a/../b", "/a/.", "/a/..",
            "/private", "/private/var/folders/x",
        ]
        for path in rejected {
            #expect(!CostUsageStore.isCanonicalAbsolutePath(path))
        }
    }

    @Test
    func `root matcher agrees with per file root checks across symlinks`() throws {
        let fileManager = FileManager.default
        // The temporary directory lives under /var, itself a symlink to /private/var.
        let base = fileManager.temporaryDirectory.appendingPathComponent("codexbar-roots-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: base) }
        let sessions = base.appendingPathComponent("sessions/2026/09/01", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let inside = sessions.appendingPathComponent("inside.jsonl")
        let external = outside.appendingPathComponent("external.jsonl")
        try Data("{}\n".utf8).write(to: inside)
        try Data("{}\n".utf8).write(to: external)
        let fileLink = sessions.appendingPathComponent("linked.jsonl")
        try fileManager.createSymbolicLink(at: fileLink, withDestinationURL: external)
        let directoryLink = base.appendingPathComponent("sessions/linked-dir", isDirectory: true)
        try fileManager.createSymbolicLink(at: directoryLink, withDestinationURL: outside)

        let roots = [base.appendingPathComponent("sessions", isDirectory: true)]
        let matcher = CostUsageScanner.CodexRootMatcher(roots: roots)
        let candidates = [
            inside.path,
            external.path,
            fileLink.path,
            directoryLink.appendingPathComponent("external.jsonl").path,
            sessions.appendingPathComponent("missing.jsonl").path,
            base.appendingPathComponent("sessions").path,
            "/private" + inside.path,
        ]
        for path in candidates {
            #expect(
                matcher.contains(path: path)
                    == CostUsageScanner.isWithinCodexRoots(fileURL: URL(fileURLWithPath: path), roots: roots),
                "\(path)")
        }
    }
}
