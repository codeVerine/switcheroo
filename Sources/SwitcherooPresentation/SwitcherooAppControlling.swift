import Foundation
import SwitcherooCore

public protocol SwitcherooAppControlling: AnyObject {
    /// Fired when asynchronous usage state changes so live views (the menu bar
    /// dropdown) can re-read `snapshot()` without waiting for a synchronous
    /// refresh. May be called from any executor.
    var onUsageUpdated: (@Sendable () -> Void)? { get set }

    func refresh()
    func snapshot() -> SwitcherooAppState

    func startAddAccount(name: String)
    func startAddAccount()

    @discardableResult func importCurrentAccount(name: String) -> SwitcherooAccountWriteResult?
    @discardableResult func importCurrentAccount(setActiveIfFirst: Bool) -> SwitcherooAccountWriteResult?

    @discardableResult func finalizePendingIfReady(setActive: Bool) -> SwitcherooAccountWriteResult?
    @discardableResult func finalizePendingIfReady(setActiveIfFirst: Bool) -> SwitcherooAccountWriteResult?

    func switchToAccount(idOrName: String)
    func deleteAccount(idOrName: String)
    @discardableResult func syncActiveSnapshot() -> SwitcherooActiveSnapshotSyncResult?
    func autoSyncDecision(now: Date) -> SwitcherooAutoSyncDecision
    func renameAccount(accountId: String, newName: String)
}

extension SwitcherooApp: SwitcherooAppControlling {}
