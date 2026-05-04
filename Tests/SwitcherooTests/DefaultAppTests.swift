import XCTest
@testable import SwitcherooDefaultApp
import SwitcherooPresentation

final class SwitcherooDefaultAppFactoryTests: XCTestCase {
    func testMakeCreatesAppForBothLoginStyles() throws {
        let factory = SwitcherooDefaultAppFactory()

        let cliApp = try factory.make(loginStyle: .cliInteractive)
        let terminalApp = try factory.make(loginStyle: .openTerminal)

        XCTAssertEqual(cliApp.snapshot().providers.map(\.id), ["codex"])
        XCTAssertEqual(cliApp.snapshot().providers.map(\.displayName), ["Codex"])
        XCTAssertNil(cliApp.snapshot().selectedProviderId)

        XCTAssertEqual(terminalApp.snapshot().providers.map(\.id), ["codex"])
        XCTAssertEqual(terminalApp.snapshot().providers.map(\.displayName), ["Codex"])
        XCTAssertNil(terminalApp.snapshot().selectedProviderId)
    }
}
