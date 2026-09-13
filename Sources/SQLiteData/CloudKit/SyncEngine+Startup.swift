#if canImport(CloudKit)
  public import CloudKit
  import Foundation

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    /// Preparation state, independent of transport allocation (`isRunning`).
    public enum StartupState: Sendable {
      case stopped
      case preparing
      /// Account authorization and local schema/outgoing preparation completed.
      /// This does not establish uploaded records or applied incoming changes.
      case ready
      /// The original error is preserved, including CloudKit retry-after information.
      case failed(any Error)
    }

    public enum StartupError: LocalizedError {
      case accountUnavailable(CKAccountStatus)

      public var errorDescription: String? {
        "iCloud account access is unavailable. Check the account and try again."
      }
    }

    /// Observable even when initialization requested an automatic start.
    /// A failed attempt retires its transport; `start()` can retry after drainage.
    public var startupState: StartupState {
      observationRegistrar.access(self, keyPath: \.startupState)
      return startup.value
    }

    public var isPrepared: Bool {
      if case .ready = startupState { return true }
      return false
    }

    func setStartupState(_ state: StartupState) {
      observationRegistrar.withMutation(of: self, keyPath: \.startupState) {
        startup.withValue { $0 = state }
      }
    }

    /// Waits for account authorization and local preparation, throwing synchronous
    /// and asynchronous startup errors. Concurrent callers join the same attempt.
    /// A cancelled waiter does not cancel startup for other callers; use `stop()`
    /// or `stopAndDrain()` to retire it. Call outside engine delegate callbacks.
    /// Success is preparation, not proof of delivery or incoming application.
    public func start() async throws {
      try await awaitStart()
    }

    func awaitStart(adopting expected: String? = nil) async throws {
      guard SyncWorkContext.token?.tracker !== workTracker else { throw LifetimeError.reentrantDrain }
      try Task.checkCancellation()
      await retirementTask.value?.value
      try Task.checkCancellation()
      let task = try requestStart(adopting: expected)
      do {
        let token = try await task.value
        try Task.checkCancellation()
        try token.check()
      } catch {
        // The owned attempt retires failures. A late waiter must never stop a
        // newer attempt; it only observes the completed retirement.
        await retirementTask.value?.value
        throw error
      }
    }

    /// Own the whole attempt before scheduling any asynchronous account lookup.
    /// The same path serves manual starts, automatic starts and account adoption.
    func requestStart(adopting expected: String? = nil) throws -> Task<SyncWorkTracker.Token, any Error> {
      try startStopLock.withLock {
        guard !isDraining.value, !isResetting.value else { throw LifetimeError.draining }
        if let existing = startupTask.value { return existing }
        workTracker.activate()
        let lease = try workTracker.begin()
        setStartupState(.preparing)
        let task = Task<SyncWorkTracker.Token, any Error> {
          defer { lease.finish() }
          return try await SyncWorkContext.$token.withValue(lease.token) {
            let context = diagnosticEmitter.map { _ in makeDiagnosticOperation(stage: .startupStarted) }
            return try await SyncDiagnosticContext.$operation.withValue(context) {
              emitDiagnostic(.startupStarted, outcome: .started)
              do {
                try await authorizeAccount(adopting: expected)
                let preparation = try startStopLock.withLock {
                  try lease.token.check()
                  return try prepareStart()
                }
                try await preparation.value
                try await verifyAccountOwnership()
                try startStopLock.withLock {
                  try lease.token.check()
                  setStartupState(.ready)
                  emitDiagnostic(.startupFinished, outcome: .prepared, finished: true)
                }
                return lease.token
              } catch {
                startStopLock.withLock {
                  let current = (try? lease.token.check()) != nil
                  let cancelled = !current || error is CancellationError
                  diagnosticFailure(cancelled ? CancellationError() : error)
                  emitDiagnostic(.startupFinished, level: cancelled ? .info : .error,
                    outcome: cancelled ? .cancelled : .failed, finished: true)
                  if current {
                    if let failure = error as? SyncAccountIsolationError { setAccountFailure(failure) }
                    stop()
                    if !cancelled { setStartupState(.failed(error)) }
                  }
                }
                throw error
              }
            }
          }
        }
        startupTask.withValue { $0 = task }
        return task
      }
    }
  }
#endif
