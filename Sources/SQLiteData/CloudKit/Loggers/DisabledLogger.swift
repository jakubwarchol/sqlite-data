#if canImport(CloudKit)
  import CloudKit

  /// A no-op logger implementation that discards all log messages.
  ///
  /// This logger is used when logging is disabled, providing a lightweight
  /// implementation that doesn't perform any actual logging operations.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public struct DisabledLogger: SyncEngineLogger {
    /// Creates a new disabled logger instance.
    public init() {}

    public func log(_ event: SyncEngine.Event, databaseScope: String) {
      // No-op: logging is disabled
    }

    public func debug(_ message: String) {
      // No-op: logging is disabled
    }

    public func info(_ message: String) {
      // No-op: logging is disabled
    }

    public func notice(_ message: String) {
      // No-op: logging is disabled
    }

    public func warning(_ message: String) {
      // No-op: logging is disabled
    }

    public func error(_ message: String) {
      // No-op: logging is disabled
    }

    public func fault(_ message: String) {
      // No-op: logging is disabled
    }
  }
#endif