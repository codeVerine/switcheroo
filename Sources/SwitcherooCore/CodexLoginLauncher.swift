import Foundation

public struct CodexLoginLauncher: Sendable {
    public init() {}

    public func launchTerminalLogin(codexHomePath: String) throws {
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
        // POSIX-safe single-quote escaping.
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'" + escaped + "'"
    }
}
