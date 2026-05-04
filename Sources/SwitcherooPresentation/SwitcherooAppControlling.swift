import Foundation
import SwitcherooCore

public protocol SwitcherooAppControlling: AnyObject {
    func refresh()
    func snapshot() -> SwitcherooAppState

    func startAddAccount(name: String)
    func startAddAccount()

    func importCurrentAccount(name: String)
    @discardableResult func importCurrentAccount(setActiveIfFirst: Bool) -> SwitcherooAccount?

    func finalizePendingIfReady(setActive: Bool)
    @discardableResult func finalizePendingIfReady(setActiveIfFirst: Bool) -> SwitcherooAccount?

    func switchToAccount(idOrName: String)
    func deleteAccount(idOrName: String)
    func syncActiveSnapshot()
    func renameAccount(accountId: String, newName: String)
}

extension SwitcherooApp: SwitcherooAppControlling {}
