import XCTest
import SwitcherooCore
import SwitcherooPresentation

final class SwitcherooAppUsageTests: XCTestCase {
    private func makeHarness(accounts: [(id: String, name: String)], activeId: String? = nil) throws -> (EngineHarness, MockAccountUsageFetcher) {
        let provider = makeProviderState(
            activeAccountId: activeId,
            accounts: accounts.map { makeAccount(id: $0.id, name: $0.name) }
        )
        let config = SwitcherooConfig(defaultProviderId: "codex", providers: [provider])
        let harness = try EngineHarness(config: config)
        for account in accounts {
            try harness.secureStore.store(
                try makeCodexAuthData(accessToken: "token-\(account.id)", accountId: "acct-\(account.id)"),
                key: "codex:\(account.id)"
            )
        }
        let fetcher = MockAccountUsageFetcher()
        return (harness, fetcher)
    }

    private func makeApp(
        harness: EngineHarness,
        fetcher: MockAccountUsageFetcher,
        stalenessInterval: TimeInterval = 60
    ) -> SwitcherooApp {
        SwitcherooApp(
            engine: harness.engine,
            fileIO: harness.fileIO,
            providers: [ProviderDescriptor(id: "codex", displayName: "Codex")],
            usageFetcher: fetcher,
            usageStalenessInterval: stalenessInterval
        )
    }

    private func usage(_ accountId: String) -> SwitcherooAccountUsage {
        SwitcherooAccountUsage(
            accountId: accountId,
            fiveHour: SwitcherooUsageWindow(usedPercent: 42, remainingPercent: 58, windowSeconds: 18_000, resetsAt: nil),
            weekly: SwitcherooUsageWindow(usedPercent: 84, remainingPercent: 16, windowSeconds: 604_800, resetsAt: nil),
            fetchedAt: Date()
        )
    }

    private func waitForTerminalState(
        _ app: SwitcherooApp,
        accountId: String,
        timeout: TimeInterval = 3
    ) async -> SwitcherooAccountUsageState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = app.snapshot().usageStatesByAccountId[accountId] ?? .notRequested
            switch state {
            case .loaded, .unavailable:
                return state
            case .loading, .notRequested:
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return app.snapshot().usageStatesByAccountId[accountId] ?? .notRequested
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if opened {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }

        func open() {
            lock.lock()
            opened = true
            continuation?.resume()
            continuation = nil
            lock.unlock()
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private final class UsageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: SwitcherooAccountUsage?

        var usage: SwitcherooAccountUsage {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored ?? SwitcherooAccountUsage(accountId: "", fiveHour: nil, weekly: nil)
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }

    private func waitForCounter(_ counter: Counter, expected: Int, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while counter.value < expected && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testRefreshFetchesUsageForAllAccounts() async throws {
        let (harness, fetcher) = try makeHarness(
            accounts: [("acc-1", "Primary"), ("acc-2", "Backup")],
            activeId: "acc-1"
        )
        fetcher.setResult(accountId: "acc-1", usage: usage("acc-1"))
        fetcher.setResult(accountId: "acc-2", usage: usage("acc-2"))
        let app = makeApp(harness: harness, fetcher: fetcher)

        app.refresh()

        let state = await waitForTerminalState(app, accountId: "acc-1")
        guard case .loaded(let loaded) = state else {
            return XCTFail("expected loaded state, got \(state)")
        }
        XCTAssertEqual(loaded.accountId, "acc-1")
        XCTAssertEqual(loaded.fiveHour?.remainingPercent, 58)
        XCTAssertEqual(Set(fetcher.callAccountIds), ["acc-1", "acc-2"])

        let backup = await waitForTerminalState(app, accountId: "acc-2")
        guard case .loaded(let backupLoaded) = backup else {
            return XCTFail("expected loaded state for acc-2, got \(backup)")
        }
        XCTAssertEqual(backupLoaded.accountId, "acc-2")
    }

    func testRefreshPublishesLoadingStateSynchronously() async throws {
        let gate = Gate()
        let acc1Usage = usage("acc-1")
        let (harness, fetcher) = try makeHarness(accounts: [("acc-1", "Primary")], activeId: "acc-1")
        fetcher.setHandler(accountId: "acc-1") {
            await gate.wait()
            return acc1Usage
        }
        let app = makeApp(harness: harness, fetcher: fetcher)

        app.refresh()

        let loadingState = app.snapshot().usageStatesByAccountId["acc-1"]
        guard case .loading = loadingState else {
            return XCTFail("expected synchronous loading state, got \(String(describing: loadingState))")
        }

        gate.open()
        let state = await waitForTerminalState(app, accountId: "acc-1")
        guard case .loaded = state else {
            return XCTFail("expected loaded state, got \(state)")
        }
    }

    func testSwitchKeepsPerAccountUsageAndDoesNotRefetchFreshRows() async throws {
        let counter = Counter()
        let acc1Usage = usage("acc-1")
        let acc2Usage = usage("acc-2")
        let (harness, fetcher) = try makeHarness(
            accounts: [("acc-1", "Primary"), ("acc-2", "Backup")],
            activeId: "acc-1"
        )
        fetcher.setHandler(accountId: "acc-1") {
            counter.increment()
            return acc1Usage
        }
        fetcher.setHandler(accountId: "acc-2") {
            counter.increment()
            return acc2Usage
        }
        let app = makeApp(harness: harness, fetcher: fetcher)

        app.refresh()
        _ = await waitForTerminalState(app, accountId: "acc-1")
        _ = await waitForTerminalState(app, accountId: "acc-2")
        XCTAssertEqual(counter.value, 2)

        app.switchToAccount(idOrName: "acc-2")

        let snapshot = app.snapshot()
        XCTAssertEqual(snapshot.activeAccountId, "acc-2")
        // Per-row usage survives the switch untouched; fresh rows are not refetched.
        guard case .loaded = snapshot.usageStatesByAccountId["acc-1"] else {
            return XCTFail("acc-1 usage must survive the switch, got \(String(describing: snapshot.usageStatesByAccountId["acc-1"]))")
        }
        guard case .loaded = snapshot.usageStatesByAccountId["acc-2"] else {
            return XCTFail("acc-2 usage must survive the switch, got \(String(describing: snapshot.usageStatesByAccountId["acc-2"]))")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.value, 2, "fresh rows must not be refetched after a switch")
    }

    func testSupersededBatchFoldsInFlightAccountAndDropsOldGeneration() async throws {
        let gate = Gate()
        let counter = Counter()
        let acc1Usage = usage("acc-1")
        let acc2Usage = usage("acc-2")
        let (harness, fetcher) = try makeHarness(
            accounts: [("acc-1", "Primary"), ("acc-2", "Backup")],
            activeId: "acc-1"
        )
        fetcher.setHandler(accountId: "acc-1") {
            counter.increment()
            await gate.wait()
            return acc1Usage
        }
        fetcher.setHandler(accountId: "acc-2") {
            counter.increment()
            return acc2Usage
        }
        let app = makeApp(harness: harness, fetcher: fetcher, stalenessInterval: 0.2)

        app.refresh()
        // Batch 1: acc-1 is blocked in flight; acc-2 loads.
        _ = await waitForTerminalState(app, accountId: "acc-2")

        // acc-2 ages past the staleness window, so a second refresh starts a
        // new batch; the still-in-flight acc-1 must fold into it.
        try await Task.sleep(nanoseconds: 250_000_000)
        app.refresh()

        guard case .loading = app.snapshot().usageStatesByAccountId["acc-1"] else {
            return XCTFail("acc-1 must stay loading while superseded, got \(String(describing: app.snapshot().usageStatesByAccountId["acc-1"]))")
        }
        guard case .loading = app.snapshot().usageStatesByAccountId["acc-2"] else {
            return XCTFail("acc-2 must reload in the new batch, got \(String(describing: app.snapshot().usageStatesByAccountId["acc-2"]))")
        }

        gate.open()
        _ = await waitForTerminalState(app, accountId: "acc-1")
        _ = await waitForTerminalState(app, accountId: "acc-2")

        // acc-1 was fetched twice (once per batch); the older response was dropped.
        XCTAssertEqual(counter.value, 4)
        guard case .loaded(let final) = app.snapshot().usageStatesByAccountId["acc-1"] else {
            return XCTFail("superseded acc-1 must resolve to loaded, got \(String(describing: app.snapshot().usageStatesByAccountId["acc-1"]))")
        }
        XCTAssertEqual(final.accountId, "acc-1")
    }

    func testRefreshDoesNotDuplicateFetchWhileLoading() async throws {
        let gate = Gate()
        let counter = Counter()
        let acc1Usage = usage("acc-1")
        let (harness, fetcher) = try makeHarness(accounts: [("acc-1", "Primary")], activeId: "acc-1")
        fetcher.setHandler(accountId: "acc-1") {
            counter.increment()
            await gate.wait()
            return acc1Usage
        }
        let app = makeApp(harness: harness, fetcher: fetcher)

        app.refresh()
        app.refresh()
        app.refresh()
        // Wait for the single in-flight fetch to actually start executing.
        await waitForCounter(counter, expected: 1)

        XCTAssertEqual(counter.value, 1, "duplicate refreshes while loading must not start new requests")

        gate.open()
        _ = await waitForTerminalState(app, accountId: "acc-1")
        XCTAssertEqual(counter.value, 1)
    }

    func testRefreshSkipsFreshResultsAndRefetchesStaleOnes() async throws {
        let counter = Counter()
        let acc1Usage = usage("acc-1")
        let (harness, fetcher) = try makeHarness(accounts: [("acc-1", "Primary")], activeId: "acc-1")
        fetcher.setHandler(accountId: "acc-1") {
            counter.increment()
            return acc1Usage
        }
        let app = makeApp(harness: harness, fetcher: fetcher, stalenessInterval: 0.2)

        app.refresh()
        _ = await waitForTerminalState(app, accountId: "acc-1")
        XCTAssertEqual(counter.value, 1)

        // Fresh result (within the 200ms staleness window): skip.
        app.refresh()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.value, 1)

        // Once the published result ages past the staleness window, refresh again.
        try await Task.sleep(nanoseconds: 250_000_000)
        app.refresh()
        _ = await waitForTerminalState(app, accountId: "acc-1")
        XCTAssertEqual(counter.value, 2)
    }

    func testPartialFailureIsolationKeepsOtherRowsAndSwitchWorking() async throws {
        let (harness, fetcher) = try makeHarness(
            accounts: [("acc-1", "Primary"), ("acc-2", "Backup")],
            activeId: "acc-1"
        )
        fetcher.setError(accountId: "acc-1", error: SwitcherooUsageError.authenticationFailed)
        fetcher.setResult(accountId: "acc-2", usage: usage("acc-2"))
        let app = makeApp(harness: harness, fetcher: fetcher)

        app.refresh()

        let state = await waitForTerminalState(app, accountId: "acc-1")
        guard case .unavailable(let reason) = state else {
            return XCTFail("expected unavailable state, got \(state)")
        }
        XCTAssertEqual(reason, SwitcherooUsageError.authenticationFailed.diagnosticMessage)
        XCTAssertFalse(reason?.contains("token") ?? false, "diagnostics must not leak credentials")

        // The other account's row loaded despite acc-1's failure.
        let other = await waitForTerminalState(app, accountId: "acc-2")
        guard case .loaded(let loaded) = other else {
            return XCTFail("acc-2 must load despite acc-1's failure, got \(other)")
        }
        XCTAssertEqual(loaded.accountId, "acc-2")

        app.switchToAccount(idOrName: "acc-2")
        let switched = await waitForTerminalState(app, accountId: "acc-2")
        guard case .loaded = switched else {
            return XCTFail("switch must still succeed after a usage failure, got \(switched)")
        }
    }

    func testMissingSavedCredentialPublishesUnavailable() async throws {
        let (harness, fetcher) = try makeHarness(accounts: [("acc-1", "Primary")], activeId: "acc-1")
        try? harness.secureStore.delete(key: "codex:acc-1")
        let app = makeApp(harness: harness, fetcher: fetcher)

        app.refresh()

        let state = await waitForTerminalState(app, accountId: "acc-1")
        guard case .unavailable = state else {
            return XCTFail("expected unavailable state, got \(state)")
        }
        XCTAssertEqual(fetcher.callAccountIds, [])
    }

    func testNoFetcherLeavesUsageStatesEmpty() throws {
        let (harness, _) = try makeHarness(accounts: [("acc-1", "Primary")], activeId: "acc-1")
        let app = SwitcherooApp(
            engine: harness.engine,
            fileIO: harness.fileIO,
            providers: [ProviderDescriptor(id: "codex", displayName: "Codex")]
        )

        app.refresh()

        XCTAssertTrue(app.snapshot().usageStatesByAccountId.isEmpty)
    }

    func testUsageUpdatedCallbackFiresWhenResultsPublish() async throws {
        let counter = Counter()
        let (harness, fetcher) = try makeHarness(accounts: [("acc-1", "Primary")], activeId: "acc-1")
        fetcher.setResult(accountId: "acc-1", usage: usage("acc-1"))
        let app = makeApp(harness: harness, fetcher: fetcher)
        app.onUsageUpdated = {
            counter.increment()
        }

        app.refresh()
        _ = await waitForTerminalState(app, accountId: "acc-1")

        XCTAssertGreaterThanOrEqual(counter.value, 1, "live views must be notified when a usage result lands")
    }

    func testDeletingAccountPrunesItsUsageRow() async throws {
        let gate = Gate()
        let acc1Usage = usage("acc-1")
        let acc2Usage = usage("acc-2")
        let (harness, fetcher) = try makeHarness(
            accounts: [("acc-1", "Primary"), ("acc-2", "Backup")],
            activeId: "acc-1"
        )
        fetcher.setHandler(accountId: "acc-1") {
            await gate.wait()
            return acc1Usage
        }
        fetcher.setResult(accountId: "acc-2", usage: acc2Usage)
        let app = makeApp(harness: harness, fetcher: fetcher)

        app.refresh()
        _ = await waitForTerminalState(app, accountId: "acc-2")

        app.deleteAccount(idOrName: "acc-2")

        let snapshot = app.snapshot()
        XCTAssertNil(snapshot.usageStatesByAccountId["acc-2"], "deleted account usage must be pruned")

        gate.open()
        _ = await waitForTerminalState(app, accountId: "acc-1")
        XCTAssertNil(app.snapshot().usageStatesByAccountId["acc-2"])
    }
}
