import Foundation
import SwitcherooCore

public enum CodexLoginMode: Sendable {
    case inProcessTTY
    case launchTerminal
}

public struct CodexLoginRunner: Sendable {
    private let mode: CodexLoginMode

    public init(mode: CodexLoginMode) {
        self.mode = mode
    }

    public func run(codexHomePath: String) throws {
        switch mode {
        case .inProcessTTY:
            try runInProcess(codexHomePath: codexHomePath)
        case .launchTerminal:
            try launchTerminal(codexHomePath: codexHomePath)
        }
    }

    private func runInProcess(codexHomePath: String) throws {
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
            throw SwitcherooError.providerLoginFailed(
                providerId: "codex",
                message: "exit \(process.terminationStatus)"
            )
        }
    }

    private func launchTerminal(codexHomePath: String) throws {
        let cmdBody = "export CODEX_HOME=\(shellQuote(codexHomePath)); codex login"
        let cmd = "zsh -lc \(shellQuote(cmdBody))"

        let appleScript = """
        on run argv
          set cmd to item 1 of argv
          tell application "Terminal"
            activate
            if (count of windows) is 0 then
              do script cmd
            else
              do script cmd in front window
            end if
          end tell
        end run
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript, cmd]

        try process.run()
    }

    private func shellQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'" + escaped + "'"
    }
}

