#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Foundation
  import GRDB
  import StructuredQueries

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    func replayIncomingChanges() async {
      await incomingReplayGate.acquire()
      do { try await replayIncomingPasses() }
      catch is CancellationError { }
      catch { reportIncomingFailure(error) }
      await incomingReplayGate.release()
    }

    private func replayIncomingPasses() async throws {
      var failed: Set<String> = []
      while true {
        try SyncWorkContext.token?.check()
        let entries = try await userDatabase.read { try IncomingJournal.fetch($0) }
        var progress = false
        for entry in entries.sorted(by: incomingOrder) where !failed.contains(entry.revision) {
          do {
            let applied = try await replayIncomingEntry(entry)
            progress = applied || progress
            if applied, entry.id.zoneID == defaultZone.zoneID,
              entry.kind == .zoneDeleted || entry.kind == .zonePurged {
              syncEngines.private?.state.add(pendingDatabaseChanges: [.saveZone(defaultZone)])
            }
          }
          catch is CancellationError { throw CancellationError() }
          catch {
            failed.insert(entry.revision)
          }
        }
        if !progress { break }
        try await enqueueOutgoingIntents()
      }
      if try await incomingPendingCount() == 0, incomingCheckpointBlocked.value.isEmpty {
        fetchCompletion.withValue { $0.localFailure = $0.untrackedLocalFailure }
      }
    }

    func incomingPendingCount() async throws -> Int {
      try await userDatabase.read { db in
        try Row.fetchAll(db, sql: "SELECT kind, recordType FROM main.\(IncomingJournal.table)").filter { row in
          let type: String = row["recordType"]
          return row["kind"] as Int != IncomingJournal.Kind.record.rawValue
            || tablesByName[type] != nil || type == CKRecord.SystemType.share
        }.count
      }
    }

    private func incomingOrder(_ lhs: IncomingJournal, _ rhs: IncomingJournal) -> Bool {
      func rank(_ entry: IncomingJournal) -> Int {
        switch entry.kind {
        case .zoneDeleted, .zonePurged, .encryptedDataReset: return -10_000
        case .deletion: return -(tablesByOrder[entry.recordType, default: -1] + 1)
        case .record: return 10_000 + tablesByOrder[entry.recordType, default: 10_000]
        }
      }
      let (left, right) = (rank(lhs), rank(rhs))
      return left == right ? lhs.sequence < rhs.sequence : left < right
    }

    private func replayIncomingEntry(_ entry: IncomingJournal) async throws -> Bool {
      let scope: SyncDiagnostic.Scope = entry.id.zoneID.ownerName == CKCurrentUserDefaultName ? .private : .shared
      let parent = SyncDiagnosticContext.operation
      // Either scope can drive the shared durable replay queue. Do not attach a
      // private application to a shared transfer (or to unscoped startup).
      let context = diagnosticEmitter.map { _ in makeDiagnosticOperation(
        scope: scope, stage: .applicationFinished, parent: parent?.scope == scope ? parent : nil
      ) }
      return try await SyncDiagnosticContext.$operation.withValue(context) {
        do {
          let applied = try await applyIncoming(entry)
          let counts = context?.counts.value ?? [:]
          let deferred = counts["deferred", default: 0] > 0
          emitDiagnostic(.applicationFinished, level: deferred ? .warning : .info,
            outcome: applied ? .applied : deferred ? .deferred : .partial,
            counts: counts, recordTypes: diagnosticRecordTypes([entry.recordType]), finished: true)
          return applied
        } catch is CancellationError { throw CancellationError() }
        catch {
          reportIncomingFailure(error)
          emitDiagnostic(.applicationFinished, level: .warning, outcome: .failed,
            counts: context?.counts.value ?? [:], recordTypes: diagnosticRecordTypes([entry.recordType]), finished: true)
          throw error
        }
      }
    }

    private func applyIncoming(_ entry: IncomingJournal) async throws -> Bool {
      let record = try entry.payload.map {
        try JSONDecoder().decode(IncomingPayload.self, from: $0).materialize(dataManager: dataManager.wrappedValue)
      }
      var share: CKShare?
      var root: CKRecord.ID?
      var unsharedRecord: CKRecord?
      if let record {
        if let value = record as? CKShare { share = value }
        else if let reference = record.share {
          share = try await container.database(for: reference.recordID).record(for: reference.recordID) as? CKShare
          guard share != nil else { throw IncomingRecoveryError.invalidPayload }
        }
        if let share {
          root = try await container.shareMetadata(for: share, shouldFetchRootRecord: false).hierarchicalRootRecordID
          guard root != nil else { throw IncomingRecoveryError.invalidPayload }
        }
      } else if entry.kind == .deletion, entry.recordType == CKRecord.SystemType.share {
        root = try await metadatabase.read { db in
          try SyncMetadata.where(\.isShared).fetchAll(db).first { $0.share?.recordID == entry.id }
            .map { CKRecord.ID(recordName: $0.recordName, zoneID: .init(zoneName: $0.zoneName, ownerName: $0.ownerName)) }
        }
        if let root { unsharedRecord = try await container.privateCloudDatabase.record(for: root) }
      }
      if share != nil || unsharedRecord != nil { try await requireAccountOwnership() }
      let resolvedShare = share, rootID = root, unshared = unsharedRecord
      let failure = LockIsolated<(any Error)?>(nil)
      return try await IncomingApplyContext.$failure.withValue(failure) {
        try await userDatabase.write { db in
          guard try entry.isCurrent(db) else { return false }
          switch entry.kind {
          case .zoneDeleted, .zonePurged, .encryptedDataReset:
            try applyIncomingZone(entry, db: db)
          case .deletion:
            if entry.recordType == CKRecord.SystemType.share {
              if let rootID {
                try SyncMetadata.find(rootID).update {
                  $0.share = #bind(nil)
                  if let unshared { $0.setLastKnownServerRecord(unshared) }
                }.execute(db)
              }
            } else {
              try applyIncomingDeletion(entry, db: db)
            }
          case .record:
            guard let record else { throw IncomingRecoveryError.invalidPayload }
            if !(record is CKShare) { upsertFromServerRecord(record, db: db) }
            if let resolvedShare, let rootID {
              try SyncMetadata.find(rootID).update { $0.share = #bind(resolvedShare) }.execute(db)
            }
          }
          if let error = failure.value { throw error }
          if entry.kind == .record, entry.recordType != CKRecord.SystemType.share {
            // Keep unsupported entity payloads in the user file for a later schema version.
            guard tablesByName[entry.recordType] != nil else { return false }
            if try UnsyncedRecordID.find(entry.id).fetchOne(db) != nil { return false }
          }
          try entry.acknowledge(db)
          return true
        }
      }
    }

    private func applyIncomingDeletion(_ entry: IncomingJournal, db: Database) throws {
      if let table = tablesByName[entry.recordType] {
        func open<T>(_: some SynchronizableTable<T>) throws {
          try T.unscoped.where {
            #sql("\($0.primaryKey)").in(SyncMetadata.find(entry.id).select(\.recordPrimaryKey))
          }.delete().execute(db)
        }
        try open(table)
      } else {
        try SyncMetadata.find(entry.id).delete().execute(db)
      }
      try UnsyncedRecordID.find(entry.id).delete().execute(db)
    }

    private func applyIncomingZone(_ entry: IncomingJournal, db: Database) throws {
      let id = entry.id.zoneID
      if entry.kind == .encryptedDataReset {
        for metadata in try SyncMetadata.where({ $0.zoneName.eq(id.zoneName) && $0.ownerName.eq(id.ownerName) }).fetchAll(db) {
          let recordID = CKRecord.ID(recordName: metadata.recordName, zoneID: id)
          if metadata.hasLastKnownServerRecord {
            try OutgoingIntent.adopt(.saveRecord(recordID), db: db)
          }
        }
      } else {
        for table in tables.reversed() {
          func open<T>(_: some SynchronizableTable<T>) throws {
            try T.unscoped.where {
              #sql("\($0.primaryKey)").in(SyncMetadata.where {
                $0.recordType.eq(T.tableName) && $0.zoneName.eq(id.zoneName) && $0.ownerName.eq(id.ownerName)
              }.select(\.recordPrimaryKey))
            }.delete().execute(db)
          }
          try open(table)
        }
      }
    }

    /// Adopt the pre-journal deferred queue and reference-violation recovery results.
    /// A missing server record retires only the deferred lookup, never an application row.
    func recoverLegacyIncomingRecords(engine: any SyncEngineProtocol) async {
      do {
        let journalIDs = try await userDatabase.read { db in
          Set(try Row.fetchAll(db, sql: "SELECT recordName, zoneName, ownerName FROM main.\(IncomingJournal.table)").map {
            CKRecord.ID(recordName: $0["recordName"], zoneID: .init(zoneName: $0["zoneName"], ownerName: $0["ownerName"]))
          })
        }
        let ids = try await metadatabase.read { db in
          try UnsyncedRecordID.all.fetchAll(db).map(CKRecord.ID.init(unsyncedRecordID:)).filter {
            !journalIDs.contains($0) && ($0.zoneID.ownerName == CKCurrentUserDefaultName)
              == (engine.database.databaseScope == .private)
          }
        }
        guard !ids.isEmpty else { return }
        for start in stride(from: 0, to: ids.count, by: 150) {
          let results = try await engine.database.records(for: Array(ids.dropFirst(start).prefix(150)))
          for (id, result) in results {
            switch result {
            case .success(let record):
              let payload = try JSONEncoder().encode(IncomingPayload(record, dataManager: dataManager.wrappedValue))
              try await userDatabase.write { db in
                try IncomingJournal.capture(id: id, recordType: record.recordType, kind: .record,
                                            payload: payload, staged: false, db: db)
              }
            case .failure(let error as CKError) where error.code == .unknownItem:
              // A missing legacy lookup does not establish that the old failed payload was
              // applied. Preserve the hold until an actual deletion or replacement is received.
              continue
            case .failure(let error): throw error
            }
          }
        }
        await replayIncomingChanges()
      } catch is CancellationError { }
      catch { reportIncomingFailure(error) }
    }
  }
#endif
