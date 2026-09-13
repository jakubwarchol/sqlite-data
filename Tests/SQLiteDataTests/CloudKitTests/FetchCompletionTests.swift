#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import SQLiteData
  import Testing

  extension BaseCloudKitTests {
    @MainActor
    @Suite(.timeLimit(.minutes(1)))
    final class FetchCompletionTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func emptyFetchCompletesBothDatabases() async throws {
        defer { syncEngine.stop() }
        try await syncEngine.fetchChangesAndApply()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnsAfterDownloadedUpdateIsVisible() async throws {
        defer { syncEngine.stop() }
        try await seedRemoteUpdate()
        try await syncEngine.fetchChangesAndApply()
        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db)?.title == "Remote title")
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnsAfterDownloadedDeletionIsVisible() async throws {
        defer { syncEngine.stop() }
        try await seedRemoteUpdate()
        _ = try syncEngine.modifyRecords(scope: .private, deleting: [RemindersList.recordID(for: 1)])
        try await syncEngine.fetchChangesAndApply()
        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db) == nil)
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(arguments: [false, true])
      func failedWriteReplaysBeforeLaterEmptyFetchSucceeds(deleting: Bool) async throws {
        defer { syncEngine.stop() }
        try await seedRemoteUpdate()
        if deleting {
          _ = try syncEngine.modifyRecords(scope: .private, deleting: [RemindersList.recordID(for: 1)])
        }
        try await userDatabase.write { db in
          try db.execute(sql: """
            CREATE TEMP TRIGGER reject_download BEFORE \(deleting ? "DELETE" : "UPDATE") ON remindersLists
            BEGIN SELECT RAISE(ABORT, 'injected apply failure'); END
            """)
        }
        await withKnownIssue {
          await #expect(throws: SyncEngine.FetchCompletionError.self) {
            try await syncEngine.fetchChangesAndApply()
          }
        }
        try await userDatabase.write { db in
          try db.execute(sql: "DROP TRIGGER reject_download")
          try #expect(RemindersList.find(1).fetchOne(db)?.title == "Local title")
        }
        try await syncEngine.fetchChangesAndApply()
        try await userDatabase.read { db in
          try #expect(RemindersList.find(1).fetchOne(db)?.title == (deleting ? nil : "Remote title"))
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func stoppedEngineIsNotSuccess() async throws {
        syncEngine.stop()
        await #expect(throws: SyncEngine.FetchCompletionError.self) {
          try await syncEngine.fetchChangesAndApply()
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func unavailableAccountIsNotSuccess() async throws {
        defer { syncEngine.stop() }
        container._accountStatus.withValue { $0 = .noAccount }
        await #expect(throws: SyncEngine.FetchCompletionError.self) {
          try await syncEngine.fetchChangesAndApply()
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func missingFetchEventsAreNotSuccess() async throws {
        defer { syncEngine.stop() }
        syncEngine.shared._fetchChangesOverride.withValue { $0 = {} }
        await #expect(throws: SyncEngine.FetchCompletionError.self) {
          try await syncEngine.fetchChangesAndApply()
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func transportErrorPropagatesAndCanRetry() async throws {
        defer { syncEngine.stop() }
        syncEngine.private._fetchChangesOverride.withValue { $0 = { throw CKError(.networkFailure) } }
        await #expect(throws: CKError.self) { try await syncEngine.fetchChangesAndApply() }
        syncEngine.private._fetchChangesOverride.withValue { $0 = nil }
        try await syncEngine.fetchChangesAndApply()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func zoneErrorPropagatesAndCanRetry() async throws {
        defer { syncEngine.stop() }
        let engine = syncEngine, cloud = syncEngine.private
        cloud._fetchChangesOverride.withValue {
          $0 = {
            await engine.handleEvent(.willFetchChanges, syncEngine: cloud)
            await engine.handleEvent(.willFetchRecordZoneChanges(zoneID: .init(zoneName: "zone")), syncEngine: cloud)
            await engine.handleEvent(
              .didFetchRecordZoneChanges(zoneID: .init(zoneName: "zone"), error: CKError(.networkFailure)),
              syncEngine: cloud
            )
            await engine.handleEvent(.didFetchChanges, syncEngine: cloud)
          }
        }
        await #expect(throws: CKError.self) { try await engine.fetchChangesAndApply() }
        cloud._fetchChangesOverride.withValue { $0 = nil }
        try await engine.fetchChangesAndApply()
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func waitsForFetchAndRejectsConcurrentCheckedFetch() async throws {
        defer { syncEngine.stop() }
        let gate = FetchCompletionGate()
        let engine = syncEngine, cloud = syncEngine.private
        cloud._fetchChangesOverride.withValue {
          $0 = {
            await engine.handleEvent(.willFetchChanges, syncEngine: cloud)
            await gate.hold()
            await engine.handleEvent(.didFetchChanges, syncEngine: cloud)
          }
        }
        let finished = LockIsolated(false)
        let first = Task {
          try await engine.fetchChangesAndApply()
          finished.withValue { $0 = true }
        }
        await gate.waitUntilEntered()
        #expect(!finished.value)
        await #expect(throws: SyncEngine.FetchCompletionError.self) {
          try await engine.fetchChangesAndApply()
        }
        await gate.release()
        try await first.value
        #expect(finished.value)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func stopDuringFetchInvalidatesCompletion() async throws {
        let gate = FetchCompletionGate()
        let engine = syncEngine, cloud = syncEngine.private
        cloud._fetchChangesOverride.withValue {
          $0 = {
            await engine.handleEvent(.willFetchChanges, syncEngine: cloud)
            await gate.hold()
            await engine.handleEvent(.didFetchChanges, syncEngine: cloud)
          }
        }
        let request = Task { try await engine.fetchChangesAndApply() }
        await gate.waitUntilEntered()
        engine.stop()
        await gate.release()
        await #expect(throws: SyncEngine.FetchCompletionError.self) { try await request.value }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func cancellationDuringFetchCannotReportSuccess() async throws {
        defer { syncEngine.stop() }
        let gate = FetchCompletionGate()
        let engine = syncEngine, cloud = syncEngine.private
        cloud._fetchChangesOverride.withValue {
          $0 = {
            await engine.handleEvent(.willFetchChanges, syncEngine: cloud)
            await gate.hold()
            await engine.handleEvent(.didFetchChanges, syncEngine: cloud)
          }
        }
        let request = Task { try await engine.fetchChangesAndApply() }
        await gate.waitUntilEntered()
        request.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await request.value }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func transportErrorCannotHideAnotherScopesApplyFailure() async throws {
        defer { syncEngine.stop() }
        let engine = syncEngine, cloud = syncEngine.shared
        let gate = SyncRecoveryGate()
        engine.private._fetchChangesOverride.withValue {
          $0 = { await gate.hold(); throw CKError(.networkFailure) }
        }
        cloud._fetchChangesOverride.withValue {
          $0 = {
            await engine.handleFetchedRecordZoneChanges(
              modifications: [CKRecord(recordType: RemindersList.tableName,
                recordID: CKRecord.ID(recordName: "1:remindersLists",
                  zoneID: CKRecordZone.ID(zoneName: "shared", ownerName: "other-owner")))],
              syncEngine: cloud
            )
            await gate.release()
          }
        }
        await withKnownIssue {
          let error = await #expect(throws: SyncEngine.FetchCompletionError.self) {
            try await engine.fetchChangesAndApply()
          }
          guard case .localApplicationFailed = error else {
            Issue.record("Transport failure concealed a local application failure")
            return
          }
        }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func unresolvedForeignKeyPreventsCompletion() async throws {
        defer { syncEngine.stop() }
        let engine = syncEngine, cloud = syncEngine.private
        cloud._fetchChangesOverride.withValue {
          $0 = {
            await engine.handleEvent(.willFetchChanges, syncEngine: cloud)
            try await engine.userDatabase.write { db in
              try UnsyncedRecordID.insert {
                UnsyncedRecordID(recordID: Reminder.recordID(for: 999))
              }.execute(db)
            }
            await engine.handleEvent(.didFetchChanges, syncEngine: cloud)
          }
        }
        // Avoid the shared mock retrying the private record before the final count check.
        let shared = engine.shared
        shared._fetchChangesOverride.withValue {
          $0 = {
            await engine.handleEvent(.willFetchChanges, syncEngine: shared)
            await engine.handleEvent(.didFetchChanges, syncEngine: shared)
          }
        }
        await #expect(throws: SyncEngine.FetchCompletionError.self) { try await engine.fetchChangesAndApply() }
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func seedRemoteUpdate() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Local title") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let record = try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
        record.setValue("Remote title", forKey: "title", at: now + 1)
        _ = try syncEngine.modifyRecords(scope: .private, saving: [record])
      }
    }
  }

  private actor FetchCompletionGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
      entered = true
      entryWaiter?.resume()
      entryWaiter = nil
      if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitUntilEntered() async {
      if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func release() {
      released = true
      releaseWaiter?.resume()
      releaseWaiter = nil
    }
  }
#endif
