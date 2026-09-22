import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import Security
import SweetCookieKit

struct KeychainAccessValidationMemoTests {
    private typealias Memo = KeychainAccessPreflight.ValidationMemo
    private static let trust = Data("synthetic-signing-requirement".utf8)

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int {
            self.lock.withLock { self.value }
        }

        func increment() -> Int {
            self.lock.withLock {
                self.value += 1
                return self.value
            }
        }
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var bundle: URL {
            self.root.appendingPathComponent("Fixture.app")
        }

        var main: URL {
            self.bundle.appendingPathComponent("Contents/MacOS/Fixture")
        }

        var helper: URL {
            self.bundle.appendingPathComponent("Contents/Helpers/FixtureCLI")
        }

        init() throws {
            for url in [self.main, self.helper] {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try Data("synthetic executable".utf8).write(to: url)
            }
            try self.setVersion("1")
        }

        func setVersion(_ version: String) throws {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleVersion": version, "CFBundleExecutable": "Fixture"],
                format: .xml,
                options: 0)
            try data.write(to: self.bundle.appendingPathComponent("Contents/Info.plist"))
        }

        func remove() { try? FileManager.default.removeItem(at: self.root) }
    }

    private static func gate(memo: Memo, path: String, check: @escaping () -> OSStatus?) -> Bool {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            ProviderInteractionContext.$current.withValue(.background) {
                KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                    let status = memo.validate(trustedApplication: Self.trust, path: path, check: check)
                    switch KeychainAccessPreflight.evaluateDecryptACL(
                        trustedApplicationValidationStatuses: [status], promptSelector: [])
                    {
                    case .allowed: return .allowed
                    case .rejected: return .interactionRequired
                    case .indeterminate: return .temporarilyUnavailable
                    }
                } operation: {
                    BrowserCookieAccessGate.shouldAttempt(.chrome)
                }
            }
        }
    }

    @Test
    func `one hundred serial browser preflights validate once`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let memo = Memo()
        let calls = Counter()
        for _ in 0..<100 {
            #expect(Self.gate(memo: memo, path: fixture.helper.path) {
                _ = calls.increment()
                return errSecSuccess
            })
        }
        #expect(calls.count == 1)
        print("validation memo serial: requests=100 validations=\(calls.count)")
    }

    @Test
    func `twenty concurrent browser preflights join one validation without blocking another key`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let joined = DispatchGroup()
        for _ in 0..<19 {
            joined.enter()
        }
        let memo = Memo(onJoin: { joined.leave() })
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        let calls = Counter()
        let path = fixture.helper.path
        let check: @Sendable () -> OSStatus? = {
            if calls.increment() == 1 {
                started.signal()
                _ = release.wait(timeout: .now() + 10)
            }
            return errSecSuccess
        }
        let queue = DispatchQueue(label: "validation-memo-test", attributes: .concurrent)
        done.enter()
        queue.async {
            #expect(Self.gate(memo: memo, path: path, check: check))
            done.leave()
        }
        #expect(started.wait(timeout: .now() + 5) == .success)
        for _ in 0..<19 {
            done.enter()
            queue.async {
                #expect(Self.gate(memo: memo, path: path, check: check))
                done.leave()
            }
        }
        #expect(joined.wait(timeout: .now() + 5) == .success)
        let otherDone = DispatchSemaphore(value: 0)
        queue.async {
            #expect(memo.validate(trustedApplication: Data("different trust".utf8), path: path) {
                errSecSuccess
            } == errSecSuccess)
            otherDone.signal()
        }
        #expect(otherDone.wait(timeout: .now() + 5) == .success)
        release.signal()
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(calls.count == 1)
        print("validation memo concurrent: requests=20 validations=\(calls.count)")
    }

    @Test(arguments: ["version", "main executable", "invoking executable", "bundle directory"])
    func `changed bundle or executable metadata revalidates`(_ change: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let memo = Memo()
        var calls = 0
        func validate() {
            #expect(memo.validate(trustedApplication: Self.trust, path: fixture.helper.path) {
                calls += 1
                return errSecSuccess
            } == errSecSuccess)
        }
        validate()
        validate()
        #expect(calls == 1)
        switch change {
        case "version": try fixture.setVersion("2")
        case "main executable": try Data("changed main executable size".utf8).write(to: fixture.main)
        case "invoking executable": try Data("changed helper size".utf8).write(to: fixture.helper)
        default:
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1000)],
                ofItemAtPath: fixture.bundle.path)
        }
        validate()
        #expect(calls == 2)
    }

    @Test(arguments: [OSStatus?.none, errSecInteractionNotAllowed, errSecNotAvailable, errSecParam])
    func `transient statuses are not cached`(_ status: OSStatus?) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let memo = Memo()
        var calls = 0
        for _ in 0..<2 {
            #expect(memo.validate(trustedApplication: Self.trust, path: fixture.helper.path) {
                calls += 1
                return status
            } == status)
        }
        #expect(calls == 2)
        #expect(Self.gate(memo: memo, path: fixture.helper.path) { errSecSuccess })
    }

    @Test(arguments: [errSecSuccess, OSStatus(CSSMERR_CSP_VERIFY_FAILED)])
    func `stable results expire at their bounded lifetime`(_ status: OSStatus) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let memo = Memo()
        let lifetime = status == errSecSuccess ? Memo.successLifetime : Memo.rejectionLifetime
        var calls = 0
        for now in [100, 100 + lifetime - 1, 100 + lifetime] {
            #expect(memo.validate(trustedApplication: Self.trust, path: fixture.helper.path, now: now) {
                calls += 1
                return status
            } == status)
        }
        #expect(calls == 2)
    }

    @Test
    func `different trust identities and paths do not share results and capacity evicts old entries`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let memo = Memo()
        var calls = 0
        for index in 0...Memo.capacity {
            #expect(memo
                .validate(trustedApplication: Data("trust-\(index)".utf8), path: fixture.helper.path, now: 100) {
                    calls += 1
                    return index == 0 ? errSecSuccess : OSStatus(CSSMERR_CSP_VERIFY_FAILED)
                } == (index == 0 ? errSecSuccess : OSStatus(CSSMERR_CSP_VERIFY_FAILED)))
        }
        #expect(memo.validate(trustedApplication: Data("trust-1".utf8), path: fixture.helper.path, now: 100) {
            calls += 1
            return OSStatus(CSSMERR_CSP_VERIFY_FAILED)
        } == OSStatus(CSSMERR_CSP_VERIFY_FAILED))
        #expect(calls == Memo.capacity + 1)
        #expect(memo.validate(trustedApplication: Data("trust-0".utf8), path: fixture.helper.path, now: 100) {
            calls += 1
            return errSecSuccess
        } == errSecSuccess)
        #expect(calls == Memo.capacity + 2)
        #expect(memo.validate(trustedApplication: Data("trust-0".utf8), path: fixture.main.path, now: 100) {
            calls += 1
            return OSStatus(CSSMERR_CSP_VERIFY_FAILED)
        } == OSStatus(CSSMERR_CSP_VERIFY_FAILED))
        #expect(calls == Memo.capacity + 3)
    }

    @Test
    func `unavailable identity metadata falls back to uncached validation`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.bundle.appendingPathComponent("Contents/Info.plist"))
        let memo = Memo()
        var calls = 0
        for trust in [Self.trust, nil] {
            for _ in 0..<2 {
                #expect(memo.validate(trustedApplication: trust, path: fixture.helper.path) {
                    calls += 1
                    return errSecSuccess
                } == errSecSuccess)
            }
        }
        #expect(calls == 4)
    }
}
#endif
