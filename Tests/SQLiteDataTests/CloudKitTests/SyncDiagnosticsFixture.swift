#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Dependencies
  import Foundation
  @testable import SQLiteData
  import os

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  struct SyncDiagnosticsFixture {
    let engine: SyncEngine
    let events = LockIsolated<[SyncDiagnostic]>([])

    init(minimumLevel: SyncDiagnostic.Level = .debug) throws {
      let database = try SQLiteDataTests.database(
        containerIdentifier: "diagnostics.\(UUID())", attachMetadatabase: false
      )
      let events = events
      engine = try withDependencies {
        $0.context = .test
      } operation: {
        try SyncEngine(
          for: database, tables: RemindersList.self, Reminder.self, RemindersListAsset.self,
          startImmediately: false, logger: Logger(.disabled),
          diagnostics: SyncDiagnostics(minimumLevel: minimumLevel) { event in
            events.withValue { $0.append(event) }
          }
        )
      }
    }

    func start() async throws {
      try await engine.start()
      try await engine.processPendingDatabaseChanges(scope: .private)
      await clear()
    }

    func clear() async {
      await engine.diagnosticEmitter?.flush()
      events.withValue { $0.removeAll() }
    }

    func collected() async -> [SyncDiagnostic] {
      await engine.diagnosticEmitter?.flush()
      return events.value
    }

    func remoteUpdate() async throws -> CKRecord {
      try await engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1, title: "Local secret") }.execute(db)
      }
      try await engine.processPendingRecordZoneChanges(scope: .private)
      let record = try engine.private.database.record(
        for: RemindersList.recordID(for: 1, zoneID: engine.defaultZone.zoneID)
      )
      record.setValue("Remote secret", forKey: "title", at: record.userModificationTime + 1)
      _ = try engine.modifyRecords(scope: .private, saving: [record])
      await clear()
      return record
    }
  }
#endif
