import Foundation
import SwitcherooCLI
import SwitcherooDefaultApp

@main
struct switcheroo {
    static func main() {
        do {
            let factory = SwitcherooDefaultAppFactory()
            let app = try factory.make(loginStyle: .cliInteractive)
            let cli = SwitcherooCLI(app: app)
            let exitCode = cli.run(arguments: Array(CommandLine.arguments.dropFirst()))
            exit(Int32(exitCode))
        } catch {
            fputs("switcheroo: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
