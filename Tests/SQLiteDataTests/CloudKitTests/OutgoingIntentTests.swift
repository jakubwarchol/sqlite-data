#if canImport(CloudKit)
  import CloudKit
  import Dependencies
  import Foundation
  import IssueReporting
  @testable import SQLiteData
  import Testing

  @Suite("Durable outgoing intent", .timeLimit(.minutes(1)))
  struct OutgoingIntentTests {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func stoppedWritesAndRollback() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1, title: "Committed") }.execute(db)
      }
      let original = try await intents(f)
      #expect(original.count == 1)
      struct Rollback: Error {}
      await #expect(throws: Rollback.self) {
        try await f.engine.userDatabase.userWrite { db in
          try RemindersList.find(1).update { $0.title = "Rolled back" }.execute(db)
          try RemindersList.insert { RemindersList(id: 2) }.execute(db)
          throw Rollback()
        }
      }
      #expect(try await intents(f).map(\.revision) == original.map(\.revision))
      try await f.start()
      try await f.engine.processPendingRecordZoneChanges(scope: .private)
      let events = await f.collected().map { ($0.kind.rawValue, $0.failures.map { $0.code ?? -1 }) }
      #expect(try await intents(f).isEmpty, "\(events)")
      #expect(try f.engine.private.database.record(for: original[0].recordID).encryptedValues["title"] as? String == "Committed")
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func newerEditSurvivesDelayedAcknowledgement() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1, title: "First") }.execute(db)
      }
      let receipt = try await f.engine.sendPendingRecordZoneChanges(scope: .private)
      let sent = try await intents(f)[0]
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.find(1).update { $0.title = "Newer" }.execute(db)
      }
      let newer = try await intents(f)[0]
      #expect(sent.revision != newer.revision)
      await receipt.receive()
      #expect(try await intents(f).map(\.revision) == [newer.revision])
      try await f.engine.processPendingRecordZoneChanges(scope: .private)
      let events = await f.collected().map { ($0.kind.rawValue, $0.failures.map { $0.code ?? -1 }) }
      #expect(try await intents(f).isEmpty, "\(events)")
      #expect(try f.engine.private.database.record(for: sent.recordID).encryptedValues["title"] as? String == "Newer")
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func deletedAndRecreatedIdentitySurvivesOldDelete() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1, title: "First") }.execute(db)
      }
      try await f.engine.processPendingRecordZoneChanges(scope: .private)
      try await f.engine.userDatabase.userWrite { db in try RemindersList.find(1).delete().execute(db) }
      let receipt = try await f.engine.sendPendingRecordZoneChanges(scope: .private)
      #expect(try await intents(f).first?.isDelete == true)
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1, title: "Recreated") }.execute(db)
      }
      await receipt.receive()
      #expect(try await intents(f).first?.isDelete == false)
      // The first retry may discover the old server change tag is now absent.
      try await f.engine.processPendingRecordZoneChanges(scope: .private)
      if !(try await intents(f).isEmpty) { try await f.engine.processPendingRecordZoneChanges(scope: .private) }
      let events = await f.collected().map { ($0.kind.rawValue, $0.failures.map { $0.code ?? -1 }) }
      #expect(try await intents(f).isEmpty, "\(events)")
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func failedAcknowledgementWriteRemainsReplayable() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1) }.execute(db)
      }
      let receipt = try await f.engine.sendPendingRecordZoneChanges(scope: .private)
      try await f.engine.userDatabase.write { db in
        try db.execute(sql: "CREATE TEMP TRIGGER reject_receipt BEFORE DELETE ON sqlitedata_icloud_outgoingIntents BEGIN SELECT RAISE(ABORT, 'injected receipt failure'); END")
      }
      await withKnownIssue { await receipt.receive() }
      #expect(try await intents(f).count == 1)
      try await f.engine.userDatabase.write { db in try db.execute(sql: "DROP TRIGGER reject_receipt") }
      try await f.engine.processPendingRecordZoneChanges(scope: .private)
      if !(try await intents(f).isEmpty) { try await f.engine.processPendingRecordZoneChanges(scope: .private) }
      let events = await f.collected().map { ($0.kind.rawValue, $0.failures.map { $0.code ?? -1 }) }
      #expect(try await intents(f).isEmpty, "\(events)")
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func unreceivedAcknowledgementSurvivesEngineReplacement() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1) }.execute(db)
      }
      _ = try await f.engine.sendPendingRecordZoneChanges(scope: .private)
      let before = try await intents(f)[0]
      f.engine.stop()
      try await f.engine.start()
      #expect(try await intents(f).map(\.revision) == [before.revision])
      try await f.engine.processPendingRecordZoneChanges(scope: .private)
      if !(try await intents(f).isEmpty) { try await f.engine.processPendingRecordZoneChanges(scope: .private) }
      let events = await f.collected().map { ($0.kind.rawValue, $0.failures.map { $0.code ?? -1 }) }
      #expect(try await intents(f).isEmpty, "\(events)")
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func overlappingAcknowledgementsNeverGuessRevision() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1, title: "First") }.execute(db)
      }
      let first = try await f.engine.sendPendingRecordZoneChanges(scope: .private)
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.find(1).update { $0.title = "Second" }.execute(db)
      }
      let second = try await f.engine.sendPendingRecordZoneChanges(scope: .private)
      await second.receive()
      await first.receive()
      #expect(try await intents(f).count == 1)
      try await f.engine.processPendingRecordZoneChanges(scope: .private)
      if !(try await intents(f).isEmpty) { try await f.engine.processPendingRecordZoneChanges(scope: .private) }
      let events = await f.collected().map { ($0.kind.rawValue, $0.failures.map { $0.code ?? -1 }) }
      #expect(try await intents(f).isEmpty, "\(events)")
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private func intents(_ f: SyncDiagnosticsFixture) async throws -> [OutgoingIntent] {
      try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0) }
    }
  }
#endif
