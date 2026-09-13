#if canImport(CloudKit)
  import CloudKit
  import GRDB

  /// Check inside the recovery write, after any network suspension. An old failure must not
  /// revive a newer deletion or overwrite a newer edit. Missing/ambiguous receipts cannot
  /// authorize recovery while any local intent remains pending for this identity.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  struct OutgoingFailureGuard: Sendable {
    let recordID: CKRecord.ID
    let revision: String?

    func allowsRecovery(_ db: Database) throws -> Bool {
      let current = try String.fetchOne(db, sql: """
        SELECT revision FROM main.\(OutgoingIntent.table)
        WHERE recordName = ? AND zoneName = ? AND ownerName = ?
        """, arguments: [recordID.recordName, recordID.zoneID.zoneName, recordID.zoneID.ownerName])
      return current == revision
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  struct OutgoingFailureGuards: Sendable {
    var saves: [CKRecord.ID: OutgoingFailureGuard] = [:]
    var deletes: [CKRecord.ID: OutgoingFailureGuard] = [:]
  }
#endif
