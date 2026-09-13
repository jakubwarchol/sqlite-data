#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import DependenciesTestSupport
  import Foundation
  @testable import SQLiteData
  import Testing

  @MainActor
  @Suite(.timeLimit(.minutes(1)))
  struct SyncDiagnosticsIntegrationTests {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func publicInitializerDeliversCorrelatedFetchAndCommittedApplication() async throws {
      let fixture = try SyncDiagnosticsFixture()
      let engine = fixture.engine
      defer { engine.stop() }
      try await fixture.start()
      _ = try await fixture.remoteUpdate()
      try await engine.fetchChangesAndApply()
      let events = await fixture.collected()
      let received = try #require(events.first { $0.kind == .changesReceived && $0.scope == .private })
      let applied = try #require(events.first { $0.kind == .applicationFinished && $0.scope == .private })
      #expect(applied.outcome == .applied)
      #expect(applied.recordTypes == ["remindersLists"])
      #expect(received.operationID == applied.operationID)
      #expect(received.sequence < applied.sequence)
      #expect(applied.durationSeconds != nil)
      #expect(Set(events.filter { $0.kind == .fetchFinished }.compactMap(\.scope)) == [.private, .shared])
      #expect(Set(events.filter { $0.kind == .fetchFinished }.compactMap(\.operationID)).count == 2)
      try await engine.userDatabase.read { db in
        try #expect(RemindersList.find(1).fetchOne(db)?.title == "Remote secret")
      }
      let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
      #expect(!encoded.contains("Remote secret"))
      #expect(!encoded.contains("Local secret"))
      #expect(received.recordTypes == ["remindersLists"])
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test(arguments: [false, true])
    func failedApplicationNeverEmitsApplied(deletion: Bool) async throws {
      let fixture = try SyncDiagnosticsFixture()
      let engine = fixture.engine
      defer { engine.stop() }
      try await fixture.start()
      let record = try await fixture.remoteUpdate()
      if deletion { _ = try engine.modifyRecords(scope: .private, deleting: [record.recordID]) }
      try await engine.userDatabase.write { db in
        try db.execute(sql: """
          CREATE TEMP TRIGGER reject_download BEFORE \(deletion ? "DELETE" : "UPDATE") ON remindersLists
          BEGIN SELECT RAISE(ABORT, 'private trigger message'); END
          """)
      }
      await withKnownIssue {
        await #expect(throws: SyncEngine.FetchCompletionError.self) {
          try await engine.fetchChangesAndApply()
        }
      }
      let events = await fixture.collected()
      let application = try #require(events.first { $0.kind == .applicationFinished && $0.scope == .private })
      #expect(application.outcome == .failed)
      #expect(application.recordTypes == ["remindersLists"])
      #expect(events.contains { $0.kind == .operationFailed && $0.failures.first?.category == .sqlite })
      #expect(!events.contains { $0.kind == .applicationFinished && $0.scope == .private && $0.outcome == .applied })
      let text = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
      #expect(!text.contains("private trigger message"))
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func partialDeliveryPreservesCountsAndRetryAfterWithoutRecordIdentity() async throws {
      let fixture = try SyncDiagnosticsFixture()
      let engine = fixture.engine
      defer { engine.stop() }
      try await fixture.start()
      let accepted = CKRecord(recordType: "remindersLists", recordID: .init(recordName: "secret-accepted"))
      let failed = CKRecord(recordType: "remindersLists", recordID: .init(recordName: "secret-failed"))
      await engine.handleEvent(
        .sentRecordZoneChanges(
          savedRecords: [accepted],
          failedRecordSaves: [(failed, CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 7]))],
          deletedRecordIDs: [], failedRecordDeletes: [:]
        ), syncEngine: engine.private
      )
      let event = try #require(await fixture.collected().first { $0.kind == .uploadResults })
      #expect(event.outcome == .partial)
      #expect(event.counts["saved"] == 1)
      #expect(event.counts["failedSaves"] == 1)
      #expect(event.failures.first?.retryAfterSeconds == 7)
      #expect(event.scope == .private)
      let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
      #expect(!text.contains("secret-"))
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func unavailableStartupAndStoppedCheckAreNotSuccess() async throws {
      let fixture = try SyncDiagnosticsFixture()
      let engine = fixture.engine
      let container = try #require(engine.container as? MockCloudContainer)
      container._accountStatus.withValue { $0 = .noAccount }
      try await engine.start()
      engine.stop()
      await #expect(throws: SyncEngine.FetchCompletionError.self) { try await engine.fetchChangesAndApply() }
      let events = await fixture.collected()
      #expect(events.contains { $0.kind == .startupFinished && $0.outcome == .unavailable })
      #expect(events.contains { $0.kind == .stopReturned && $0.outcome == .callbackCompleted })
      #expect(events.contains { $0.kind == .requestFinished && $0.outcome == .failed })
      #expect(!events.contains { $0.kind == .startupFinished && $0.outcome == .prepared })
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func cancelledTransportProducesCancelledRequest() async throws {
      let fixture = try SyncDiagnosticsFixture()
      let engine = fixture.engine
      defer { engine.stop() }
      try await fixture.start()
      engine.private._fetchChangesOverride.withValue { $0 = { throw CancellationError() } }
      await #expect(throws: CancellationError.self) { try await engine.fetchChangesAndApply() }
      let events = await fixture.collected()
      #expect(events.contains { $0.kind == .operationFailed && $0.failures.first?.category == .cancellation })
      #expect(events.contains { $0.kind == .requestFinished && $0.outcome == .cancelled })
      #expect(!events.contains { $0.kind == .requestFinished && $0.outcome == .callbackCompleted })
    }
  }
#endif
