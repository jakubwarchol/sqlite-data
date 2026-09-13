#if canImport(CloudKit)
  import CloudKit
  import Foundation
  import GRDB
  import IssueReporting

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    func captureIncoming(
      modifications: [CKRecord],
      deletions: [(recordID: CKRecord.ID, recordType: CKRecord.RecordType)],
      engine: any SyncEngineProtocol
    ) async {
      do {
        for deletion in deletions {
          try await userDatabase.write { db in
            try IncomingJournal.capture(id: deletion.recordID, recordType: deletion.recordType, kind: .deletion, db: db)
          }
        }
        // Stage one record at a time to bound the extra asset-buffer memory to one record.
        for record in modifications {
          let payload = try JSONEncoder().encode(IncomingPayload(record, dataManager: dataManager.wrappedValue))
          try await userDatabase.write { db in
            try IncomingJournal.capture(id: record.recordID, recordType: record.recordType,
                                        kind: .record, payload: payload, db: db)
          }
        }
      } catch is CancellationError { return }
      catch {
        SyncDiagnosticContext.operation?.increment("captureFailed")
        _ = incomingCheckpointBlocked.withValue { $0.insert(engine.database.databaseScope) }
        reportIncomingFailure(error)
      }
    }

    func captureIncomingZones(
      deletions: [(zoneID: CKRecordZone.ID, reason: CKDatabase.DatabaseChange.Deletion.Reason)],
      engine: any SyncEngineProtocol
    ) async {
      do {
        for (id, reason) in deletions {
          let kind: IncomingJournal.Kind
          switch reason {
          case .deleted: kind = .zoneDeleted
          case .purged: kind = .zonePurged
          case .encryptedDataReset: kind = .encryptedDataReset
          @unknown default: throw IncomingRecoveryError.unsupportedZoneDeletion
          }
          try await userDatabase.write { db in
            try IncomingJournal.capture(id: CKRecord.ID(recordName: "__sqlitedata_zone_event__", zoneID: id), recordType: "",
                                        kind: kind, db: db)
          }
        }
      } catch is CancellationError { return }
      catch {
        SyncDiagnosticContext.operation?.increment("captureFailed")
        _ = incomingCheckpointBlocked.withValue { $0.insert(engine.database.databaseScope) }
        reportIncomingFailure(error)
      }
    }

    func commitIncomingCheckpoint(
      _ serialization: CKSyncEngine.State.Serialization, engine: any SyncEngineProtocol
    ) async {
      guard !incomingCheckpointBlocked.value.contains(engine.database.databaseScope) else { return }
      do {
        try await userDatabase.write { db in
          try IncomingJournal.saveCheckpoint(serialization, scope: engine.database.databaseScope, db: db)
        }
        SyncDiagnosticContext.operation?.increment("checkpointCommitted")
        await replayIncomingChanges()
      } catch is CancellationError { }
      catch {
        _ = incomingCheckpointBlocked.withValue { $0.insert(engine.database.databaseScope) }
        reportIncomingFailure(error)
      }
    }

    func restoredMockState(in database: any DatabaseReader, scope: CKDatabase.Scope) throws -> MockSyncEngineState {
      let state = MockSyncEngineState()
      if let json = try database.read({ db in
        try String.fetchOne(db, sql: "SELECT data FROM main.\(IncomingJournal.checkpoints) WHERE scope = ?",
                            arguments: [scope.rawValue])
      }) {
        let fields = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Int]
        guard let tag = fields?["mockChangeTag"] else { throw IncomingRecoveryError.invalidPayload }
        state.changeTag.withValue { $0 = tag }
      }
      return state
    }

    // The package-owned mock has no CKSyncEngine.Serialization initializer. Its private
    // checkpoint seam uses the same SQLite promotion transaction as the live delegate event.
    func commitMockIncomingCheckpoint(_ engine: MockSyncEngine) async {
      guard engine._automaticallyCheckpoint.value,
        !incomingCheckpointBlocked.value.contains(engine.database.databaseScope) else { return }
      do {
        let json = "{\"mockChangeTag\":\(engine.state.changeTag.value)}"
        try await userDatabase.write { db in
          try IncomingJournal.commitCheckpoint(json, scope: engine.database.databaseScope, db: db)
        }
        SyncDiagnosticContext.operation?.increment("checkpointCommitted")
        await replayIncomingChanges()
      } catch is CancellationError { }
      catch {
        _ = incomingCheckpointBlocked.withValue { $0.insert(engine.database.databaseScope) }
        reportIncomingFailure(error)
      }
    }

    func reportIncomingFailure(_ error: any Error) {
      fetchCompletion.withValue { $0.localFailure = $0.localFailure ?? error }
      withErrorReporting(.sqliteDataCloudKitFailure) {
        diagnosticFailure(error)
        throw error
      }
    }

    /// Replays retained incoming changes and performs a checked fetch. A failed capture
    /// requires replacing this generation with one restored from the last durable checkpoint.
    /// Call from the resource owner, never from an engine delegate callback.
    public func recoverIncomingChanges() async throws {
      guard SyncWorkContext.token?.tracker !== workTracker else { throw LifetimeError.reentrantDrain }
      if !incomingCheckpointBlocked.value.isEmpty {
        try await stopAndDrain()
        incomingCheckpointBlocked.withValue { $0.removeAll() }
        try await start()
      }
      try await fetchChangesAndApply()
    }
  }
#endif
