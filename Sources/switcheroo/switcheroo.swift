import Foundation
import SwitcherooCore

@main
struct switcheroo {
    static func main() {
        do {
            try run()
        } catch {
            fputs("switcheroo: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        var args = CommandLine.arguments
        _ = args.first
        args.removeFirst()

        guard let cmd = args.first else {
            printUsage()
            return
        }

        let service = try SwitcherooService()

        switch cmd {
        case "list":
            let accounts = service.listAccounts()
            if accounts.isEmpty {
                print("(no accounts)")
                return
            }
            for acc in accounts {
                let activeMark = (service.activeAccount()?.id == acc.id) ? "*" : " "
                print("\(activeMark) \(acc.name) (\(acc.id))")
            }

        case "current":
            if let active = service.activeAccount() {
                print("\(active.name) (\(active.id))")
            } else {
                print("(no active account)")
            }

        case "import-current":
            let name = try requireArg(args.dropFirst(), label: "name")
            _ = try service.importCurrentAccount(name: name, setActive: false)
            print("Imported '\(name)'.")

        case "add":
            let name = try requireArg(args.dropFirst(), label: "name")
            let setActive = args.contains("--set-active")

            let pending = try service.prepareAddAccount(name: name)
            try runCodexLoginInteractive(codexHomePath: pending.codexHomePath)
            try service.finalizeAddAccount(pending, setActive: setActive)
            print("Added '\(name)'.")

        case "switch":
            let idOrName = try requireArg(args.dropFirst(), label: "account-id-or-name")
            let targetId = resolveAccountId(service: service, idOrName: idOrName)
            try service.switchToAccount(accountId: targetId)
            print("Switched.")

        case "delete":
            let idOrName = try requireArg(args.dropFirst(), label: "account-id-or-name")
            let targetId = resolveAccountId(service: service, idOrName: idOrName)
            try service.deleteAccount(accountId: targetId)
            print("Deleted.")

        case "sync":
            let did = try service.syncActiveAccountSnapshotIfNeeded()
            print(did ? "Synced." : "No active account.")

        default:
            printUsage()
        }
    }

    private static func resolveAccountId(service: SwitcherooService, idOrName: String) -> String {
        let accounts = service.listAccounts()
        if let exact = accounts.first(where: { $0.id == idOrName }) {
            return exact.id
        }
        if let byName = accounts.first(where: { $0.name == idOrName }) {
            return byName.id
        }
        // fall back to prefix match on id
        if let byPrefix = accounts.first(where: { $0.id.lowercased().hasPrefix(idOrName.lowercased()) }) {
            return byPrefix.id
        }
        return idOrName
    }

    private static func requireArg<S: Sequence>(_ seq: S, label: String) throws -> String where S.Element == String {
        if let v = Array(seq).first, !v.hasPrefix("--") {
            return v
        }
        throw NSError(domain: "switcheroo.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing argument: \(label)"])
    }

    private static func runCodexLoginInteractive(codexHomePath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "login"]

        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHomePath
        process.environment = env

        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw SwitcherooError.codexLoginFailed(exitCode: process.terminationStatus, stderr: "")
        }
    }

    private static func printUsage() {
        print(
            """
            switcheroo (Codex account failover helper)

            Usage:
              switcheroo list
              switcheroo current
              switcheroo add <name> [--set-active]
              switcheroo import-current <name>
              switcheroo switch <account-id-or-name>
              switcheroo delete <account-id-or-name>
              switcheroo sync
            """
        )
    }
}
