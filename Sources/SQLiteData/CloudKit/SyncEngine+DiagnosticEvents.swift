#if canImport(CloudKit)
  import CloudKit
  import Foundation

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    func diagnoseEvent(
      _ event: Event, engine: any SyncEngineProtocol, operation: () async -> Void
    ) async {
      guard let emitter = diagnosticEmitter else { return await operation() }
      let scope: SyncDiagnostic.Scope = switch engine.database.databaseScope {
      case .shared: .shared
      case .public: .public
      default: .private
      }
      let sending: Bool
      switch event {
      case .willSendChanges, .didSendChanges, .sentRecordZoneChanges, .sentDatabaseChanges:
        sending = true
      default: sending = false
      }
      let key = SyncDiagnosticEmitter.TransferKey(engine: ObjectIdentifier(engine), sending: sending)
      let starts: Bool
      let ends: Bool
      switch event {
      case .willFetchChanges, .willSendChanges: starts = true; ends = false
      case .didFetchChanges, .didSendChanges: starts = false; ends = true
      default: starts = false; ends = false
      }
      let parent = emitter.transfers.withValue { transfers in
        if starts {
          // Retain at most four pairs of engine generations, including late callbacks.
          if transfers.count >= 8, let oldest = transfers.min(by: { $0.value.started < $1.value.started }) {
            transfers[oldest.key] = nil
          }
          transfers[key] = makeDiagnosticOperation(
            scope: scope, stage: sending ? .sendStarted : .fetchStarted
          )
        }
        // State/account events are not evidence that either transfer made progress.
        switch event {
        case .stateUpdate, .accountChange: return nil as SyncDiagnosticOperation?
        default: return transfers[key]
        }
      }
      let context = (starts || ends) ? parent ?? makeDiagnosticOperation(scope: scope, stage: stage(event))
        : makeDiagnosticOperation(scope: scope, stage: stage(event), parent: parent)
      await SyncDiagnosticContext.$operation.withValue(context) {
        diagnosticEventReceived(event)
        await operation()
        diagnosticEventFinished(event, context: context)
      }
      if ends {
        emitter.transfers.withValue {
          if $0[key] === parent { $0[key] = nil }
        }
      }
    }

    private func stage(_ event: Event) -> SyncDiagnostic.Kind {
      switch event {
      case .stateUpdate: .statePersisted
      case .accountChange: .accountChanged
      case .fetchedDatabaseChanges, .fetchedRecordZoneChanges: .incomingStaged
      case .sentDatabaseChanges: .zoneUploadResults
      case .sentRecordZoneChanges: .uploadResults
      case .willFetchChanges, .didFetchChanges: .fetchStarted
      case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges: .zoneFetchFinished
      case .willSendChanges, .didSendChanges: .sendStarted
      @unknown default: .invariantViolation
      }
    }

    private func diagnosticEventReceived(_ event: Event) {
      switch event {
      case .willFetchChanges: emitDiagnostic(.fetchStarted, outcome: .started)
      case .willSendChanges: emitDiagnostic(.sendStarted, outcome: .started)
      case .willFetchRecordZoneChanges:
        emitDiagnostic(.zoneFetchStarted, level: .debug, outcome: .started)
      case .accountChange(let change):
        let counts: [String: Int] = switch change {
        case .signIn: ["signedIn": 1]
        case .signOut: ["signedOut": 1]
        case .switchAccounts: ["switchedAccounts": 1]
        @unknown default: ["unknownChange": 1]
        }
        emitDiagnostic(.accountChanged, counts: counts)
      case .fetchedDatabaseChanges(let modifications, let deletions):
        SyncDiagnosticContext.operation?.increment("receivedModifiedZones", by: modifications.count)
        SyncDiagnosticContext.operation?.increment("receivedDeletedZones", by: deletions.count)
        emitDiagnostic(.changesReceived, level: .debug,
                       counts: ["modifiedZones": modifications.count, "deletedZones": deletions.count])
      case .fetchedRecordZoneChanges(let modifications, let deletions):
        SyncDiagnosticContext.operation?.increment("receivedModifications", by: modifications.count)
        SyncDiagnosticContext.operation?.increment("receivedDeletions", by: deletions.count)
        emitDiagnostic(
          .changesReceived, level: .debug,
          counts: ["modifications": modifications.count, "deletions": deletions.count],
          recordTypes: diagnosticRecordTypes(modifications.map(\.recordType) + deletions.map(\.recordType))
        )
      case .sentRecordZoneChanges(let saved, let failed, let deleted, let failedDeletes):
        uploadDiagnostic(
          .uploadResults, saved: saved.count, deleted: deleted.count,
          saveErrors: failed.map(\.error), deleteErrors: Array(failedDeletes.values),
          types: diagnosticRecordTypes(saved.map(\.recordType) + failed.map { $0.record.recordType })
        )
      case .sentDatabaseChanges(let saved, let failed, let deleted, let failedDeletes):
        uploadDiagnostic(
          .zoneUploadResults, saved: saved.count, deleted: deleted.count,
          saveErrors: failed.map(\.error), deleteErrors: Array(failedDeletes.values), types: []
        )
      case .didFetchRecordZoneChanges(_, let error):
        if let error { diagnosticFailure(error) }
        emitDiagnostic(
          .zoneFetchFinished, level: error == nil ? .debug : .warning,
          outcome: error == nil ? .callbackCompleted : .failed
        )
      default: break
      }
    }

    private func diagnosticEventFinished(_ event: Event, context: SyncDiagnosticOperation) {
      let counts = context.counts.value
      let failed = counts["errors", default: 0] > 0
      switch event {
      case .fetchedDatabaseChanges, .fetchedRecordZoneChanges:
        let types: [String]
        if case .fetchedRecordZoneChanges(let modifications, let deletions) = event {
          types = diagnosticRecordTypes(modifications.map(\.recordType) + deletions.map(\.recordType))
        } else {
          types = []
        }
        emitDiagnostic(
          .incomingStaged, level: failed ? .warning : .debug,
          outcome: counts["captureFailed", default: 0] > 0 ? .failed : .retained,
          counts: counts, recordTypes: types, finished: true
        )
      case .stateUpdate:
        let persisted = counts["checkpointCommitted", default: 0] > 0
        emitDiagnostic(.statePersisted, level: persisted ? .debug : .error,
                       outcome: persisted ? .applied : .failed, counts: counts, finished: true)
      case .didFetchChanges, .didSendChanges:
        let sending: Bool = if case .didSendChanges = event { true } else { false }
        let partial = counts["deliveryFailures", default: 0] > 0
        emitDiagnostic(
          sending ? .sendFinished : .fetchFinished, level: failed || partial ? .warning : .info,
          outcome: failed ? .failed : partial ? .partial : .callbackCompleted,
          counts: counts, finished: true
        )
      default: break
      }
    }

    private func uploadDiagnostic(
      _ kind: SyncDiagnostic.Kind, saved: Int, deleted: Int,
      saveErrors: [CKError], deleteErrors: [CKError], types: [String]
    ) {
      let failureCount = saveErrors.count + deleteErrors.count
      SyncDiagnosticContext.operation?.increment("deliveryFailures", by: failureCount)
      SyncDiagnosticContext.operation?.increment("acceptedSaveResults", by: saved)
      SyncDiagnosticContext.operation?.increment("acceptedDeleteResults", by: deleted)
      var samples: [SyncDiagnostic.Failure] = []
      for error in saveErrors + deleteErrors {
        let failure = SyncDiagnostic.Failure(sanitizing: error)
        if samples.count < 8 && !samples.contains(failure) { samples.append(failure) }
      }
      emitDiagnostic(
        kind, level: failureCount == 0 ? .info : .warning,
        outcome: failureCount == 0 ? .accepted : saved + deleted > 0 ? .partial : .failed,
        counts: ["saved": saved, "deleted": deleted, "failedSaves": saveErrors.count,
                 "failedDeletes": deleteErrors.count], recordTypes: types, failures: samples
      )
    }

    func diagnosticRecordTypes(_ types: [String]) -> [String] {
      Array(Set(types.filter { tablesByName[$0] != nil }).sorted().prefix(16))
    }
  }
#endif
