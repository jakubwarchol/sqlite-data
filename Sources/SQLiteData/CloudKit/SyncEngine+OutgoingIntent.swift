#if canImport(CloudKit)
  import CloudKit
  import GRDB
  import StructuredQueries

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    /// CKSyncEngine serialization is a scheduling cache. The user-file journal owns intent.
    func enqueueOutgoingIntents() async throws {
      let intents = try await sendableOutgoingIntents()
      syncEngines.withValue { engines in
        for (engine, isPrivate) in [(engines.private, true), (engines.shared, false)] {
          engine?.state.add(pendingRecordZoneChanges: intents.filter {
            ($0.recordID.zoneID.ownerName == CKCurrentUserDefaultName) == isPrivate
          }.map(\.change))
        }
      }
    }

    func sendableOutgoingIntents() async throws -> [OutgoingIntent] {
      try await userDatabase.read { db in
        try OutgoingIntent.fetch(db).filter { intent in
          guard !intent.blocked else { return false }
          if intent.isDelete { return true }
          guard let name = intent.recordID.tableName, let table = tablesByName[name],
            let primaryKey = intent.recordID.recordPrimaryKey else { return false }
          func exists<T>(_: some SynchronizableTable<T>) throws -> Bool {
            try T.unscoped.find(#sql("\(bind: primaryKey)")).fetchOne(db) != nil
          }
          return try exists(table)
        }
      }
    }

    func prepareOutgoingIntents(in db: Database) throws {
      try OutgoingIntent.create(in: db, containerIdentifier: container.containerIdentifier)
      try OutgoingIntent.restoreMetadata(in: db)
      for change in try PendingRecordZoneChange.select(\.pendingRecordZoneChange).fetchAll(db) {
        try OutgoingIntent.adopt(change, db: db)
      }
      // Clearing the legacy queue is safe only in the transaction which adopts its contents.
      try PendingRecordZoneChange.delete().execute(db)
      try OutgoingIntent.installTriggers(in: db)
    }

    func adoptSerializedOutgoingIntents() throws {
      let changes = syncEngines.withValue {
        ($0.private?.state.pendingRecordZoneChanges ?? []) + ($0.shared?.state.pendingRecordZoneChanges ?? [])
      }
      try userDatabase.write { db in
        for change in changes { try OutgoingIntent.adopt(change, db: db) }
      }
    }

    /// Called before forming a batch. Rolled-back callback hints and stale opposite operations
    /// cannot override the committed desired operation in the journal.
    func durablePendingChanges(
      options: CKSyncEngine.SendChangesOptions, syncEngine: any SyncEngineProtocol
    ) async throws -> [CKSyncEngine.PendingRecordZoneChange] {
      // Live CKSyncEngine can call its delegate immediately after construction.
      // Do not discard its restored hints before they have been adopted transactionally.
      guard outgoingReady.value else { return [] }
      let intents = try await sendableOutgoingIntents()
        .filter { ($0.recordID.zoneID.ownerName == CKCurrentUserDefaultName)
          == (syncEngine.database.databaseScope == .private) }
      let changes = intents.map(\.change)
      let stale = syncEngine.state.pendingRecordZoneChanges.filter { !changes.contains($0) }
      syncEngine.state.remove(pendingRecordZoneChanges: stale)
      syncEngine.state.add(pendingRecordZoneChanges: changes)
      return changes.filter(options.scope.contains)
    }

    func acknowledgeOutgoing(
      savedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID],
      failedRecordSaves: [(record: CKRecord, error: CKError)], failedRecordDeletes: [CKRecord.ID: CKError],
      syncEngine: any SyncEngineProtocol
    ) async {
      for record in savedRecords {
        let receipt = outgoingAttempts.completed(record.recordID, isDelete: false, engine: syncEngine)
        await withDiagnosticErrorReporting(.sqliteDataCloudKitFailure) {
          try await userDatabase.write { db in
            try refreshLastKnownServerRecord(record, db: db)
            try receipt?.acknowledge(db)
          }
        }
      }
      // Deleting an already absent record is the idempotent success case after a lost receipt.
      for id in deletedRecordIDs + failedRecordDeletes.compactMap({ $0.value.code == .unknownItem ? $0.key : nil }) {
        let receipt = outgoingAttempts.completed(id, isDelete: true, engine: syncEngine)
        await withDiagnosticErrorReporting(.sqliteDataCloudKitFailure) {
          try await userDatabase.write { db in try receipt?.acknowledge(db) }
        }
      }
      for failure in failedRecordSaves {
        let receipt = outgoingAttempts.completed(failure.record.recordID, isDelete: false, engine: syncEngine)
        if failure.error.code == .permissionFailure, let receipt {
          await withDiagnosticErrorReporting(.sqliteDataCloudKitFailure) {
            try await userDatabase.write { db in
              try db.execute(sql: """
                UPDATE main.\(OutgoingIntent.table) SET blocked = 1
                WHERE recordName = ? AND zoneName = ? AND ownerName = ? AND revision = ?
                """, arguments: [receipt.intent.recordID.recordName, receipt.intent.recordID.zoneID.zoneName,
                                  receipt.intent.recordID.zoneID.ownerName, receipt.intent.revision])
            }
          }
        }
      }
      for (id, error) in failedRecordDeletes where error.code != .unknownItem {
        _ = outgoingAttempts.completed(id, isDelete: true, engine: syncEngine)
      }
    }

    func refreshLastKnownServerRecord(_ record: CKRecord, db: Database) throws {
      let metadata = try SyncMetadata.find(record.recordID).fetchOne(db)
      if let lastKnownDate = metadata?.lastKnownServerRecord?.modificationDate {
        guard let recordDate = record.modificationDate, lastKnownDate < recordDate else { return }
      }
      try SyncMetadata.find(record.recordID).update { $0.setLastKnownServerRecord(record) }.execute(db)
    }
  }
#endif
