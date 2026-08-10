import Foundation
import SwitcherooCodexProvider
import SwitcherooCore
import SwitcherooMacAdapters
import SwitcherooPiAdapter
import SwitcherooPresentation

public enum DefaultLoginStyle: Sendable {
    case cliInteractive
    case openTerminal
}

public struct SwitcherooDefaultAppFactory {
    public init() {}

    /// Usage display is a menu-bar-only experience; the CLI opts out so its
    /// commands stay offline-safe.
    public func make(loginStyle: DefaultLoginStyle, usageFetchingEnabled: Bool = true) throws -> SwitcherooApp {
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
            providers: [codexProvider],
            authTargetAdapters: [
                CodexAuthTargetAdapter(defaultAuthFilePath: codexProvider.defaultActiveAuthFilePath),
                PiAuthTargetAdapter(),
            ]
        )

        let providerDescriptors = [
            ProviderDescriptor(id: codexProvider.id, displayName: codexProvider.displayName),
        ]

        let usageClient = CodexAPIClient(
            baseURL: CodexAPIClient.defaultChatGptBaseURL,
            pathStyle: .chatgpt,
            transport: URLSessionCodexTransport()
        )
        let usageFetcher: (any AccountUsageFetching)? = usageFetchingEnabled
            ? CodexUsageFetcher(client: usageClient)
            : nil

        return SwitcherooApp(
            engine: engine,
            fileIO: fileIO,
            providers: providerDescriptors,
            usageFetcher: usageFetcher
        )
    }
}

