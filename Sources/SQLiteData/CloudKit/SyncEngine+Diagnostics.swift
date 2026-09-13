#if canImport(CloudKit)
  import CloudKit
  import GRDB
  import Foundation
  import IssueReporting

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    func makeDiagnosticOperation(
      scope: SyncDiagnostic.Scope? = nil, stage: SyncDiagnostic.Kind,
      parent: SyncDiagnosticOperation? = nil
    ) -> SyncDiagnosticOperation {
      SyncDiagnosticOperation(scope: scope, stage: stage, parent: parent) { [weak self] error in
        self?.diagnosticFailure(error)
      }
    }

    func diagnosticStateSerialization(
      in database: any DatabaseReader, scope: CKDatabase.Scope
    ) -> CKSyncEngine.State.Serialization? {
      do {
        return try database.read { db in
          try StateSerialization.find(#bind(scope)).select(\.data).fetchOne(db)
        }
      } catch {
        diagnosticFailure(error)
        return nil
      }
    }

    func emitDiagnostic(
      _ kind: SyncDiagnostic.Kind, level: SyncDiagnostic.Level = .info,
      operation: SyncDiagnosticOperation? = nil, outcome: SyncDiagnostic.Outcome? = nil,
      counts: @autoclosure () -> [String: Int] = [:],
      recordTypes: @autoclosure () -> [String] = [],
      failures: [SyncDiagnostic.Failure] = [], finished: Bool = false
    ) {
      guard let diagnosticEmitter, level >= diagnosticEmitter.configuration.minimumLevel else { return }
      let operation = operation ?? SyncDiagnosticContext.operation
      diagnosticEmitter.emit(
        SyncDiagnostic(
          kind: kind, level: level, sessionID: diagnosticEmitter.sessionID,
          operationID: operation?.id, scope: operation?.scope,
          durationSeconds: finished ? operation?.duration : nil, outcome: outcome,
          stage: operation?.stage, counts: counts(), recordTypes: recordTypes(), failures: failures
        )
      )
    }

    func diagnosticFailure(_ error: any Error) {
      guard diagnosticEmitter != nil else { return }
      SyncDiagnosticContext.operation?.increment("errors")
      let failure = SyncDiagnostic.Failure(sanitizing: error)
      emitDiagnostic(
        .operationFailed, level: failure.category == .cancellation ? .info : .error,
        outcome: failure.category == .cancellation ? .cancelled : .failed,
        failures: [failure]
      )
    }

    func reportSyncIssue(
      _ message: @autoclosure () -> String,
      fileID: StaticString = #fileID, filePath: StaticString = #filePath,
      line: UInt = #line, column: UInt = #column
    ) {
      SyncDiagnosticContext.operation?.increment("errors")
      emitDiagnostic(.invariantViolation, level: .error, outcome: .failed,
                     failures: [.init(category: .invariant)])
      reportIssue(message(), fileID: fileID, filePath: filePath, line: line, column: column)
    }

    func withDiagnosticErrorReporting<R>(
      _ message: String? = nil,
      fileID: StaticString = #fileID, filePath: StaticString = #filePath,
      line: UInt = #line, column: UInt = #column,
      catching operation: () throws -> R
    ) -> R? {
      withErrorReporting(message, fileID: fileID, filePath: filePath, line: line, column: column) {
        do { return try operation() }
        catch { diagnosticFailure(error); throw error }
      }
    }

    func withDiagnosticErrorReporting<R>(
      _ message: String? = nil,
      fileID: StaticString = #fileID, filePath: StaticString = #filePath,
      line: UInt = #line, column: UInt = #column,
      catching operation: () async throws -> sending R
    ) async -> R? {
      await withErrorReporting(message, fileID: fileID, filePath: filePath, line: line, column: column) {
        do { return try await operation() }
        catch { diagnosticFailure(error); throw error }
      }
    }

    func diagnoseRequest(
      _ kind: SyncDiagnostic.Kind, operation: () async throws -> Void
    ) async throws {
      guard diagnosticEmitter != nil else { return try await operation() }
      let context = makeDiagnosticOperation(stage: kind)
      try await SyncDiagnosticContext.$operation.withValue(context) {
        emitDiagnostic(kind, outcome: .started)
        do {
          try await operation()
          emitDiagnostic(.requestFinished, outcome: .callbackCompleted, finished: true)
        } catch {
          if context.counts.value["errors", default: 0] == 0 { diagnosticFailure(error) }
          emitDiagnostic(
            .requestFinished, level: error is CancellationError ? .info : .warning,
            outcome: error is CancellationError ? .cancelled : .failed, finished: true
          )
          throw error
        }
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncDiagnostic.Failure {
    init(sanitizing error: any Error) {
      switch error {
      case let error as CKError:
        let requestedDelay = error.retryAfterSeconds
          ?? (error.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
        let retry = requestedDelay.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.init(category: .cloudKit, code: error.code.rawValue,
                  name: error.code.loggingDescription, retryAfterSeconds: retry)
      case let error as DatabaseError:
        self.init(category: .sqlite, code: Int(error.extendedResultCode.rawValue))
      case is CancellationError:
        self.init(category: .cancellation)
      case let error as SyncEngine.FetchCompletionError:
        // Never include the associated error description, record ID or account identity.
        let code: Int
        switch error {
        case .notRunning: code = 1
        case .alreadyFetching: code = 2
        case .accountUnavailable: code = 3
        case .invalidated: code = 4
        case .incomplete: code = 5
        case .localApplicationFailed: code = 6
        case .unappliedRecords: code = 7
        case .invalidRecord: code = 8
        }
        self.init(category: .checkedFetch, code: code)
      case is DecodingError:
        self.init(category: .decoding)
      default:
        // Arbitrary NSError domains/userInfo and error descriptions can contain user data.
        self.init(category: .other)
      }
    }
  }
#endif
