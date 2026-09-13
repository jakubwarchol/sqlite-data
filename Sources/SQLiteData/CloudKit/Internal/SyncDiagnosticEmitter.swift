#if canImport(CloudKit)
  import ConcurrencyExtras
  import Dispatch
  import Foundation

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  final class SyncDiagnosticEmitter: Sendable {
    let sessionID = UUID()
    let configuration: SyncDiagnostics
    let transfers = LockIsolated<[TransferKey: SyncDiagnosticOperation]>([:])
    private let queue = DispatchQueue(label: "SQLiteData.sync-diagnostics")
    private let state: LockIsolated<State>

    init(_ configuration: SyncDiagnostics) {
      self.configuration = configuration
      state = LockIsolated(State(capacity: min(max(configuration.bufferCapacity, 1), 4096)))
    }

    func emit(_ event: @autoclosure () -> SyncDiagnostic) {
      let event = event()
      guard event.level >= configuration.minimumLevel else { return }
      let schedule = state.withValue { state in
        var event = event
        state.sequence &+= 1
        event.sequence = state.sequence
        guard state.count < state.buffer.count else {
          state.dropped += 1
          return false
        }
        state.buffer[(state.head + state.count) % state.buffer.count] = event
        state.count += 1
        guard !state.draining else { return false }
        state.draining = true
        return true
      }
      if schedule { queue.async { self.drain() } }
    }

    private func drain() {
      while let event = state.withValue({ state -> SyncDiagnostic? in
        if state.count > 0 {
          let event = state.buffer[state.head]
          state.buffer[state.head] = nil
          state.head = (state.head + 1) % state.buffer.count
          state.count -= 1
          return event
        }
        if state.dropped > 0 {
          let dropped = state.dropped
          state.dropped = 0
          state.sequence &+= 1
          // Loss reports are delivered even when the requested threshold is error.
          return SyncDiagnostic(
            kind: .eventsDropped, level: .warning, sessionID: sessionID,
            sequence: state.sequence, counts: ["dropped": dropped]
          )
        }
        state.draining = false
        return nil
      }) {
        configuration.receive(event)
      }
    }

    /// Test barrier only. Call after producers stop; never from a receiving callback.
    func flush() async {
      await withCheckedContinuation { continuation in
        queue.async { continuation.resume() }
      }
    }

    private struct State {
      var buffer: [SyncDiagnostic?]
      var head = 0
      var count = 0
      var sequence: UInt64 = 0
      var dropped = 0
      var draining = false
      init(capacity: Int) { buffer = Array(repeating: nil, count: capacity) }
    }

    struct TransferKey: Hashable {
      var engine: ObjectIdentifier
      var sending: Bool
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  final class SyncDiagnosticOperation: Sendable {
    let id: UUID
    let started = ContinuousClock.now
    let scope: SyncDiagnostic.Scope?
    let stage: SyncDiagnostic.Kind
    let parent: SyncDiagnosticOperation?
    let reportFailure: @Sendable (any Error) -> Void
    let counts = LockIsolated<[String: Int]>([:])

    init(
      scope: SyncDiagnostic.Scope? = nil, stage: SyncDiagnostic.Kind,
      parent: SyncDiagnosticOperation? = nil,
      reportFailure: @escaping @Sendable (any Error) -> Void = { _ in }
    ) {
      self.id = parent?.id ?? UUID()
      self.scope = scope
      self.stage = stage
      self.parent = parent
      self.reportFailure = reportFailure
    }

    func increment(_ key: String, by count: Int = 1) {
      counts.withValue { $0[key, default: 0] += count }
      parent?.increment(key, by: count)
    }

    var duration: Double {
      let value = started.duration(to: .now).components
      return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  enum SyncDiagnosticContext {
    @TaskLocal static var operation: SyncDiagnosticOperation?
  }

  // Record conversion also exists on older OS versions where SyncEngine is unavailable.
  func reportSyncDiagnosticError(_ error: any Error) {
    if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
      SyncDiagnosticContext.operation?.reportFailure(error)
    }
  }
#endif
