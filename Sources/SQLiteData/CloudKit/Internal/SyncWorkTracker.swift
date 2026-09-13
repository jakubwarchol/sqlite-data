#if canImport(CloudKit)
  import ConcurrencyExtras
  import Foundation

  /// A generation is retired before cancellation starts. Leases span complete async operations,
  /// including suspension and their final database commit. New callbacks from retired engines
  /// cannot acquire a lease, even if CloudKit delivers them after cancelOperations returns.
  final class SyncWorkTracker: Sendable {
    struct Token: Sendable {
      let tracker: SyncWorkTracker
      let generation: UInt64
      func check() throws {
        guard tracker.state.withValue({ $0.accepting && $0.generation == generation })
        else { throw CancellationError() }
      }
    }

    struct Lease: Sendable {
      let token: Token
      let id: UUID
      func finish() { token.tracker.finish(id) }
    }

    private struct State {
      var generation: UInt64 = 0
      var accepting = false
      var leases: Set<UUID> = []
      var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = LockIsolated(State())

    var token: Token { state.withValue { Token(tracker: self, generation: $0.generation) } }

    func activate() {
      state.withValue {
        precondition($0.leases.isEmpty, "A new generation requires a drained predecessor")
        $0.generation &+= 1
        $0.accepting = true
      }
    }

    func begin(expected: Token? = nil) throws -> Lease {
      try state.withValue {
        guard $0.accepting,
          expected == nil || (expected?.tracker === self && expected?.generation == $0.generation)
        else { throw CancellationError() }
        let id = UUID()
        $0.leases.insert(id)
        return Lease(token: Token(tracker: self, generation: $0.generation), id: id)
      }
    }

    func retire() { state.withValue { $0.accepting = false } }

    func waitUntilDrained(onWaiting: @Sendable (Int) -> Void = { _ in }) async {
      await withCheckedContinuation { continuation in
        let count = state.withValue {
          if $0.leases.isEmpty { return 0 }
          $0.waiters.append(continuation)
          return $0.leases.count
        }
        if count == 0 { continuation.resume() }
        else { onWaiting(count) }
      }
    }

    private func finish(_ id: UUID) {
      let waiters = state.withValue {
        $0.leases.remove(id)
        guard $0.leases.isEmpty else { return [CheckedContinuation<Void, Never>]() }
        defer { $0.waiters.removeAll() }
        return $0.waiters
      }
      for waiter in waiters { waiter.resume() }
    }
  }

  enum SyncWorkContext {
    @TaskLocal static var token: SyncWorkTracker.Token?
  }
#endif
