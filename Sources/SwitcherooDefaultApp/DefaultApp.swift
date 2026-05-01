import Foundation
import SwitcherooCodexProvider
import SwitcherooCore
import SwitcherooMacAdapters
import SwitcherooPresentation

public enum DefaultLoginStyle: Sendable {
    case cliInteractive
    case openTerminal
}

public struct SwitcherooDefaultAppFactory {
    public init() {}

    public func make(loginStyle: DefaultLoginStyle) throws -> SwitcherooApp {
        let configStore = MacConfigStore()
        let secureStore = MacKeychainSecureStore()
        let fileIO = FoundationFileIO()
        let paths = MacPaths()

        let runnerMode: CodexLoginMode = (loginStyle == .cliInteractive) ? .inProcessTTY : .launchTerminal
        let loginRunner = CodexLoginRunner(mode: runnerMode)

        let codexProvider = CodexProvider { codexHomePath in
            try loginRunner.run(codexHomePath: codexHomePath)
        }

        let engine = try SwitcherooEngine(
            configStore: configStore,
            secureStore: secureStore,
            fileIO: fileIO,
            paths: paths,
            providers: [codexProvider]
        )

        let providerDescriptors = [
            ProviderDescriptor(id: codexProvider.id, displayName: codexProvider.displayName),
        ]

        return SwitcherooApp(engine: engine, fileIO: fileIO, providers: providerDescriptors)
    }
}

