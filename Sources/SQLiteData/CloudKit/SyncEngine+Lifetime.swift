#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Foundation

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    public enum LifetimeError: Error {
      /// Awaiting one's own retirement would deadlock. Request stop from the callback,
      /// and await stopAndDrain from the resource owner after returning from the callback.
      case reentrantDrain
      case draining
    }

    /// Retires this generation and waits for owned operations and database writes to finish.
    /// Late CloudKit callbacks are rejected. Local tracking remains installed for offline edits.
    /// Cancellation of a waiting caller does not withdraw the retirement request.
    /// Do not invoke this method from a sync delegate or another in-progress engine operation.
    public func stopAndDrain() async throws {
      guard SyncWorkContext.token?.tracker !== workTracker else { throw LifetimeError.reentrantDrain }
      stop()
      await retirementTask.value?.value
    }

    func withSyncWork<R: Sendable>(_ operation: () async throws -> R) async throws -> R {
      let inherited = SyncWorkContext.token.flatMap { $0.tracker === workTracker ? $0 : nil }
      let lease = try workTracker.begin(expected: inherited)
      defer { lease.finish() }
      return try await SyncWorkContext.$token.withValue(lease.token) {
        try await operation()
      }
    }

    func acceptsCallback(from engine: any SyncEngineProtocol) -> Bool {
      if let token = SyncWorkContext.token, token.tracker === workTracker {
        return (try? token.check()) != nil
      }
      return syncEngines.withValue { $0.private === engine || $0.shared === engine }
    }

    /// Called while holding startStopLock, after removing the engines from public state.
    func retire(_ engines: SyncEngines) {
      workTracker.retire()
      let startup = startTask.value
      startup?.cancel()
      retirementTask.withValue { task in
        task = Task { [workTracker] in
          await SyncWorkContext.$token.withValue(nil) {
            await startup?.value
            async let privateCancellation: Void = engines.private?.cancelOperations() ?? ()
            async let sharedCancellation: Void = engines.shared?.cancelOperations() ?? ()
            _ = await (privateCancellation, sharedCancellation)
            await workTracker.waitUntilDrained { count in
              emitDiagnostic(.drainWaiting, counts: ["operations": count])
            }
            emitDiagnostic(.drainFinished, outcome: .callbackCompleted)
          }
          startStopLock.withLock { isDraining.withValue { $0 = false } }
        }
      }
    }
  }

  /// Each live engine keeps the generation it was constructed for, including callbacks
  /// issued before the pair of private/shared engines has been published by the owner.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  final class SyncSessionDelegate: CKSyncEngineDelegate, Sendable {
    private let reference = IsolatedWeakVar<SyncEngine>()
    var owner: SyncEngine? { reference.value }
    let token: SyncWorkTracker.Token
    init(owner: SyncEngine) {
      reference.set(owner)
      self.token = owner.workTracker.token
    }
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
      await SyncWorkContext.$token.withValue(token) {
        await owner?.handleEvent(event, syncEngine: syncEngine)
      }
    }
    func nextRecordZoneChangeBatch(
      _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
      await SyncWorkContext.$token.withValue(token) {
        await owner?.nextRecordZoneChangeBatch(context, syncEngine: syncEngine)
      }
    }
  }
#endif
