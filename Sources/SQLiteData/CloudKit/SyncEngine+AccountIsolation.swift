#if canImport(CloudKit)
  import CloudKit
  import Foundation
  import GRDB
  import StructuredQueries

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    /// The latest account gate failure. Observing this property lets the application present
    /// paused ownership/adoption state even when CloudKit detects a switch before app notifications.
    public var accountIsolationFailure: SyncAccountIsolationError? {
      observationRegistrar.access(self, keyPath: \.accountIsolationFailure)
      return accountFailure.value
    }

    func setAccountFailure(_ failure: SyncAccountIsolationError?) {
      observationRegistrar.withMutation(of: self, keyPath: \.accountIsolationFailure) {
        accountFailure.withValue { $0 = failure }
      }
    }

    public var accountAdoptionRequest: SyncAccountAdoption? {
      guard case .adoptionRequired = accountIsolationFailure else { return nil }
      return pendingAccountAdoption.value.map { SyncAccountAdoption(engine: accountAdoptionID, fingerprint: $0) }
    }

    /// Explicitly connects previously unowned local data to the account presented by the last
    /// adoption-required start. An already owned store can never be reassigned by this method.
    /// A changed account requires a fresh review; the earlier choice does not transfer to it.
    public func adoptLocalDataForCurrentAccount(_ request: SyncAccountAdoption) async throws {
      guard request.engine == accountAdoptionID else { throw SyncAccountIsolationError.adoptionRequired }
      try await stopAndDrain()
      try await isolatedStart(adopting: request.fingerprint)
    }

    func isolatedStart(adopting expected: String? = nil) async throws {
      guard SyncWorkContext.token?.tracker !== workTracker else { throw LifetimeError.reentrantDrain }
      await retirementTask.value?.value
      do {
        try await requestIsolatedStart(adopting: expected).value
        try Task.checkCancellation()
      } catch {
        stop()
        await retirementTask.value?.value
        throw error
      }
    }

    /// Register the complete account lookup/start request before scheduling it. A stop during
    /// an uncooperative account lookup must still drain its lease and reject its eventual write.
    func requestIsolatedStart(adopting expected: String? = nil) throws -> Task<Void, Error> {
      try startStopLock.withLock {
        guard !isDraining.value, !isResetting.value else { throw LifetimeError.draining }
        if let existing = isolatedStartTask.value { return existing }
        workTracker.activate()
        let lease = try workTracker.begin()
        let task = Task<Void, Error> {
          defer { lease.finish() }
          try await SyncWorkContext.$token.withValue(lease.token) {
            let context = diagnosticEmitter.map { _ in makeDiagnosticOperation(stage: .startupStarted) }
            try await SyncDiagnosticContext.$operation.withValue(context) {
              emitDiagnostic(.startupStarted, outcome: .started)
              do {
                try await authorizeAccount(adopting: expected)
                try lease.token.check()
                let preparation = try startStopLock.withLock {
                  try lease.token.check()
                  return try prepareStart()
                }
                await preparation.value
                try lease.token.check()
              } catch {
                if let failure = error as? SyncAccountIsolationError { setAccountFailure(failure) }
                diagnosticFailure(error)
                emitDiagnostic(.startupFinished, level: .error, outcome: .failed, finished: true)
                throw error
              }
            }
          }
        }
        isolatedStartTask.withValue { $0 = task }
        return task
      }
    }

    private func currentAccountFingerprint() async throws -> String {
      guard let isolation = accountIsolation else { throw SyncAccountIsolationError.adoptionRequired }
      let status = try await container.accountStatus()
      guard status == .available else { throw SyncAccountIsolationError.accountUnavailable(status) }
      let id = try await container.userRecordID()
      try SyncWorkContext.token?.check()
      return try SyncAccountBinding.fingerprint(id, container: container.containerIdentifier ?? "",
                                                environment: isolation.environment.rawValue)
    }

    private func authorizeAccount(adopting expected: String?) async throws {
      guard let isolation = accountIsolation else { return }
      let fingerprint = try await currentAccountFingerprint()
      if let expected, expected != fingerprint { throw SyncAccountIsolationError.accountChangedDuringAdoption }
      do {
        try await userDatabase.write { db in
          let containerID = container.containerIdentifier ?? ""
          if try SyncAccountBinding.validate(db, container: containerID,
            environment: isolation.environment.rawValue, account: fingerprint) { return }
          if expected == nil, try hasExistingAccountData(db) { throw SyncAccountIsolationError.adoptionRequired }
          try SyncAccountBinding.bind(db, container: containerID, environment: isolation.environment.rawValue,
                                      account: fingerprint)
        }
        pendingAccountAdoption.withValue { $0 = nil }
        authorizedAccount.withValue { $0 = fingerprint }
        setAccountFailure(nil)
      } catch SyncAccountIsolationError.adoptionRequired {
        pendingAccountAdoption.withValue { $0 = fingerprint }
        throw SyncAccountIsolationError.adoptionRequired
      }
    }

    private func hasExistingAccountData(_ db: Database) throws -> Bool {
      for table in tables {
        func hasRows<T>(_: some SynchronizableTable<T>) throws -> Bool {
          try T.unscoped.count().fetchOne(db) != 0
        }
        if try hasRows(table) { return true }
      }
      if try SyncMetadata.count().fetchOne(db) != 0 { return true }
      for table in [OutgoingIntent.table, IncomingJournal.table] {
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table))") == true { return true }
      }
      return false
    }

    func requireAccountOwnership() async throws {
      do { try await verifyAccountOwnership() }
      catch is CancellationError { throw CancellationError() }
      catch {
        if let failure = error as? SyncAccountIsolationError { setAccountFailure(failure) }
        stop()
        throw error
      }
    }

    /// Called at transfer and callback boundaries, before admitting new cloud data or exposing
    /// a record batch. The generation check also runs inside every owned database transaction.
    func verifyAccountOwnership() async throws {
      guard let isolation = accountIsolation else { return }
      let fingerprint = try await currentAccountFingerprint()
      guard authorizedAccount.value == fingerprint else { throw SyncAccountIsolationError.differentAccount }
      let valid = try await userDatabase.read { db in
        try SyncAccountBinding.validate(db, container: container.containerIdentifier ?? "",
          environment: isolation.environment.rawValue, account: fingerprint)
      }
      guard valid else { throw SyncAccountIsolationError.adoptionRequired }
    }
  }
#endif
