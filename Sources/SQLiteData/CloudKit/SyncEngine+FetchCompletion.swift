#if canImport(CloudKit)
  public import CloudKit
  import ConcurrencyExtras
  import IssueReporting

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    /// A fetch could not establish that remote changes were applied locally.
    public enum FetchCompletionError: Error {
      case notRunning
      case alreadyFetching
      case accountUnavailable(CKAccountStatus)
      case invalidated
      case incomplete
      case localApplicationFailed(any Error)
      case unappliedRecords(Int)
      case invalidRecord(CKRecord.ID)
    }

    /// Fetches both databases and waits for CloudKit's delegate processing and local writes.
    ///
    /// Unlike `fetchChanges`, a stopped engine or a swallowed local apply error cannot report
    /// success. Missing foreign-key dependencies also prevent success. Concurrent calls to this
    /// method throw `alreadyFetching`; ordinary background synchronization remains enabled.
    ///
    /// Local apply failures are retained for this engine's lifetime: a later empty fetch cannot
    /// prove the failed changes were replayed. This is a completion check, not a repair mechanism
    /// or a durable receipt across process termination. It cannot see another device's unsent
    /// edits or prevent changes arriving after it returns. Never call from a sync delegate event.
    public func fetchChangesAndApply() async throws {
      try fetchCompletion.withValue {
        guard !$0.isChecking else { throw FetchCompletionError.alreadyFetching }
        $0.isChecking = true
      }
      defer { fetchCompletion.withValue { $0.isChecking = false } }
      await startTask.withValue(\.self)?.value
      try Task.checkCancellation()
      let (privateEngine, sharedEngine) = syncEngines.withValue { ($0.private, $0.shared) }
      guard let privateEngine, let sharedEngine else { throw FetchCompletionError.notRunning }
      let before = fetchCompletion.value
      if let error = before.localFailure { throw FetchCompletionError.localApplicationFailed(error) }
      let status = try await container.accountStatus()
      guard status == .available else { throw FetchCompletionError.accountUnavailable(status) }

      do {
        try await fetchBothDatabases(privateEngine, sharedEngine)
      } catch {
        // The helper's structured child tasks have both finished, including cancellation
        // cleanup. A transport error must not conceal an apply failure in the other scope.
        if let failure = fetchCompletion.value.localFailure {
          throw FetchCompletionError.localApplicationFailed(failure)
        }
        throw error
      }
      try Task.checkCancellation()
      let pendingCount = try await metadatabase.read { db in
        try UnsyncedRecordID.count().fetchOne(db) ?? 0
      }
      try Task.checkCancellation()
      let sameEngines = syncEngines.withValue {
        $0.private === privateEngine && $0.shared === sharedEngine
      }
      let after = fetchCompletion.value
      guard sameEngines, before.accountGeneration == after.accountGeneration
      else { throw FetchCompletionError.invalidated }
      if let error = after.localFailure { throw FetchCompletionError.localApplicationFailed(error) }
      if before.zoneFailureGeneration != after.zoneFailureGeneration, let error = after.zoneFailure {
        throw error
      }
      for engine in [privateEngine, sharedEngine] {
        let id = ObjectIdentifier(engine)
        guard after.completed[id, default: 0] > before.completed[id, default: 0]
        else { throw FetchCompletionError.incomplete }
      }
      guard pendingCount == 0 else { throw FetchCompletionError.unappliedRecords(pendingCount) }
    }

    private func fetchBothDatabases(
      _ privateEngine: any SyncEngineProtocol, _ sharedEngine: any SyncEngineProtocol
    ) async throws {
      async let privateFetch: Void = privateEngine.fetchChanges(.init())
      async let sharedFetch: Void = sharedEngine.fetchChanges(.init())
      _ = try await (privateFetch, sharedFetch)
    }

    func withFetchErrorReporting<R>(
      fileID: StaticString = #fileID, filePath: StaticString = #filePath,
      line: UInt = #line, column: UInt = #column,
      _ operation: () throws -> R
    ) -> R? {
      withErrorReporting(
        .sqliteDataCloudKitFailure, fileID: fileID, filePath: filePath, line: line, column: column
      ) {
        do { return try operation() }
        catch {
          fetchCompletion.withValue { $0.localFailure = $0.localFailure ?? error }
          throw error
        }
      }
    }

    func withFetchErrorReporting<R>(
      fileID: StaticString = #fileID, filePath: StaticString = #filePath,
      line: UInt = #line, column: UInt = #column,
      _ operation: () async throws -> sending R
    ) async -> R? {
      await withErrorReporting(
        .sqliteDataCloudKitFailure, fileID: fileID, filePath: filePath, line: line, column: column
      ) {
        do { return try await operation() }
        catch {
          fetchCompletion.withValue { $0.localFailure = $0.localFailure ?? error }
          throw error
        }
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  struct FetchCompletionState: Sendable {
    var isChecking = false
    var localFailure: (any Error)?
    var accountGeneration = 0
    var completed: [ObjectIdentifier: Int] = [:]
    var zoneFailureGeneration = 0
    var zoneFailure: CKError?
  }
#endif
