import Foundation
import SwitcherooDefaultApp

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

        let factory = SwitcherooDefaultAppFactory()
        let app = try factory.make(loginStyle: .cliInteractive)

        switch cmd {
        case "list":
            app.refresh()
            let state = app.snapshot()
            if state.accounts.isEmpty {
                print("(no accounts)")
                return
            }
            for acc in state.accounts {
                let activeMark = (state.activeAccountId == acc.id) ? "*" : " "
                print("\(activeMark) \(acc.name)")
            }

        case "current":
            app.refresh()
            let state = app.snapshot()
            if let id = state.activeAccountId, let active = state.accounts.first(where: { $0.id == id }) {
                print(active.name)
            } else {
                print("(no active account)")
            }

        case "import-current":
            let name = try requireArg(args.dropFirst(), label: "name")
            app.importCurrentAccount(name: name)
            app.refresh()
            print("Imported '\(name)'.")

        case "add":
            let name = try requireArg(args.dropFirst(), label: "name")
            let setActive = args.contains("--set-active")
            app.startAddAccount(name: name)
            app.finalizePendingIfReady(setActive: setActive)
            app.refresh()
            print("Added '\(name)'.")

        case "switch":
            let idOrName = try requireArg(args.dropFirst(), label: "account-name")
            app.switchToAccount(idOrName: idOrName)
            print("Switched.")

        case "delete":
            let idOrName = try requireArg(args.dropFirst(), label: "account-name")
            app.deleteAccount(idOrName: idOrName)
            print("Deleted.")

        case "sync":
            app.syncActiveSnapshot()
            print("Synced.")

        default:
            printUsage()
        }
    }

    private static func requireArg<S: Sequence>(_ seq: S, label: String) throws -> String where S.Element == String {
        if let v = Array(seq).first, !v.hasPrefix("--") {
            return v
        }
        throw NSError(domain: "switcheroo.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing argument: \(label)"])
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
              switcheroo switch <account-name>
              switcheroo delete <account-name>
              switcheroo sync
            """
        )
    }
}

