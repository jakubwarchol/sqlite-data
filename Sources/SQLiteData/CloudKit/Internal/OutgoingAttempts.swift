#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import GRDB

  /// Receipts are internal bookkeeping, never a public upload-acknowledgement API.
  /// Overlapping attempts for an identity are ambiguous: retain intent and retry, rather than
  /// guess which local revision a callback acknowledges. A restart also retains all intent.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  final class OutgoingAttempts: Sendable {
    struct Key: Hashable {
      var engine: ObjectIdentifier
      var recordID: CKRecord.ID
      var isDelete: Bool
    }
    struct Receipt {
      var intent: OutgoingIntent
      var covered: [OutgoingIntent]
      func acknowledge(_ db: Database) throws {
        try intent.acknowledge(db)
        for child in covered { try child.acknowledge(db) }
      }
    }
    struct Attempt {
      var intent: OutgoingIntent
      var covered: [OutgoingIntent] = []
      var count = 1
      var ambiguous = false
    }
    private let storage = LockIsolated<[Key: Attempt]>([:])
    private let coverage = LockIsolated<[Key: [OutgoingIntent]]>([:])

    func cover(_ intent: OutgoingIntent, by shareID: CKRecord.ID, engine: any SyncEngineProtocol) {
      let key = Key(engine: ObjectIdentifier(engine), recordID: shareID, isDelete: true)
      coverage.withValue { $0[key, default: []].append(intent) }
    }

    func prepared(_ intent: OutgoingIntent, engine: any SyncEngineProtocol) {
      storage.withValue {
        let key = Key(engine: ObjectIdentifier(engine), recordID: intent.recordID, isDelete: intent.isDelete)
        if var attempt = $0[key] {
          attempt.count += 1
          attempt.ambiguous = true
          $0[key] = attempt
        } else {
          $0[key] = Attempt(intent: intent, covered: coverage.withValue { $0.removeValue(forKey: key) ?? [] })
        }
      }
    }

    func completed(_ id: CKRecord.ID, isDelete: Bool, engine: any SyncEngineProtocol) -> Receipt? {
      storage.withValue {
        let key = Key(engine: ObjectIdentifier(engine), recordID: id, isDelete: isDelete)
        guard var attempt = $0.removeValue(forKey: key) else { return nil }
        attempt.count -= 1
        if attempt.count > 0 { $0[key] = attempt }
        return attempt.ambiguous ? nil : Receipt(intent: attempt.intent, covered: attempt.covered)
      }
    }

    func clear() {
      storage.withValue { $0.removeAll() }
      coverage.withValue { $0.removeAll() }
    }

    func finish(engine: any SyncEngineProtocol) {
      storage.withValue { $0 = $0.filter { $0.key.engine != ObjectIdentifier(engine) } }
      coverage.withValue { $0 = $0.filter { $0.key.engine != ObjectIdentifier(engine) } }
    }
  }
#endif
