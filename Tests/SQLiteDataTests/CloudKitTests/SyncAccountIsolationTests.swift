#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Foundation
  import Dependencies
  import os
  @testable import SQLiteData
  import Testing

  @Suite("Persistent iCloud ownership", .timeLimit(.minutes(1)))
  struct SyncAccountIsolationTests {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func changedAccountCannotReadAnOutgoingBatchBeforeAppNotification() async throws {
      let f = try SyncDiagnosticsFixture(accountIsolation: .init(environment: .development))
      defer { f.engine.stop() }
      try await f.start()
      let container = try #require(f.engine.container as? MockCloudContainer)
      let firstUser = container._userRecordID.value
      try await insert(f)
      let original = f.engine.private
      container._userRecordID.withValue { $0 = CKRecord.ID(recordName: "account-B") }
      #expect(await f.engine.nextRecordZoneChangeBatch(syncEngine: original) == nil)
      #expect(!f.engine.isRunning)
      #expect(try await rowCount(f) == 1)
      #expect(try await pendingCount(f) == 1)
      await expectAccountError(.differentAccount) { try await f.engine.start() }
      #expect(try await rowCount(f) == 1)
      container._userRecordID.withValue { $0 = firstUser }
      try await f.engine.start()
      try await f.engine.processPendingDatabaseChanges(scope: .private)
      try await f.engine.processPendingRecordZoneChanges(scope: .private)
      #expect(try await pendingCount(f) == 0)
      let record = try f.engine.private.database.record(for: RemindersList.recordID(for: 1, zoneID: f.engine.defaultZone.zoneID))
      #expect(record.encryptedValues["title"] as? String == "Account A's offline work")
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func incomingDataFromChangedAccountIsRejectedWithoutAdvancingCheckpoint() async throws {
      let f = try SyncDiagnosticsFixture(accountIsolation: .init(environment: .development))
      defer { f.engine.stop() }
      try await f.start()
      let record = try await f.remoteUpdate()
      let cloud = f.engine.private
      let container = try #require(f.engine.container as? MockCloudContainer)
      container._userRecordID.withValue { $0 = CKRecord.ID(recordName: "account-B") }
      await f.engine.handleEvent(.fetchedRecordZoneChanges(modifications: [record], deletions: []), syncEngine: cloud)
      #expect(!f.engine.isRunning)
      #expect(try await f.engine.incomingPendingCount() == 0)
      #expect(try await f.engine.userDatabase.read { try RemindersList.find(1).fetchOne($0)?.title } == "Local secret")
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func sharedEngineAccountEventFencesBothScopesAndRetainsOfflineEdits() async throws {
      let f = try SyncDiagnosticsFixture(accountIsolation: .init(environment: .development))
      defer { f.engine.stop() }
      try await f.start()
      try await insert(f)
      let privateCloud = f.engine.private, sharedCloud = f.engine.shared
      await f.engine.handleEvent(.accountChange(changeType: .switchAccounts(
        previousUser: CKRecord.ID(recordName: "mock-user"), currentUser: CKRecord.ID(recordName: "account-B")
      )), syncEngine: sharedCloud)
      try await f.engine.stopAndDrain()
      #expect(!f.engine.isRunning)
      #expect(try await rowCount(f) == 1)
      #expect(try await pendingCount(f) == 1)
      #expect(await f.engine.nextRecordZoneChangeBatch(syncEngine: privateCloud) == nil)
      #expect(await f.engine.nextRecordZoneChangeBatch(syncEngine: sharedCloud) == nil)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func existingUnownedDataNeedsExplicitAdoptionAndCannotBeReassigned() async throws {
      let f = try SyncDiagnosticsFixture(accountIsolation: .init(environment: .development))
      defer { f.engine.stop() }
      try await insert(f)
      await expectAccountError(.adoptionRequired) { try await f.engine.start() }
      #expect(!f.engine.isRunning)
      #expect(try await bindingCount(f) == 0)
      try await f.engine.adoptLocalDataForCurrentAccount(try #require(f.engine.accountAdoptionRequest))
      #expect(f.engine.isRunning)
      #expect(try await bindingCount(f) == 1)
      try await f.engine.stopAndDrain()
      let container = try #require(f.engine.container as? MockCloudContainer)
      container._userRecordID.withValue { $0 = CKRecord.ID(recordName: "account-B") }
      await expectAccountError(.differentAccount) { try await f.engine.start() }
      #expect(f.engine.accountAdoptionRequest == nil)
      #expect(try await rowCount(f) == 1)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func adoptionChoiceDoesNotCarryOverToAnotherAccount() async throws {
      let f = try SyncDiagnosticsFixture(accountIsolation: .init(environment: .development))
      defer { f.engine.stop() }
      try await insert(f)
      await expectAccountError(.adoptionRequired) { try await f.engine.start() }
      let request = try #require(f.engine.accountAdoptionRequest)
      let container = try #require(f.engine.container as? MockCloudContainer)
      container._userRecordID.withValue { $0 = CKRecord.ID(recordName: "account-B") }
      // A new lookup may refresh the visible prompt, but an older confirmation stays scoped to A.
      await expectAccountError(.adoptionRequired) { try await f.engine.start() }
      #expect(f.engine.accountAdoptionRequest != request)
      await expectAccountError(.accountChangedDuringAdoption) { try await f.engine.adoptLocalDataForCurrentAccount(request) }
      #expect(try await bindingCount(f) == 0)
      #expect(!f.engine.isRunning)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func environmentBindingCannotBeReusedUnderAnotherEnvironment() async throws {
      let f = try SyncDiagnosticsFixture(accountIsolation: .init(environment: .development))
      defer { f.engine.stop() }
      try await f.start()
      try await f.engine.stopAndDrain()
      try await f.engine.userDatabase.write { db in
        try db.execute(sql: "UPDATE sqlitedata_icloud_accountBinding SET environment = 'production'")
      }
      await expectAccountError(.differentEnvironment) { try await f.engine.start() }
      #expect(!f.engine.isRunning)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func stopDrainsSuspendedAccountLookupWithoutBindingOrStartingAfterward() async throws {
      let (events, continuation) = AsyncStream<Void>.makeStream()
      defer { continuation.finish() }
      let f = try SyncDiagnosticsFixture(receive: {
        if $0.kind == .drainWaiting { continuation.yield(()) }
      }, accountIsolation: .init(environment: .development))
      let container = try #require(f.engine.container as? MockCloudContainer)
      let gate = SyncRecoveryGate()
      defer { Task { await gate.release() } }
      container._userRecordIDOverride.withValue { $0 = {
        await gate.hold()
        return CKRecord.ID(recordName: "mock-user")
      } }
      let starting = Task { try await f.engine.start() }
      await gate.waitUntilEntered()
      let draining = Task { try await f.engine.stopAndDrain() }
      var iterator = events.makeAsyncIterator()
      _ = try #require(await iterator.next())
      #expect(try await bindingCount(f) == 0)
      await gate.release()
      await #expect(throws: CancellationError.self) { try await starting.value }
      try await draining.value
      #expect(!f.engine.isRunning)
      #expect(try await bindingCount(f) == 0)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func boundStoreCannotDisableProtectionAtConstruction() async throws {
      let f = try SyncDiagnosticsFixture(accountIsolation: .init(environment: .development))
      try await f.start()
      try await f.engine.stopAndDrain()
      #expect(throws: SyncAccountIsolationError.self) {
        try withDependencies { $0.context = .test } operation: {
          _ = try SyncEngine(for: f.engine.userDatabase.database,
            tables: RemindersList.self, Reminder.self, RemindersListAsset.self,
            containerIdentifier: f.engine.container.containerIdentifier,
            startImmediately: false, logger: Logger(.disabled))
        }
      }
      #expect(try await bindingCount(f) == 1)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private func insert(_ f: SyncDiagnosticsFixture) async throws {
      try await f.engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1, title: "Account A's offline work") }.execute(db)
      }
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private func rowCount(_ f: SyncDiagnosticsFixture) async throws -> Int {
      try await f.engine.userDatabase.read { try RemindersList.count().fetchOne($0) ?? 0 }
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private func pendingCount(_ f: SyncDiagnosticsFixture) async throws -> Int {
      try await f.engine.userDatabase.read {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlitedata_icloud_outgoingIntents") ?? 0
      }
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private func bindingCount(_ f: SyncDiagnosticsFixture) async throws -> Int {
      try await f.engine.userDatabase.read {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlitedata_icloud_accountBinding") ?? 0
      }
    }

    private func expectAccountError(_ expected: SyncAccountIsolationError,
      _ operation: () async throws -> Void
    ) async {
      do { try await operation(); Issue.record("Expected an account ownership failure") }
      catch let error as SyncAccountIsolationError { #expect(error.localizedDescription == expected.localizedDescription) }
      catch { Issue.record(error) }
    }
  }
#endif
