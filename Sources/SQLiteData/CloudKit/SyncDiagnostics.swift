#if canImport(CloudKit)
  public import Foundation
  import ConcurrencyExtras

  /// An optional, per-engine diagnostic destination. Events are available in release builds.
  ///
  /// Delivery is serial on a dedicated queue, outside database and engine locks. The receiver
  /// must return promptly and must not synchronously wait for more diagnostics. The bounded
  /// queue drops new events when full and reports the loss once it catches up. Diagnostics
  /// are observational, not a durable journal or a receipt that all devices are synchronized.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public final class SyncDiagnostics: Sendable {
    private let level: LockIsolated<SyncDiagnostic.Level>
    /// May be changed while the engine runs. Already queued events retain their delivery.
    public var minimumLevel: SyncDiagnostic.Level {
      get { level.value }
      set { level.withValue { $0 = newValue } }
    }
    public let bufferCapacity: Int
    public let receive: @Sendable (SyncDiagnostic) -> Void

    public init(
      minimumLevel: SyncDiagnostic.Level = .info,
      bufferCapacity: Int = 256,
      receive: @escaping @Sendable (SyncDiagnostic) -> Void
    ) {
      self.level = LockIsolated(minimumLevel)
      self.bufferCapacity = min(max(bufferCapacity, 1), 4096)
      self.receive = receive
    }
  }

  /// A sanitized snapshot. It contains no record contents, identifiers, paths or raw errors.
  ///
  /// Sequence numbers describe emission within this engine instance; gaps indicate filtering
  /// or overflow. Operation IDs correlate observed work, not CloudKit record revisions.
  /// `callbackCompleted` is deliberately distinct from local application or server acceptance.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public struct SyncDiagnostic: Sendable, Codable, Equatable {
    public enum Level: Int, Sendable, Codable, Comparable {
      case debug, info, warning, error
      public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Kind: String, Sendable, Codable {
      case startupStarted, startupFinished, stopRequested, stopReturned, drainWaiting, drainFinished, accountChanged
      case fetchStarted, fetchFinished, zoneFetchStarted, zoneFetchFinished
      case changesReceived, incomingStaged, applicationFinished, statePersisted
      case sendStarted, sendFinished, batchPrepared, uploadResults, zoneUploadResults
      case retryEnqueued, operationFailed, invariantViolation, eventsDropped
      case fetchRequested, sendRequested, checkedFetchRequested, requestFinished
    }

    public enum Scope: String, Sendable, Codable { case `private`, shared, `public` }
    public enum Outcome: String, Sendable, Codable {
      case started, callbackCompleted, applied, accepted, partial, failed, cancelled
      case deferred, skipped, prepared, unavailable, retained
    }

    public struct Failure: Sendable, Codable, Equatable, Hashable {
      public enum Category: String, Sendable, Codable {
        case cloudKit, sqlite, cancellation, checkedFetch, decoding, other, invariant
      }
      public var category: Category
      public var code: Int?
      public var name: String?
      public var retryAfterSeconds: Double?

      public init(category: Category, code: Int? = nil, name: String? = nil, retryAfterSeconds: Double? = nil) {
        self.category = category
        self.code = code
        self.name = name
        self.retryAfterSeconds = retryAfterSeconds
      }
    }

    public var kind: Kind
    public var level: Level
    public var sessionID: UUID
    public var operationID: UUID?
    public var scope: Scope?
    public var sequence: UInt64
    public var timestamp: Date
    public var durationSeconds: Double?
    public var outcome: Outcome?
    public var stage: Kind?
    /// Fixed library-defined keys and aggregate values, never row values.
    public var counts: [String: Int]
    /// At most 16 registered type names, truncated to 96 characters each.
    public var recordTypes: [String]
    /// At most eight distinct sanitized errors. Counts retain the full failure total.
    public var failures: [Failure]

    public init(
      kind: Kind, level: Level, sessionID: UUID, operationID: UUID? = nil,
      scope: Scope? = nil, sequence: UInt64 = 0, timestamp: Date = Date(),
      durationSeconds: Double? = nil, outcome: Outcome? = nil, stage: Kind? = nil,
      counts: [String: Int] = [:], recordTypes: [String] = [], failures: [Failure] = []
    ) {
      self.kind = kind
      self.level = level
      self.sessionID = sessionID
      self.operationID = operationID
      self.scope = scope
      self.sequence = sequence
      self.timestamp = timestamp
      self.durationSeconds = durationSeconds
      self.outcome = outcome
      self.stage = stage
      self.counts = counts
      self.recordTypes = Array(recordTypes.prefix(16)).map { String($0.prefix(96)) }
      self.failures = Array(failures.prefix(8))
    }
  }
#endif
