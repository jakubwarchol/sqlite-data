#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import DependenciesTestSupport
  import Dispatch
  import Foundation
  @testable import SQLiteData
  import Testing

  @Suite(.timeLimit(.minutes(1)))
  struct SyncDiagnosticsTests {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func minimumLevelCanChangeWithoutReplacingEngine() async {
      let values = LockIsolated<[SyncDiagnostic]>([])
      let destination = SyncDiagnostics(minimumLevel: .error) { event in
        values.withValue { $0.append(event) }
      }
      let emitter = SyncDiagnosticEmitter(destination)
      let event = SyncDiagnostic(kind: .changesReceived, level: .debug, sessionID: emitter.sessionID)
      emitter.emit(event)
      await emitter.flush()
      #expect(values.value.isEmpty)
      destination.minimumLevel = .debug
      emitter.emit(event)
      await emitter.flush()
      #expect(values.value.count == 1)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func consumerCanReadDatabaseAfterEmissionInsideWriter() async throws {
      let database = try DatabaseQueue(path: URL.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID()).sqlite").path)
      try await database.write { try $0.execute(sql: "CREATE TABLE records (id TEXT PRIMARY KEY NOT NULL)") }
      let readCount = LockIsolated<Int?>(nil)
      let engine = try withDependencies { $0.context = .test } operation: {
        try SyncEngine(for: database, tables: DiagnosticRow.self, startImmediately: false,
          diagnostics: SyncDiagnostics { _ in
            let count = try? database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM records") }
            readCount.withValue { $0 = count ?? nil }
          })
      }
      try await database.write { db in
        try db.execute(sql: "INSERT INTO records VALUES ('local-row')")
        engine.emitDiagnostic(.applicationFinished, outcome: .applied)
      }
      await engine.diagnosticEmitter?.flush()
      #expect(readCount.value == 1)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func slowConsumerDoesNotBlockProducerAndReportsOverflow() async throws {
      let values = LockIsolated<[SyncDiagnostic]>([])
      let gate = DispatchSemaphore(value: 0)
      let entered = AsyncStream.makeStream(of: Void.self)
      let emitter = SyncDiagnosticEmitter(SyncDiagnostics(bufferCapacity: 2) { event in
        let first = values.withValue { values in
          values.append(event)
          return values.count == 1
        }
        if first {
          entered.continuation.yield()
          gate.wait()
        }
      })
      defer { gate.signal(); entered.continuation.finish() }
      func emit() {
        emitter.emit(SyncDiagnostic(kind: .fetchFinished, level: .info, sessionID: emitter.sessionID))
      }
      emit()
      var iterator = entered.stream.makeAsyncIterator()
      await iterator.next()
      for _ in 0..<10 { emit() }
      #expect(values.value.count == 1)
      gate.signal()
      await emitter.flush()
      let events = values.value
      #expect(events.count == 4)
      #expect(events.last?.kind == .eventsDropped)
      #expect(events.last?.counts["dropped"] == 8)
      #expect(events.map(\.sequence) == [1, 2, 3, 12])
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func filterSkipsVerbosePayloadConstruction() async throws {
      let fixture = try SyncDiagnosticsFixture(minimumLevel: .error)
      let built = LockIsolated(false)
      fixture.engine.emitDiagnostic(.batchPrepared, level: .debug, counts: {
        built.withValue { $0 = true }
        return ["requestedChanges": 100]
      }())
      fixture.engine.diagnosticFailure(CancellationError())
      #expect(!built.value)
      #expect(await fixture.collected().isEmpty)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func disabledDestinationDoesNotConstructPayload() throws {
      let database = try DatabaseQueue(path: URL.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID()).sqlite").path)
      try database.write { try $0.execute(sql: "CREATE TABLE records (id TEXT PRIMARY KEY NOT NULL)") }
      let engine = try withDependencies { $0.context = .test } operation: {
        try SyncEngine(for: database, tables: DiagnosticRow.self, startImmediately: false)
      }
      let built = LockIsolated(false)
      engine.emitDiagnostic(.batchPrepared, counts: {
        built.withValue { $0 = true }
        return [:]
      }())
      #expect(!built.value)
      #expect(engine.diagnosticEmitter == nil)
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func failuresDoNotExposeDescriptionsRecordsOrNestedUserInfo() throws {
      let secret = "private task /Users/person/token"
      let error = CKError(.requestRateLimited, userInfo: [
        NSLocalizedDescriptionKey: secret, CKErrorRetryAfterKey: 12.5,
        CKPartialErrorsByItemIDKey: [secret: NSError(domain: secret, code: 99)]
      ])
      let failure = SyncDiagnostic.Failure(sanitizing: error)
      #expect(failure == .init(category: .cloudKit, code: CKError.requestRateLimited.rawValue, name: "requestRateLimited",
                               retryAfterSeconds: 12.5))
      let data = try JSONEncoder().encode([
        failure,
        SyncDiagnostic.Failure(sanitizing: NSError(domain: secret, code: 99)),
        SyncDiagnostic.Failure(sanitizing: SyncEngine.FetchCompletionError.invalidRecord(
          CKRecord.ID(recordName: secret)
        ))
      ])
      let text = String(decoding: data, as: UTF8.self)
      #expect(!text.contains(secret))
      #expect(!text.contains("99"))
      #expect(SyncDiagnostic.Failure(sanitizing: CKError(.networkFailure, userInfo: [
        CKErrorRetryAfterKey: Double.infinity
      ])).retryAfterSeconds == nil)
    }
  }

  @Table("records")
  private struct DiagnosticRow { let id: UUID }
#endif
