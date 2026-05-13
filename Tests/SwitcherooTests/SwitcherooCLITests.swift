import XCTest
@testable import SwitcherooCLI
import SwitcherooCore
import SwitcherooPresentation

final class SwitcherooCLITests: XCTestCase {
    func testNoArgumentsPrintUsage() {
        let app = MockSwitcherooApp()
        var output: [String] = []
        var errors: [String] = []

        let cli = SwitcherooCLI(
            app: app,
            output: { output.append($0) },
            errorOutput: { errors.append($0) }
        )

        let exitCode = cli.run(arguments: [])

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(app.refreshCalls, 0)
        XCTAssertEqual(output.count, 1)
        XCTAssertTrue(output[0].contains("switcheroo list"))
        XCTAssertTrue(output[0].contains("switcheroo sync"))
    }

    func testListPrintsNoAccountsWhenEmpty() {
        let app = MockSwitcherooApp()
        var output: [String] = []

        let cli = SwitcherooCLI(app: app, output: { output.append($0) }, errorOutput: { _ in })

        let exitCode = cli.run(arguments: ["list"])

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(app.refreshCalls, 1)
        XCTAssertEqual(output, ["(no accounts)"])
    }

    func testListPrintsAccountsAndHighlightsActive() {
        let active = makeAccount(id: "acc-1", name: "Active")
        let inactive = makeAccount(id: "acc-2", name: "Backup")
        let app = MockSwitcherooApp(
            state: SwitcherooAppState(
                accounts: [active, inactive],
                activeAccountId: active.id
            )
        )
        var output: [String] = []

        let cli = SwitcherooCLI(app: app, output: { output.append($0) }, errorOutput: { _ in })

        let exitCode = cli.run(arguments: ["list"])

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(app.refreshCalls, 1)
        XCTAssertEqual(output, ["* Active", "  Backup"])
    }

    func testCurrentPrintsActiveAccountName() {
        let active = makeAccount(id: "acc-1", name: "Active")
        let app = MockSwitcherooApp(
            state: SwitcherooAppState(accounts: [active], activeAccountId: active.id)
        )
        var output: [String] = []

        let cli = SwitcherooCLI(app: app, output: { output.append($0) }, errorOutput: { _ in })

        let exitCode = cli.run(arguments: ["current"])

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(app.refreshCalls, 1)
        XCTAssertEqual(output, ["Active"])
    }

    func testCurrentPrintsNoActiveAccountWhenMissing() {
        let app = MockSwitcherooApp(
            state: SwitcherooAppState(accounts: [makeAccount(id: "acc-1", name: "Only")])
        )
        var output: [String] = []

        let cli = SwitcherooCLI(app: app, output: { output.append($0) }, errorOutput: { _ in })

        let exitCode = cli.run(arguments: ["current"])

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(output, ["(no active account)"])
    }

    func testImportCurrentAndAddAndSyncCommands() {
        let pending = PendingLogin(
            providerId: "codex",
            accountId: "pending-1",
            accountName: "Derived",
            providerHomePath: "/tmp/codex/pending-1",
            expectedAuthFilePath: "/tmp/codex/pending-1/auth.json"
        )
        let account = makeAccount(id: "acc-3", name: "Imported")
        let app = MockSwitcherooApp()
        app.nextPendingLogin = pending
        app.nextImportedAccount = account

        var output: [String] = []

        let cli = SwitcherooCLI(
            app: app,
            output: { output.append($0) },
            errorOutput: { _ in }
        )

        XCTAssertEqual(cli.run(arguments: ["import-current", "Personal"]), 0)
        XCTAssertEqual(cli.run(arguments: ["add", "Work", "--set-active"]), 0)
        XCTAssertEqual(cli.run(arguments: ["sync"]), 0)

        XCTAssertEqual(app.importCurrentAccountNameCalls, ["Personal"])
        XCTAssertEqual(app.startAddAccountNameCalls, ["Work"])
        XCTAssertEqual(app.finalizeSetActiveCalls, [true])
        XCTAssertEqual(app.syncCalls, 3)
        XCTAssertEqual(output, [
            "Imported 'Personal'.",
            "Added 'Work'.",
            "Synced.",
        ])
    }

    func testImportCurrentAndAddReportUpdatedExistingAccountForDuplicates() {
        let pending = PendingLogin(
            providerId: "codex",
            accountId: "pending-dup",
            accountName: "Derived",
            providerHomePath: "/tmp/codex/pending-dup",
            expectedAuthFilePath: "/tmp/codex/pending-dup/auth.json"
        )
        let account = makeAccount(id: "acc-existing", name: "Existing")
        let app = MockSwitcherooApp(state: SwitcherooAppState(accounts: [account]))
        app.nextPendingLogin = pending
        app.nextImportedAccount = account
        app.nextFinalizedAccount = account
        app.nextImportedDisposition = .updatedExisting
        app.nextFinalizedDisposition = .updatedExisting

        var output: [String] = []
        let cli = SwitcherooCLI(app: app, output: { output.append($0) }, errorOutput: { _ in })

        XCTAssertEqual(cli.run(arguments: ["import-current", "Personal"]), 0)
        XCTAssertEqual(cli.run(arguments: ["add", "Work", "--set-active"]), 0)

        XCTAssertEqual(output, [
            "Updated existing account 'Existing'.",
            "Updated existing account 'Existing'.",
        ])
    }

    func testCommandPrintsShortReloginWarningWhenOpportunisticSyncCannotMatchAccount() {
        let app = MockSwitcherooApp()
        app.nextSyncResult = SwitcherooActiveSnapshotSyncResult(
            disposition: .skippedUnmatchedIdentity,
            account: nil,
            accessTokenExpiry: nil
        )
        var output: [String] = []
        var errors: [String] = []
        let cli = SwitcherooCLI(
            app: app,
            output: { output.append($0) },
            errorOutput: { errors.append($0) }
        )

        XCTAssertEqual(cli.run(arguments: ["list"]), 0)

        XCTAssertEqual(app.syncCalls, 1)
        XCTAssertEqual(output, ["(no accounts)"])
        XCTAssertEqual(errors, ["switcheroo: Re-login required."])
    }

    func testSwitchDeleteAndMissingArgumentErrors() {
        let app = MockSwitcherooApp(state: SwitcherooAppState(accounts: [makeAccount(id: "acc-1", name: "One")]))
        var output: [String] = []
        var errors: [String] = []

        let cli = SwitcherooCLI(
            app: app,
            output: { output.append($0) },
            errorOutput: { errors.append($0) }
        )

        XCTAssertEqual(cli.run(arguments: ["switch", "acc"]), 0)
        XCTAssertEqual(cli.run(arguments: ["delete", "One"]), 0)
        XCTAssertEqual(cli.run(arguments: ["add", "--set-active"]), 1)
        XCTAssertEqual(cli.run(arguments: ["bogus"]), 0)

        XCTAssertEqual(app.switchCalls, ["acc"])
        XCTAssertEqual(app.deleteCalls, ["One"])
        XCTAssertEqual(output.last, """
        switcheroo (Codex account failover helper)

        Usage:
          switcheroo list
          switcheroo current
          switcheroo add <name> [--set-active]
          switcheroo import-current <name>
          switcheroo switch <account-name>
          switcheroo delete <account-name>
          switcheroo sync
        """)
        XCTAssertEqual(errors, ["switcheroo: Missing argument: name"])
    }
}
