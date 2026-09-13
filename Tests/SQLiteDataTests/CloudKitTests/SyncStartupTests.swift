#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Dependencies
  import Foundation
  @testable import SQLiteData
  import Testing

  @Suite("Truthful startup", .timeLimit(.minutes(1)))
  struct SyncStartupTests {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func asynchronousDatabaseFailureIsThrownAndRetryDoesNotStayPoisoned() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      try await f.engine.userDatabase.userWrite { db in
        try db.execute(sql: """
          CREATE TEMP TRIGGER rejectStartup BEFORE INSERT ON sqlitedata_icloud_recordTypes
          BEGIN SELECT RAISE(ABORT, 'injected startup cache failure'); END
          """)
      }
      await #expect(throws: DatabaseError.self) { try await f.engine.start() }
      #expect(!f.engine.isRunning)
      #expect(!f.engine.isPrepared)
      guard case .failed(let error) = f.engine.startupState else {
        Issue.record("Startup did not retain its failure"); return
      }
      #expect(error is DatabaseError)
      #expect(f.engine.fetchCompletion.value.untrackedLocalFailure == nil)
      let events = await f.collected()
      #expect(events.filter { $0.kind == .startupFinished }.map(\.outcome) == [.failed])
      try await f.engine.userDatabase.userWrite { try $0.execute(sql: "DROP TRIGGER rejectStartup") }
      try await f.engine.start()
      #expect(f.engine.isPrepared)
      try await f.engine.fetchChangesAndApply()
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func unavailableAccountIsNotSuccessfulPreparation() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      let container = try #require(f.engine.container as? MockCloudContainer)
      container._accountStatus.withValue { $0 = .noAccount }
      await #expect(throws: SyncEngine.StartupError.self) { try await f.engine.start() }
      #expect(!f.engine.isRunning)
      #expect(!f.engine.isPrepared)
      container._accountStatus.withValue { $0 = .available }
      try await f.engine.start()
      #expect(f.engine.isPrepared)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func cancellationOfOneWaiterDoesNotCancelSharedPreparation() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      let container = try #require(f.engine.container as? MockCloudContainer)
      let gate = SyncRecoveryGate()
      defer { Task { await gate.release() } }
      let checks = LockIsolated(0)
      container._accountStatusOverride.withValue { $0 = {
        checks.withValue { $0 += 1 }
        await gate.hold()
        return .available
      } }
      let first = Task { try await f.engine.start() }
      await gate.waitUntilEntered()
      #expect(f.engine.isRunning)
      #expect(!f.engine.isPrepared)
      guard case .preparing = f.engine.startupState else { Issue.record("Expected preparation"); return }
      // Acquire the same owned attempt before releasing the first waiter.
      let joined = try f.engine.requestStart()
      first.cancel()
      await gate.release()
      await #expect(throws: CancellationError.self) { try await first.value }
      try await joined.value.check()
      #expect(f.engine.isPrepared)
      #expect(checks.value == 1)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func stopWhilePreparingCannotPublishReadyAndRestartUsesNewAttempt() async throws {
      let f = try SyncDiagnosticsFixture()
      defer { f.engine.stop() }
      let container = try #require(f.engine.container as? MockCloudContainer)
      let gate = SyncRecoveryGate()
      defer { Task { await gate.release() } }
      container._accountStatusOverride.withValue { $0 = { await gate.hold(); return .available } }
      let starting = Task { try await f.engine.start() }
      await gate.waitUntilEntered()
      f.engine.stop()
      #expect(!f.engine.isPrepared)
      container._accountStatusOverride.withValue { $0 = nil }
      let restarting = Task { try await f.engine.start() }
      await gate.release()
      await #expect(throws: CancellationError.self) { try await starting.value }
      try await restarting.value
      #expect(f.engine.isPrepared)
      #expect(f.engine.isRunning)
      let events = await f.collected().filter { $0.kind == .startupFinished }
      #expect(events.map(\.outcome) == [.cancelled, .prepared])
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func failurePreservesCloudKitRetryInformationWithoutDiagnostics() async throws {
      let db = try SQLiteDataTests.database(containerIdentifier: "startup.\(UUID())", attachMetadatabase: false)
      let engine = try withDependencies { $0.context = .test } operation: {
        try SyncEngine(for: db, tables: RemindersList.self, startImmediately: false)
      }
      defer { engine.stop() }
      let container = try #require(engine.container as? MockCloudContainer)
      container._accountStatusOverride.withValue { $0 = {
        throw CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 45])
      } }
      do { try await engine.start(); Issue.record("Expected startup failure") }
      catch let error as CKError {
        #expect(error.code == .requestRateLimited)
        #expect((error.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue == 45)
      }
      #expect(!engine.isRunning)
      guard case .failed(let error) = engine.startupState else { Issue.record("Missing failure"); return }
      #expect((error as? CKError)?.code == .requestRateLimited)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func publicAutomaticStartCanBeJoinedAndStopped() async throws {
      let db = try SQLiteDataTests.database(containerIdentifier: "startup.\(UUID())", attachMetadatabase: false)
      let engine = try withDependencies { $0.context = .test } operation: {
        try SyncEngine(for: db, tables: RemindersList.self, startImmediately: true)
      }
      defer { engine.stop() }
      try await engine.start()
      #expect(engine.isPrepared)
      try await engine.stopAndDrain()
      guard case .stopped = engine.startupState else { Issue.record("Expected stopped state"); return }
      #expect(!engine.isPrepared)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func automaticStartRetainsFailureWithoutAnAwaitingCaller() async throws {
      let db = try SQLiteDataTests.database(containerIdentifier: "startup.\(UUID())", attachMetadatabase: false)
      let gate = SyncRecoveryGate()
      defer { Task { await gate.release() } }
      let engine = try withDependencies { $0.context = .test } operation: {
        try SyncEngine(for: db, tables: RemindersList.self, startImmediately: false)
      }
      let container = try #require(engine.container as? MockCloudContainer)
      container._accountStatusOverride.withValue { $0 = {
        await gate.hold()
        throw CKError(.networkUnavailable)
      } }
      // This is the same owned request used by startImmediately, with no waiter.
      _ = try engine.requestStart()
      defer { engine.stop() }
      await gate.waitUntilEntered()
      let attempt = try #require(engine.startupTask.value)
      await gate.release()
      _ = await attempt.result
      // Read after the automatic failure, without invoking start or stop.
      #expect(!engine.isRunning)
      guard case .failed(let error) = engine.startupState else { Issue.record("Missing automatic failure"); return }
      #expect((error as? CKError)?.code == .networkUnavailable)
      await engine.retirementTask.value?.value
    }
  }
#endif
