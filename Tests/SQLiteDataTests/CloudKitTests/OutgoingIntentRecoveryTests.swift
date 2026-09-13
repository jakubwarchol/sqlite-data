#if canImport(CloudKit)
  import CloudKit
  import DependenciesTestSupport
  import Foundation
  @testable import SQLiteData
  import Testing

  @Suite("Outgoing journal recovery", .timeLimit(.minutes(1)))
  struct OutgoingIntentRecoveryTests {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func journalFailureRollsBackTheUserWrite() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.engine.userDatabase.write { db in
        try db.execute(sql: "CREATE TEMP TRIGGER reject_intent BEFORE INSERT ON sqlitedata_icloud_outgoingIntents BEGIN SELECT RAISE(ABORT, 'injected journal failure'); END")
      }
      await #expect(throws: DatabaseError.self) {
        try await f.engine.userDatabase.userWrite { db in
          try RemindersList.insert { RemindersList(id: 1) }.execute(db)
        }
      }
      #expect(try await f.engine.userDatabase.read { try RemindersList.count().fetchOne($0) } == 0)
      #expect(try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0).count } == 0)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func missingSidecarMetadataRestoresOriginalClock() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1, title: "Retained") }.execute(db)
      }
      let before = try #require(try await f.engine.metadatabase.read { try SyncMetadata.all.fetchOne($0) })
      // This independent sidecar connection has no user-database temporary triggers.
      try await f.engine.metadatabase.write { db in try SyncMetadata.delete().execute(db) }
      try f.engine.setUpSyncEngine()
      let after = try #require(try await f.engine.metadatabase.read { try SyncMetadata.all.fetchOne($0) })
      #expect(after.userModificationTime == before.userModificationTime)
      #expect(after.recordName == before.recordName)
      #expect(after.zoneName == before.zoneName)
      #expect(try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0).count } == 1)
      try await f.start()
      try await f.engine.processPendingRecordZoneChanges(scope: .private)
      #expect(try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0).count } == 0)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func legacyQueueAdoptionIsTransactionalAndPreservesNewerIntent() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1) }.execute(db)
        try RemindersList.find(1).delete().execute(db)
      }
      let tombstone = try #require(try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0).first })
      try await f.engine.userDatabase.write { db in
        try PendingRecordZoneChange.insert { PendingRecordZoneChange(.saveRecord(tombstone.recordID)) }.execute(db)
        try PendingRecordZoneChange.insert {
          PendingRecordZoneChange(.deleteRecord(CKRecord.ID(recordName: "legacy:remindersLists", zoneID: f.engine.defaultZone.zoneID)))
        }.execute(db)
        try f.engine.prepareOutgoingIntents(in: db)
      }
      let intents = try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0) }
      #expect(intents.count == 2)
      #expect(intents.contains { $0.recordID == tombstone.recordID && $0.isDelete && $0.revision == tombstone.revision })
      #expect(try await f.engine.metadatabase.read { try PendingRecordZoneChange.count().fetchOne($0) } == 0)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func oldSaveReceiptCannotClearANewerDeletion() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1) }.execute(db)
      }
      let receipt = try await f.engine.sendPendingRecordZoneChanges(scope: .private)
      try await f.engine.userDatabase.userWrite { db in try RemindersList.find(1).delete().execute(db) }
      let deleted = try #require(try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0).first })
      await receipt.receive()
      #expect(try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0).first?.revision } == deleted.revision)
      #expect(deleted.isDelete)
      try await f.engine.processPendingRecordZoneChanges(scope: .private)
      #expect(try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0).count } == 0)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func zoneMoveReplayNeverUsesTheOldRecordIdentity() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1) }.execute(db)
      }
      try await f.engine.processPendingRecordZoneChanges(scope: .private)
      try await f.engine.userDatabase.userWrite { db in
        try SyncMetadata.update { $0.zoneName = "new-zone" }.execute(db)
      }
      let intents = try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0) }
      #expect(intents.count == 2)
      #expect(intents.contains { $0.isDelete && $0.recordID.zoneID == f.engine.defaultZone.zoneID })
      try await f.engine.metadatabase.write { db in try SyncMetadata.delete().execute(db) }
      try f.engine.setUpSyncEngine()
      let restored = try #require(try await f.engine.metadatabase.read { try SyncMetadata.all.fetchOne($0) })
      #expect(restored.zoneName == "new-zone")
      #expect(restored._lastKnownServerRecordAllFields == nil)
      let batch = try #require(await f.engine.nextRecordZoneChangeBatch(syncEngine: f.engine.private))
      #expect(batch.recordsToSave.count == 1)
      #expect(batch.recordsToSave.first?.recordID.zoneID.zoneName == "new-zone")
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func wrongContainerCannotAdoptJournal() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      await #expect(throws: OutgoingIntent.ConfigurationMismatch.self) {
        try await f.engine.userDatabase.write { db in
          try OutgoingIntent.create(in: db, containerIdentifier: "different-container")
        }
      }
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func assetEncodingFailureRetainsIntentWithoutDiagnostics() async throws {
      let database = try SQLiteDataTests.database(containerIdentifier: "asset.\(UUID())", attachMetadatabase: false)
      let engine = try withDependencies { $0.context = .test } operation: {
        try SyncEngine(for: database, tables: RemindersList.self, RemindersListAsset.self,
                       startImmediately: false, diagnostics: nil)
      }
      defer { engine.stop() }
      try await engine.start()
      try await engine.processPendingDatabaseChanges(scope: .private)
      try await engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1) }.execute(db)
      }
      try await engine.processPendingRecordZoneChanges(scope: .private)
      try await engine.userDatabase.userWrite { db in
        try RemindersListAsset.insert { RemindersListAsset(remindersListID: 1, coverImage: Data([1, 2, 3])) }.execute(db)
      }
      await withKnownIssue {
        await withDependencies { $0.dataManager = OutgoingFailingDataManager() } operation: {
          let batch = await engine.nextRecordZoneChangeBatch(syncEngine: engine.private)
          #expect(batch?.recordsToSave.isEmpty == true)
        }
      }
      #expect(try await engine.userDatabase.read { try OutgoingIntent.fetch($0).count } == 1)
      try await engine.processPendingRecordZoneChanges(scope: .private)
      #expect(try await engine.userDatabase.read { try OutgoingIntent.fetch($0).count } == 0)
    }
  }

  private struct OutgoingFailingDataManager: DataManager {
    var temporaryDirectory: URL { URL(fileURLWithPath: "/tmp") }
    func load(_ url: URL) throws -> Data { Data() }
    func sha256(of fileURL: URL) -> Data? { nil }
    func save(_ data: Data, to url: URL) throws { throw Failure() }
    private struct Failure: Error {}
  }
#endif
