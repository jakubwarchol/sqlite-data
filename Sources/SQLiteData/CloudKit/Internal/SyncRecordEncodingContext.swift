#if canImport(CloudKit)
  import ConcurrencyExtras

  /// Conversion helpers historically report errors instead of throwing them. Batch preparation
  /// must independently observe those failures even when diagnostics are entirely disabled.
  enum SyncRecordEncodingContext {
    @TaskLocal static var failed: LockIsolated<Bool>?
  }
#endif
