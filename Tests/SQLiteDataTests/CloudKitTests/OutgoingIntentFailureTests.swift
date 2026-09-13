#if canImport(CloudKit)
  import CloudKit
  @testable import SQLiteData
  import Testing

  @Suite("Outgoing failure recovery", .timeLimit(.minutes(1)))
  struct OutgoingIntentFailureTests {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test(arguments: [CKError.Code.serverRecordChanged, .serverRejectedRequest])
    func staleConflictCannotReviveANewerDeletion(code: CKError.Code) async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      let serverRecord = try await f.remoteUpdate()
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.find(1).update { $0.title = "Pending" }.execute(db)
      }
      let batch = try #require(await f.engine.nextRecordZoneChangeBatch(syncEngine: f.engine.private))
      let sent = try #require(batch.recordsToSave.first)
      try await f.engine.userDatabase.userWrite { db in try RemindersList.find(1).delete().execute(db) }
      let deletion = try #require(try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0).first })
      await f.engine.handleSentRecordZoneChanges(failedRecordSaves: [
        (sent, CKError(code, userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord]))
      ], syncEngine: f.engine.private)
      #expect(try await f.engine.userDatabase.read { try RemindersList.count().fetchOne($0) } == 0)
      #expect(try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0).first?.revision } == deletion.revision)
      #expect(deletion.isDelete)
      try await f.engine.processPendingRecordZoneChanges(scope: .private)
      #expect(try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0).count } == 0)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func stalePermissionFailureCannotDeleteANewerEdit() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1, title: "First") }.execute(db)
      }
      let batch = try #require(await f.engine.nextRecordZoneChangeBatch(syncEngine: f.engine.private))
      let sent = try #require(batch.recordsToSave.first)
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.find(1).update { $0.title = "Newer" }.execute(db)
      }
      let newer = try #require(try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0).first })
      // Keep the recovery zone present but the record absent, exercising unknownItem after
      // the permission failure's asynchronous refetch.
      _ = try f.engine.modifyRecordZones(scope: .shared, saving: [f.engine.defaultZone])
      await f.engine.handleSentRecordZoneChanges(failedRecordSaves: [
        (sent, CKError(.permissionFailure))
      ], syncEngine: f.engine.private)
      #expect(try await f.engine.userDatabase.read { try RemindersList.find(1).fetchOne($0)?.title } == "Newer")
      let retained = try #require(try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0).first })
      #expect(retained.revision == newer.revision)
      #expect(!retained.blocked)
      try await f.engine.processPendingRecordZoneChanges(scope: .private)
      #expect(try await f.engine.userDatabase.read { try OutgoingIntent.fetch($0).count } == 0)
    }
  }
#endif
