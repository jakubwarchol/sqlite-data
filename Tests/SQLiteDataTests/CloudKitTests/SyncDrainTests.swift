#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  @testable import SQLiteData
  import Testing

  @Suite("Awaited sync retirement", .timeLimit(.minutes(1)))
  struct SyncDrainTests {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func drainWaitsForSuspendedWorkAndRejectsItsLateWrite() async throws {
      let (events, continuation) = AsyncStream<Void>.makeStream()
      defer { continuation.finish() }
      let f = try SyncDiagnosticsFixture { event in
        if event.kind == .drainWaiting { continuation.yield(()) }
      }
      defer { f.engine.stop() }
      try await f.start()
      let gate = SyncRecoveryGate()
      defer { Task { await gate.release() } }
      let engine = f.engine, old = engine.private
      old._fetchChangesOverride.withValue { $0 = {
        await gate.hold()
        try await engine.userDatabase.write { db in
          try RemindersList.insert { RemindersList(id: 99, title: "Late callback") }.execute(db)
        }
      } }
      let fetching = Task { () -> Bool in
        do { try await engine.fetchChanges(); return false }
        catch is CancellationError { return true }
        catch { Issue.record(error); return false }
      }
      await gate.waitUntilEntered()
      engine.stop()
      let finished = LockIsolated(false)
      let draining = Task { try await engine.stopAndDrain(); finished.withValue { $0 = true } }
      var iterator = events.makeAsyncIterator()
      _ = try #require(await iterator.next())
      #expect(!finished.value)
      await gate.release()
      #expect(await fetching.value)
      try await draining.value
      #expect(finished.value)
      #expect(try await engine.userDatabase.read { try RemindersList.count().fetchOne($0) } == 0)
      let record = CKRecord(recordType: RemindersList.tableName,
                            recordID: RemindersList.recordID(for: 99, zoneID: engine.defaultZone.zoneID))
      record.setValue(99, forKey: "id", at: 1)
      await engine.handleEvent(.fetchedRecordZoneChanges(modifications: [record], deletions: []), syncEngine: old)
      #expect(try await engine.incomingPendingCount() == 0)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func restartJoinsTheOutstandingDrain() async throws {
      let (events, continuation) = AsyncStream<Void>.makeStream()
      defer { continuation.finish() }
      let f = try SyncDiagnosticsFixture { event in
        if event.kind == .drainWaiting { continuation.yield(()) }
      }
      defer { f.engine.stop() }
      try await f.start()
      let gate = SyncRecoveryGate()
      defer { Task { await gate.release() } }
      let engine = f.engine, old = engine.private
      old._fetchChangesOverride.withValue { $0 = { await gate.hold() } }
      let fetching = Task { try await engine.fetchChanges() }
      await gate.waitUntilEntered()
      engine.stop()
      let restarting = Task { try await engine.start() }
      var iterator = events.makeAsyncIterator()
      _ = try #require(await iterator.next())
      #expect(!engine.isRunning)
      await gate.release()
      try await fetching.value
      try await restarting.value
      #expect(engine.isRunning)
      #expect(engine.private !== old)
      #expect(await engine.nextRecordZoneChangeBatch(syncEngine: old) == nil)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func reentrantDrainIsRejectedBeforeStopping() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      let engine = f.engine, cloud = engine.private
      let rejected = LockIsolated(false)
      cloud._fetchChangesOverride.withValue { $0 = {
        do { try await engine.stopAndDrain() }
        catch SyncEngine.LifetimeError.reentrantDrain { rejected.withValue { $0 = true } }
        await engine.handleEvent(.willFetchChanges, syncEngine: cloud)
        await engine.handleEvent(.didFetchChanges, syncEngine: cloud)
      } }
      try await engine.fetchChangesAndApply()
      #expect(rejected.value)
      #expect(engine.isRunning)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func drainWaitsForCloudKitCancellationAndClearsOldActivity() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.start()
      let old = f.engine.private
      await f.engine.handleEvent(.willFetchChanges, syncEngine: old)
      #expect(f.engine.isFetchingChanges)
      let gate = SyncRecoveryGate()
      defer { Task { await gate.release() } }
      old._cancelOperationsOverride.withValue { $0 = { await gate.hold() } }
      let finished = LockIsolated(false)
      let draining = Task { try await f.engine.stopAndDrain(); finished.withValue { $0 = true } }
      await gate.waitUntilEntered()
      #expect(!finished.value)
      #expect(!f.engine.isFetchingChanges)
      await gate.release()
      try await draining.value
      try await f.engine.start()
      await f.engine.handleEvent(.willFetchChanges, syncEngine: old)
      #expect(!f.engine.isFetchingChanges)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func explicitResetRetainsOwnershipAndRestoresOfflineTracking() async throws {
      let f = try SyncDiagnosticsFixture(accountIsolation: .init(environment: .development))
      defer { f.engine.stop() }
      try await f.start()
      _ = try await f.remoteUpdate()
      try await f.engine.deleteLocalData()
      #expect(f.engine.isRunning)
      #expect(try await f.engine.userDatabase.read { try RemindersList.count().fetchOne($0) } == 0)
      try await f.engine.stopAndDrain()
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 2, title: "After explicit reset") }.execute(db)
      }
      #expect(try await f.engine.userDatabase.read {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlitedata_icloud_outgoingIntents")
      } == 1)
      let container = try #require(f.engine.container as? MockCloudContainer)
      container._userRecordID.withValue { $0 = CKRecord.ID(recordName: "account-B") }
      await #expect(throws: SyncAccountIsolationError.self) { try await f.engine.start() }
    }
  }
#endif
