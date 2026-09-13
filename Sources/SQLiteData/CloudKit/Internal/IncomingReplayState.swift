#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras

  /// Serializes replay across private and shared callbacks without holding a SQLite transaction
  /// across a network suspension. Work is revalidated against its journal revision before apply.
  actor IncomingReplayGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
      if !occupied { occupied = true; return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
      if waiters.isEmpty { occupied = false }
      else { waiters.removeFirst().resume() }
    }
  }

  enum IncomingApplyContext {
    @TaskLocal static var failure: LockIsolated<(any Error)?>?
  }
#endif
