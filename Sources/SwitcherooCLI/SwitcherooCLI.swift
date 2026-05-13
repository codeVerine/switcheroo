import Foundation
import SwitcherooCore
import SwitcherooPresentation

enum SwitcherooCLIError: LocalizedError {
    case missingArgument(label: String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let label):
            return "Missing argument: \(label)"
        }
    }
}

public struct SwitcherooCLI {
    private let app: any SwitcherooAppControlling
    private let output: (String) -> Void
    private let errorOutput: (String) -> Void

    public init(
        app: any SwitcherooAppControlling,
        output: @escaping (String) -> Void = { print($0) },
        errorOutput: @escaping (String) -> Void = { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    ) {
        self.app = app
        self.output = output
        self.errorOutput = errorOutput
    }

    @discardableResult
    public func run(arguments: [String]) -> Int {
        do {
            try runOrThrow(arguments: arguments)
            return 0
        } catch {
            errorOutput("switcheroo: \(error.localizedDescription)")
            return 1
        }
    }

    private func runOrThrow(arguments: [String]) throws {
        guard let command = arguments.first else {
            output(usageText)
            return
        }

        let args = Array(arguments.dropFirst())
        // Best-effort: try to keep the active snapshot fresh, but only once per command.
        // (The explicit `sync` command handles its own sync.)
        if command != "sync" {
            _ = app.syncActiveSnapshot()
            if app.snapshot().requiresRelogin {
                errorOutput("switcheroo: Re-login required.")
            }
        }

        switch command {
        case "list":
            app.refresh()
            let state = app.snapshot()
            if state.accounts.isEmpty {
                output("(no accounts)")
                return
            }

            for account in state.accounts {
                let activeMark = (state.activeAccountId == account.id) ? "*" : " "
                output("\(activeMark) \(account.name)")
            }

        case "current":
            app.refresh()
            let state = app.snapshot()
            if let id = state.activeAccountId, let active = state.accounts.first(where: { $0.id == id }) {
                output(active.name)
            } else {
                output("(no active account)")
            }

        case "import-current":
            let name = try requireArg(args, label: "name")
            let result = app.importCurrentAccount(name: name)
            app.refresh()
            output(importOutput(defaultName: name, result: result))

        case "add":
            let name = try requireArg(args, label: "name")
            let setActive = args.contains("--set-active")
            app.startAddAccount(name: name)
            let result = app.finalizePendingIfReady(setActive: setActive)
            app.refresh()
            output(addOutput(defaultName: name, result: result))

        case "switch":
            let idOrName = try requireArg(args, label: "account-name")
            app.switchToAccount(idOrName: idOrName)
            output("Switched.")

        case "delete":
            let idOrName = try requireArg(args, label: "account-name")
            app.deleteAccount(idOrName: idOrName)
            output("Deleted.")

        case "sync":
            _ = app.syncActiveSnapshot()
            if app.snapshot().requiresRelogin {
                errorOutput("switcheroo: Re-login required.")
            }
            output("Synced.")

        default:
            output(usageText)
        }
    }

    private func requireArg(_ args: [String], label: String) throws -> String {
        guard let value = args.first, !value.hasPrefix("--") else {
            throw SwitcherooCLIError.missingArgument(label: label)
        }
        return value
    }

    private func importOutput(defaultName: String, result: SwitcherooAccountWriteResult?) -> String {
        switch result?.disposition {
        case .updatedExisting:
            return "Updated existing account '\(result?.account?.name ?? defaultName)'."
        default:
            return "Imported '\(defaultName)'."
        }
    }

    private func addOutput(defaultName: String, result: SwitcherooAccountWriteResult?) -> String {
        switch result?.disposition {
        case .updatedExisting:
            return "Updated existing account '\(result?.account?.name ?? defaultName)'."
        default:
            return "Added '\(defaultName)'."
        }
    }

    private var usageText: String {
        """
        switcheroo (Codex account failover helper)

        Usage:
          switcheroo list
          switcheroo current
          switcheroo add <name> [--set-active]
          switcheroo import-current <name>
          switcheroo switch <account-name>
          switcheroo delete <account-name>
          switcheroo sync
        """
    }
}
