#if canImport(CloudKit)
  public import CloudKit

  /// Observes account changes after the engine has fenced unsafe work.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public protocol SyncEngineDelegate: AnyObject, Sendable {
    /// Sign-out and account switches stop synchronization and retain local data, including
    /// unsent edits and incoming recovery payloads. The default implementation does nothing.
    ///
    /// Update application presentation here, then return. The resource owner can subsequently
    /// await `stopAndDrain()` before closing or replacing the database. Awaiting retirement or
    /// calling `deleteLocalData()` inside this callback throws `LifetimeError.reentrantDrain`.
    ///
    /// Enable `SyncAccountIsolation` to persist account ownership across launches and prevent
    /// restarting an account's store under another account. Explicit deletion never reassigns it.
    func syncEngine(
      _ syncEngine: SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngineDelegate {
    public func syncEngine(
      _ syncEngine: SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async { }
  }
#endif
