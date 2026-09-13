#if canImport(CloudKit)
  import CloudKit
  import Foundation
  import Dependencies
  @testable import SQLiteData
  import Testing

  @Suite("Incoming checkpoint boundaries", .timeLimit(.minutes(1)))
  struct IncomingCheckpointTests {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func failedCheckpointKeepsStagedPayloadAndReplaysAfterRestart() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      _ = try await f.remoteUpdate()
      try await f.engine.userDatabase.write { db in
        try db.execute(sql: "CREATE TEMP TRIGGER reject_checkpoint BEFORE INSERT ON sqlitedata_icloud_incomingCheckpoints BEGIN SELECT RAISE(ABORT, 'injected checkpoint failure'); END")
      }
      await withKnownIssue { try await f.engine.fetchChanges() }
      #expect(try await f.engine.incomingPendingCount() == 1)
      #expect(try await title(f) == "Local secret")
      try await f.engine.userDatabase.write { db in try db.execute(sql: "DROP TRIGGER reject_checkpoint") }
      try await f.engine.recoverIncomingChanges()
      #expect(try await title(f) == "Remote secret")
      #expect(try await f.engine.incomingPendingCount() == 0)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func assetReplaySurvivesRemovalOfEveryDownloadedTemporaryFile() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      let parent = try await f.remoteUpdate()
      try await f.engine.fetchChangesAndApply()
      let manager = try #require(f.engine.dataManager.wrappedValue as? InMemoryDataManager)
      let original = URL(fileURLWithPath: "/tmp/incoming-original-\(UUID())")
      let bytes = Data("Retained asset bytes".utf8)
      try manager.save(bytes, to: original)
      let asset = CKRecord(recordType: RemindersListAsset.tableName,
        recordID: RemindersListAsset.recordID(for: 1, zoneID: f.engine.defaultZone.zoneID))
      asset.setValue("1", forKey: "id", at: 100)
      asset.setValue("1", forKey: "remindersListID", at: 100)
      withDependencies { $0.dataManager = manager } operation: {
        #expect(asset.setAsset(CKAsset(fileURL: original), forKey: "coverImage", at: 100))
      }
      asset.parent = CKRecord.Reference(record: parent, action: .none)
      try await f.engine.userDatabase.write { db in
        try db.execute(sql: "CREATE TEMP TRIGGER reject_asset BEFORE INSERT ON remindersListAssets BEGIN SELECT RAISE(ABORT, 'injected asset apply failure'); END")
      }
      await withKnownIssue {
        await f.engine.handleEvent(.fetchedRecordZoneChanges(modifications: [asset], deletions: []), syncEngine: f.engine.private)
      }
      #expect(try await f.engine.incomingPendingCount() == 1)
      try await f.engine.stopAndDrain()
      manager.storage.withValue { $0.removeAll() }
      try await f.engine.userDatabase.write { db in try db.execute(sql: "DROP TRIGGER reject_asset") }
      try await f.engine.start()
      try await f.engine.fetchChangesAndApply()
      #expect(try await f.engine.userDatabase.read { try RemindersListAsset.find(1).fetchOne($0)?.coverImage } == bytes)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func oneScopeCheckpointNeverPromotesAnotherScopesPayload() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      let id = CKRecord.ID(recordName: "future-row:futureEntities",
        zoneID: CKRecordZone.ID(zoneName: "shared", ownerName: "another-owner"))
      let record = CKRecord(recordType: "futureEntities", recordID: id)
      await f.engine.captureIncoming(modifications: [record], deletions: [], engine: f.engine.shared)
      await f.engine.commitMockIncomingCheckpoint(f.engine.private)
      #expect(try await f.engine.userDatabase.read { try IncomingJournal.fetch($0).count } == 0)
      await f.engine.commitMockIncomingCheckpoint(f.engine.shared)
      #expect(try await f.engine.userDatabase.read { try IncomingJournal.fetch($0).count } == 1)
      // Unknown entities remain durable for a future schema, without blocking current entities.
      #expect(try await f.engine.incomingPendingCount() == 0)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private func title(_ f: SyncDiagnosticsFixture) async throws -> String? {
      try await f.engine.userDatabase.read { try RemindersList.find(1).fetchOne($0)?.title }
    }
  }
#endif
