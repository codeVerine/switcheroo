import XCTest
import SwitcherooCodexProvider
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
        stalenessInterval: TimeInterval = 60,
        failureCooldown: TimeInterval = 30,
        clock: FakeClock? = nil
    ) -> SwitcherooApp {
        let now: @Sendable () -> Date
        if let clock {
            now = { clock.now }
        } else {
            now = { Date() }
        }
        return SwitcherooApp(
            engine: harness.engine,
            fileIO: harness.fileIO,
            providers: [ProviderDescriptor(id: "codex", displayName: "Codex")],
            usageFetcher: fetcher,
            usageStalenessInterval: stalenessInterval,
            usageFailureCooldown: failureCooldown,
            now: now
        )
    }

    private func usage(_ accountId: String, fetchedAt: Date = Date()) -> SwitcherooAccountUsage {
        SwitcherooAccountUsage(
            accountId: accountId,
            fiveHour: SwitcherooUsageWindow(usedPercent: 42, remainingPercent: 58, windowSeconds: 18_000, resetsAt: nil),
            weekly: SwitcherooUsageWindow(usedPercent: 84, remainingPercent: 16, windowSeconds: 604_800, resetsAt: nil),
            fetchedAt: fetchedAt
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
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if opened {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                continuations.append(continuation)
                lock.unlock()
            }
        }

        func open() {
            lock.lock()
            opened = true
            let waiting = continuations
            continuations = []
            lock.unlock()
            for continuation in waiting {
                continuation.resume()
            }
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

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
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

    func testSwitchStartsFreshAllAccountGenerationEvenWhenRowsAreCached() async throws {
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

        // The switch must start a second all-account generation even though
        // every row is still inside the one-minute freshness cache.
        try app.switchToAccount(idOrName: "acc-2")

        let snapshot = app.snapshot()
        XCTAssertEqual(snapshot.activeAccountId, "acc-2")
        guard case .loading = snapshot.usageStatesByAccountId["acc-1"] else {
            return XCTFail("switch generation must reload acc-1, got \(String(describing: snapshot.usageStatesByAccountId["acc-1"]))")
        }
        guard case .loading = snapshot.usageStatesByAccountId["acc-2"] else {
            return XCTFail("switch generation must reload acc-2, got \(String(describing: snapshot.usageStatesByAccountId["acc-2"]))")
        }

        _ = await waitForTerminalState(app, accountId: "acc-1")
        _ = await waitForTerminalState(app, accountId: "acc-2")
        XCTAssertEqual(counter.value, 4, "the switch must run one fresh all-account batch")
    }

    func testSupersededBatchFoldsInFlightAccountAndDropsOldGeneration() async throws {
        let gate = Gate()
        let counter = Counter()
        let clock = FakeClock()
        let acc1Usage = usage("acc-1", fetchedAt: clock.now)
        let acc2Usage = usage("acc-2", fetchedAt: clock.now)
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
        let app = makeApp(harness: harness, fetcher: fetcher, clock: clock)

        app.refresh()
        // Batch 1: acc-1 is blocked in flight; acc-2 loads.
        _ = await waitForTerminalState(app, accountId: "acc-2")

        // acc-2 ages past the 60s staleness window, so a second refresh starts
        // a new batch; the still-in-flight acc-1 must fold into it.
        clock.advance(by: 61)
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
        let clock = FakeClock()
        let acc1Usage = usage("acc-1", fetchedAt: clock.now)
        let (harness, fetcher) = try makeHarness(accounts: [("acc-1", "Primary")], activeId: "acc-1")
        fetcher.setHandler(accountId: "acc-1") {
            counter.increment()
            return acc1Usage
        }
        let app = makeApp(harness: harness, fetcher: fetcher, clock: clock)

        app.refresh()
        _ = await waitForTerminalState(app, accountId: "acc-1")
        XCTAssertEqual(counter.value, 1)

        // Fresh result (clock unchanged): skip.
        app.refresh()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.value, 1)

        // Once the clock advances past the 60s staleness window, refresh again.
        clock.advance(by: 61)
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

        try app.switchToAccount(idOrName: "acc-2")
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

    func testDeletingInFlightAccountNeverPublishes() async throws {
        let gate = Gate()
        let acc1Usage = usage("acc-1")
        let (harness, fetcher) = try makeHarness(accounts: [("acc-1", "Primary")], activeId: "acc-1")
        fetcher.setHandler(accountId: "acc-1") {
            await gate.wait()
            return acc1Usage
        }
        let app = makeApp(harness: harness, fetcher: fetcher)
        let callbackCounter = Counter()
        app.onUsageUpdated = { callbackCounter.increment() }

        app.refresh()
        await waitUntil { fetcher.callAccountIds.count == 1 }
        guard case .loading = app.snapshot().usageStatesByAccountId["acc-1"] else {
            return XCTFail("expected in-flight loading state, got \(String(describing: app.snapshot().usageStatesByAccountId["acc-1"]))")
        }

        app.deleteAccount(idOrName: "acc-1")
        XCTAssertTrue(app.snapshot().usageStatesByAccountId.isEmpty)

        let callbacksBeforeRelease = callbackCounter.value
        gate.open()
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(
            app.snapshot().usageStatesByAccountId.isEmpty,
            "a deleted account's in-flight result must never re-publish"
        )
        XCTAssertEqual(
            callbackCounter.value,
            callbacksBeforeRelease,
            "no usage callback may fire for a deleted account"
        )
    }

    func testAddDuringFetchFoldsIntoNewGenerationAndResolves() async throws {
        let gate = Gate()
        let acc1Usage = usage("acc-1")
        let (harness, fetcher) = try makeHarness(accounts: [("acc-1", "Primary")], activeId: "acc-1")
        fetcher.setHandler(accountId: "acc-1") {
            await gate.wait()
            return acc1Usage
        }
        fetcher.setDefaultResult(usage("acc-2"))
        let app = makeApp(harness: harness, fetcher: fetcher)

        app.refresh()
        await waitUntil { fetcher.callAccountIds.count == 1 }

        // Add a second account while acc-1's fetch is still in flight.
        app.startAddAccount(name: "Work")
        let pending = try XCTUnwrap(app.snapshot().pendingLogin)
        harness.fileIO.files[pending.expectedAuthFilePath] = try makeAuthData(
            email: "work@example.com",
            accountId: "acct-2",
            accessTokenExpiry: Date().addingTimeInterval(3600)
        )
        app.finalizePendingIfReady(setActive: false)

        let addedId = try XCTUnwrap(app.snapshot().accounts.first { $0.name == "Work" }?.id)

        // The new account must load; acc-1 folds into the replacement generation.
        let added = await waitForTerminalState(app, accountId: addedId)
        guard case .loaded = added else {
            return XCTFail("newly added account must load, got \(added)")
        }

        gate.open()
        let acc1 = await waitForTerminalState(app, accountId: "acc-1")
        guard case .loaded = acc1 else {
            return XCTFail("superseded acc-1 must still resolve, got \(acc1)")
        }
        XCTAssertEqual(fetcher.callAccountIds.filter { $0 == "acc-1" }.count, 2)
    }

    func testNetworkConcurrencyIsBoundedToThree() async throws {
        let gate = Gate()
        let accountIds = (1...6).map { "acc-\($0)" }
        let accounts = accountIds.map { ($0, "Account \($0)") }
        let (harness, fetcher) = try makeHarness(accounts: accounts, activeId: "acc-1")
        let accUsages = accountIds.map { usage($0) }
        for (index, accountId) in accountIds.enumerated() {
            fetcher.setHandler(accountId: accountId) {
                await gate.wait()
                return accUsages[index]
            }
        }
        let app = makeApp(harness: harness, fetcher: fetcher)

        app.refresh()

        // Only the rolling limit may run at once; the rest wait in the queue.
        await waitUntil { fetcher.callAccountIds.count == 3 }
        XCTAssertEqual(fetcher.maxConcurrentCalls, 3, "concurrency must be capped at the rolling limit")

        gate.open()
        await waitUntil { fetcher.callAccountIds.count == 6 }
        XCTAssertLessThanOrEqual(fetcher.maxConcurrentCalls, 3, "the concurrency limit must not regress")

        for accountId in accountIds {
            let state = await waitForTerminalState(app, accountId: accountId)
            guard case .loaded = state else {
                return XCTFail("expected loaded state for \(accountId), got \(state)")
            }
        }
    }

    func testSupersededBatchStopsSchedulingQueuedWorkAndOrdersActiveFirst() async throws {
        let gate = Gate()
        let accountIds = (1...6).map { "acc-\($0)" }
        let accounts = accountIds.map { ($0, "Account \($0)") }
        let (harness, fetcher) = try makeHarness(accounts: accounts, activeId: "acc-1")
        let accUsages = accountIds.map { usage($0) }
        for (index, accountId) in accountIds.enumerated() {
            fetcher.setHandler(accountId: accountId) {
                await gate.wait()
                return accUsages[index]
            }
        }
        let app = makeApp(harness: harness, fetcher: fetcher)

        // Batch A: three children start and block; the rest wait in the queue.
        app.refresh()
        await waitUntil { fetcher.callAccountIds.count == 3 }

        // A switch starts batch B (new generation, active account first) while
        // A's three requests are still blocked. A's queued work must not start.
        app.switchToAccount(idOrName: "acc-6")
        await waitUntil { fetcher.callAccountIds.count == 6 }

        let calls = fetcher.callAccountIds
        XCTAssertEqual(calls.count, 6)
        XCTAssertTrue(
            Set(calls).isSubset(of: ["acc-1", "acc-2", "acc-3", "acc-6"]),
            "superseded batch A must stop scheduling queued work; active-first switch must start acc-6: got \(calls)"
        )

        // Release everything: both batches finish; B covers every account.
        gate.open()
        for accountId in accountIds {
            let state = await waitForTerminalState(app, accountId: accountId)
            guard case .loaded = state else {
                return XCTFail("expected loaded state for \(accountId), got \(state)")
            }
        }
        XCTAssertEqual(fetcher.callAccountIds.count, 9, "batch A contributes 3 calls, batch B contributes 6")
    }

    func testCredentialsNeverCrossAccounts() async throws {        let (harness, fetcher) = try makeHarness(
            accounts: [("acc-1", "Primary"), ("acc-2", "Backup")],
            activeId: "acc-1"
        )
        fetcher.setResult(accountId: "acc-1", usage: usage("acc-1"))
        fetcher.setResult(accountId: "acc-2", usage: usage("acc-2"))
        let app = makeApp(harness: harness, fetcher: fetcher)

        app.refresh()
        _ = await waitForTerminalState(app, accountId: "acc-1")
        _ = await waitForTerminalState(app, accountId: "acc-2")

        // Each account's fetch must carry exactly its own saved credential.
        let byAccount = fetcher.recordedAuthDataByAccount
        let acc1Credential = try XCTUnwrap(
            CodexAPIClient.credential(fromAuthData: try XCTUnwrap(byAccount["acc-1"]))
        )
        let acc2Credential = try XCTUnwrap(
            CodexAPIClient.credential(fromAuthData: try XCTUnwrap(byAccount["acc-2"]))
        )
        XCTAssertEqual(acc1Credential.accessToken, "token-acc-1")
        XCTAssertEqual(acc1Credential.accountId, "acct-acc-1")
        XCTAssertEqual(acc2Credential.accessToken, "token-acc-2")
        XCTAssertEqual(acc2Credential.accountId, "acct-acc-2")
    }

    func testZeroAccountsStartsNoBatch() throws {
        let (harness, fetcher) = try makeHarness(accounts: [])
        let app = makeApp(harness: harness, fetcher: fetcher)

        app.refresh()

        XCTAssertTrue(app.snapshot().usageStatesByAccountId.isEmpty)
        XCTAssertEqual(fetcher.callAccountIds, [])
    }

    func testSyncActiveSnapshotDoesNotFetchUsage() throws {
        let (harness, fetcher) = try makeHarness(accounts: [("acc-1", "Primary")], activeId: "acc-1")
        let app = makeApp(harness: harness, fetcher: fetcher)

        app.syncActiveSnapshot()

        XCTAssertEqual(fetcher.callAccountIds, [], "the auth-sync timer path must never fetch usage")
        XCTAssertTrue(app.snapshot().usageStatesByAccountId.isEmpty)
    }

    func testUnavailableRowsRespectFailureCooldown() async throws {
        let clock = FakeClock()
        let (harness, fetcher) = try makeHarness(accounts: [("acc-1", "Primary")], activeId: "acc-1")
        fetcher.setError(accountId: "acc-1", error: SwitcherooUsageError.networkUnavailable)
        let app = makeApp(harness: harness, fetcher: fetcher, clock: clock)

        app.refresh()
        _ = await waitForTerminalState(app, accountId: "acc-1")
        XCTAssertEqual(fetcher.callAccountIds.count, 1)

        // Inside the cooldown (clock unchanged): no retry.
        app.refresh()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fetcher.callAccountIds.count, 1, "failed rows must not be retried inside the cooldown")

        // Past the 30s cooldown: retry happens.
        clock.advance(by: 31)
        app.refresh()
        _ = await waitForTerminalState(app, accountId: "acc-1")
        XCTAssertEqual(fetcher.callAccountIds.count, 2)
    }

    func testRetryAfterExtendsCooldown() async throws {
        let clock = FakeClock()
        let (harness, fetcher) = try makeHarness(accounts: [("acc-1", "Primary")], activeId: "acc-1")
        fetcher.setError(accountId: "acc-1", error: SwitcherooUsageError.serviceUnavailable(retryAfterSeconds: 600))
        let app = makeApp(harness: harness, fetcher: fetcher, clock: clock)

        app.refresh()
        _ = await waitForTerminalState(app, accountId: "acc-1")
        XCTAssertEqual(fetcher.callAccountIds.count, 1)

        // Even past the 30s default cooldown, the server's 600s hint wins.
        clock.advance(by: 120)
        app.refresh()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fetcher.callAccountIds.count, 1, "the server Retry-After hint must extend the cooldown")
    }

    func testMissingCredentialRespectsCooldown() async throws {
        let clock = FakeClock()
        let (harness, fetcher) = try makeHarness(accounts: [("acc-1", "Primary")], activeId: "acc-1")
        try? harness.secureStore.delete(key: "codex:acc-1")
        let app = makeApp(harness: harness, fetcher: fetcher, clock: clock)
        let credentialLoadCount = { () -> Int in
            harness.secureStore.recordedLoadedKeys.filter { $0 == "codex:acc-1" }.count
        }

        app.refresh()
        _ = await waitForTerminalState(app, accountId: "acc-1")
        XCTAssertTrue(fetcher.callAccountIds.isEmpty)
        let loadsAfterFirstRefresh = credentialLoadCount()

        // Inside the cooldown, a refresh must not re-read the missing
        // credential or put the row back into loading. Only the metadata
        // refresh reads the store, so the delta stays at one load.
        app.refresh()
        try await Task.sleep(nanoseconds: 50_000_000)
        let deltaInsideCooldown = credentialLoadCount() - loadsAfterFirstRefresh
        XCTAssertEqual(deltaInsideCooldown, 1, "missing-credential rows must respect the failure cooldown")

        // Past the cooldown the credential is read again (metadata + usage prep).
        clock.advance(by: 31)
        app.refresh()
        try await Task.sleep(nanoseconds: 50_000_000)
        let deltaPastCooldown = credentialLoadCount() - loadsAfterFirstRefresh - deltaInsideCooldown
        XCTAssertEqual(deltaPastCooldown, 2)
    }
}
