#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import DependenciesTestSupport
  import Foundation
  @testable import SQLiteData
  import Testing

  @MainActor
  @Suite(.timeLimit(.minutes(1)))
  struct SyncDiagnosticFailureTests {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func outgoingAssetFailureMakesBatchPreparationPartial() async throws {
      let fixture = try SyncDiagnosticsFixture()
      let engine = fixture.engine
      defer { engine.stop() }
      try await fixture.start()
      try await engine.userDatabase.userWrite { db in
        try RemindersList.insert { RemindersList(id: 1, title: "Parent") }.execute(db)
        try RemindersListAsset.insert {
          RemindersListAsset(remindersListID: 1, coverImage: Data("private bytes".utf8))
        }.execute(db)
      }
      await withKnownIssue {
        await withDependencies { $0.dataManager = FailingDiagnosticDataManager() } operation: {
          _ = await engine.nextRecordZoneChangeBatch(syncEngine: engine.private)
        }
      }
      let events = await fixture.collected()
      #expect(events.contains { $0.kind == .operationFailed && $0.stage == .batchPrepared })
      #expect(events.contains { $0.kind == .batchPrepared && $0.outcome == .partial })
      let text = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
      #expect(!text.contains("private bytes"))
      #expect(!text.contains("private write path"))
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func missingParentIsDeferredInsteadOfApplied() async throws {
      let fixture = try SyncDiagnosticsFixture()
      let engine = fixture.engine
      defer { engine.stop() }
      try await fixture.start()
      let parentID = RemindersList.recordID(for: 999, zoneID: engine.defaultZone.zoneID)
      let record = CKRecord(recordType: Reminder.tableName,
                            recordID: Reminder.recordID(for: 1, zoneID: engine.defaultZone.zoneID))
      record.setValue("1", forKey: "id", at: 1)
      record.setValue("Secret child", forKey: "title", at: 1)
      record.setValue(false, forKey: "isCompleted", at: 1)
      record.setValue("999", forKey: "remindersListID", at: 1)
      record.parent = CKRecord.Reference(recordID: parentID, action: .none)
      await engine.handleEvent(.fetchedRecordZoneChanges(modifications: [record], deletions: []),
                                syncEngine: engine.private)
      let application = try #require(await fixture.collected().first { $0.kind == .applicationFinished })
      #expect(application.outcome == .deferred)
      #expect(application.counts["deferred"] == 1)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func unknownEntityIsExplicitlyPartialAndDoesNotExposeUnknownTypeText() async throws {
      let fixture = try SyncDiagnosticsFixture()
      let engine = fixture.engine
      defer { engine.stop() }
      try await fixture.start()
      let record = CKRecord(recordType: "unknown_sensitive_type",
                            recordID: CKRecord.ID(recordName: "secret"))
      await engine.handleEvent(.fetchedRecordZoneChanges(modifications: [record], deletions: []),
                                syncEngine: engine.private)
      let events = await fixture.collected()
      #expect(events.first { $0.kind == .applicationFinished }?.outcome == .partial)
      #expect(!String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains("sensitive"))
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func missingAssetProducesLocalFailureWithoutPath() async throws {
      let fixture = try SyncDiagnosticsFixture()
      let engine = fixture.engine
      defer { engine.stop() }
      try await fixture.start()
      _ = try await fixture.remoteUpdate()
      let record = CKRecord(recordType: RemindersListAsset.tableName,
                            recordID: RemindersListAsset.recordID(for: 1, zoneID: engine.defaultZone.zoneID))
      record.setValue("1", forKey: "remindersListID", at: 1)
      record.setAsset(CKAsset(fileURL: URL(filePath: "/missing/private-asset-\(UUID())")),
                       forKey: "coverImage", at: 1)
      record.parent = CKRecord.Reference(
        recordID: RemindersList.recordID(for: 1, zoneID: engine.defaultZone.zoneID), action: .none
      )
      await withKnownIssue {
        await engine.handleEvent(.fetchedRecordZoneChanges(modifications: [record], deletions: []),
                                  syncEngine: engine.private)
      }
      let events = await fixture.collected()
      #expect(events.first { $0.kind == .applicationFinished }?.outcome == .failed)
      #expect(events.contains { $0.kind == .operationFailed })
      #expect(!String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains("private-asset"))
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func metadataReadFailureRemainsNilButIsObservable() async throws {
      let fixture = try SyncDiagnosticsFixture()
      let emptyDatabase = try DatabaseQueue()
      let state = fixture.engine.diagnosticStateSerialization(in: emptyDatabase, scope: .private)
      #expect(state == nil)
      let events = await fixture.collected()
      #expect(events.contains { $0.kind == .operationFailed && $0.failures.first?.category == .sqlite })
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func failedBatchRetryAndFailedDeletionRemainVisible() async throws {
      let fixture = try SyncDiagnosticsFixture()
      let engine = fixture.engine
      defer { engine.stop() }
      try await fixture.start()
      let record = CKRecord(recordType: RemindersList.tableName,
                            recordID: RemindersList.recordID(for: 123, zoneID: engine.defaultZone.zoneID))
      await engine.handleEvent(.sentRecordZoneChanges(
        savedRecords: [], failedRecordSaves: [(record, CKError(.batchRequestFailed))],
        deletedRecordIDs: [], failedRecordDeletes: [record.recordID: CKError(.networkUnavailable)]
      ), syncEngine: engine.private)
      let events = await fixture.collected()
      let result = try #require(events.first { $0.kind == .uploadResults })
      #expect(result.outcome == .failed)
      #expect(result.counts["failedDeletes"] == 1)
      #expect(result.failures.count == 2)
      #expect(events.contains { $0.kind == .retryEnqueued && $0.counts["records"] == 1 })
    }
  }

  private struct FailingDiagnosticDataManager: DataManager {
    var temporaryDirectory: URL { URL(filePath: "/unused/private write path") }
    func load(_ url: URL) throws -> Data { throw failure }
    func save(_ data: Data, to url: URL) throws { throw failure }
    func sha256(of fileURL: URL) -> Data? { nil }
    private var failure: NSError {
      NSError(domain: "private write path", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "private bytes"])
    }
  }
#endif
