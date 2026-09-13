#if canImport(CloudKit)
  import CloudKit
  @testable import SQLiteData
  import Testing

  @Suite("Durable incoming recovery", .timeLimit(.minutes(1)))
  struct IncomingJournalTests {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func failedUpdateReplaysAfterRestartWithoutCloudRedelivery() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      _ = try await f.remoteUpdate()
      try await f.engine.userDatabase.write { db in
        try db.execute(sql: "CREATE TEMP TRIGGER reject_incoming BEFORE INSERT ON remindersLists BEGIN SELECT RAISE(ABORT, 'injected apply failure'); END")
      }
      await withKnownIssue { try await f.engine.fetchChanges() }
      #expect(try await title(f) == "Local secret")
      #expect(try await f.engine.incomingPendingCount() == 1)
      let checkpoint = f.engine.private.state.changeTag.value
      try await f.engine.stopAndDrain()
      try await f.engine.userDatabase.write { db in try db.execute(sql: "DROP TRIGGER reject_incoming") }
      try await f.engine.start()
      #expect(f.engine.private.state.changeTag.value == checkpoint)
      // The resumed transport starts after that record's server change tag.
      try await f.engine.fetchChangesAndApply()
      #expect(try await title(f) == "Remote secret")
      #expect(try await f.engine.incomingPendingCount() == 0)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func failedRetirementRollsBackDeletionAndReplayKeepsLaterRecreation() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      _ = try await f.remoteUpdate()
      try await f.engine.fetchChangesAndApply()
      let id = RemindersList.recordID(for: 1, zoneID: f.engine.defaultZone.zoneID)
      _ = try f.engine.modifyRecords(scope: .private, deleting: [id])
      try await f.engine.userDatabase.write { db in
        try db.execute(sql: "CREATE TEMP TRIGGER reject_incoming_receipt BEFORE DELETE ON sqlitedata_icloud_incomingJournal WHEN OLD.staged = 0 BEGIN SELECT RAISE(ABORT, 'injected inbox receipt failure'); END")
      }
      await withKnownIssue { try await f.engine.fetchChanges() }
      #expect(try await title(f) == "Remote secret", "The row and inbox retirement must roll back together")
      #expect(try await f.engine.incomingPendingCount() == 1)
      try await f.engine.userDatabase.write { db in try db.execute(sql: "DROP TRIGGER reject_incoming_receipt") }
      try await f.engine.recoverIncomingChanges()
      #expect(try await title(f) == nil)
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1, title: "Recreated after recovery") }.execute(db)
      }
      try await f.engine.stopAndDrain()
      try await f.engine.start()
      try await f.engine.fetchChangesAndApply()
      #expect(try await title(f) == "Recreated after recovery")
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func stagedChangesCannotApplyBeforeTheirCheckpoint() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      _ = try await f.remoteUpdate()
      f.engine.private._automaticallyCheckpoint.withValue { $0 = false }
      try await f.engine.fetchChanges()
      #expect(try await title(f) == "Local secret")
      #expect(try await f.engine.incomingPendingCount() == 1)
      await #expect(throws: SyncEngine.FetchCompletionError.self) {
        try await f.engine.fetchChangesAndApply()
      }
      f.engine.private._automaticallyCheckpoint.withValue { $0 = true }
      await f.engine.commitMockIncomingCheckpoint(f.engine.private)
      try await f.engine.fetchChangesAndApply()
      #expect(try await title(f) == "Remote secret")
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func captureFailurePreservesThePreviousCheckpointAndDeletion() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      _ = try await f.remoteUpdate()
      try await f.engine.fetchChangesAndApply()
      let previous = f.engine.private.state.changeTag.value
      let id = RemindersList.recordID(for: 1, zoneID: f.engine.defaultZone.zoneID)
      _ = try f.engine.modifyRecords(scope: .private, deleting: [id])
      try await f.engine.userDatabase.write { db in
        try db.execute(sql: "CREATE TEMP TRIGGER reject_capture BEFORE INSERT ON sqlitedata_icloud_incomingJournal BEGIN SELECT RAISE(ABORT, 'injected capture failure'); END")
      }
      await withKnownIssue { try await f.engine.fetchChanges() }
      #expect(try await title(f) == "Remote secret")
      #expect(f.engine.private.state.changeTag.value > previous)
      try await f.engine.userDatabase.write { db in try db.execute(sql: "DROP TRIGGER reject_capture") }
      try await f.engine.recoverIncomingChanges()
      #expect(try await title(f) == nil)
      #expect(try await f.engine.incomingPendingCount() == 0)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private func title(_ f: SyncDiagnosticsFixture) async throws -> String? {
      try await f.engine.userDatabase.read { try RemindersList.find(1).fetchOne($0)?.title }
    }
  }
#endif
