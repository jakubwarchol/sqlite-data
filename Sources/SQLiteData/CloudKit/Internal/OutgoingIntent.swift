#if canImport(CloudKit)
  import CloudKit
  import GRDB
  import Foundation

  /// Latest desired operation for an identity. Stored in the user's database, not the sidecar.
  /// A random revision prevents ABA after delete/reinsert and survives engine replacement.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  struct OutgoingIntent: Sendable {
    static let table = "sqlitedata_icloud_outgoingIntents"
    let recordID: CKRecord.ID
    let revision: String
    let isDelete: Bool
    var blocked = false

    var change: CKSyncEngine.PendingRecordZoneChange {
      isDelete ? .deleteRecord(recordID) : .saveRecord(recordID)
    }

    static func fetch(_ db: Database) throws -> [Self] {
      try Row.fetchAll(db, sql: "SELECT recordName, zoneName, ownerName, revision, isDelete, blocked FROM main.\(table)")
        .map { row in
          Self(recordID: CKRecord.ID(recordName: row["recordName"], zoneID: .init(
            zoneName: row["zoneName"], ownerName: row["ownerName"])),
            revision: row["revision"], isDelete: row["isDelete"], blocked: row["blocked"])
        }
    }

    static func revision(_ db: Database, for id: CKRecord.ID, isDelete: Bool) throws -> String? {
      try String.fetchOne(db, sql: """
        SELECT revision FROM main.\(table)
        WHERE recordName = ? AND zoneName = ? AND ownerName = ? AND isDelete = ?
        """, arguments: [id.recordName, id.zoneID.zoneName, id.zoneID.ownerName, isDelete])
    }

    func acknowledge(_ db: Database) throws {
      try db.execute(sql: """
        DELETE FROM main.\(Self.table)
        WHERE recordName = ? AND zoneName = ? AND ownerName = ? AND revision = ?
        """, arguments: [recordID.recordName, recordID.zoneID.zoneName, recordID.zoneID.ownerName, revision])
      if db.changesCount > 0 && isDelete {
        // An older delete must never remove the metadata of a recreated row.
        try db.execute(sql: """
          DELETE FROM sqlitedata_icloud_metadata
          WHERE recordName = ? AND zoneName = ? AND ownerName = ? AND _isDeleted = 1
          """, arguments: [recordID.recordName, recordID.zoneID.zoneName, recordID.zoneID.ownerName])
      }
    }

    static func create(in db: Database, containerIdentifier: String? = nil) throws {
      try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS main.sqlitedata_icloud_outgoingConfiguration (
          singleton INTEGER PRIMARY KEY CHECK(singleton = 1), version INTEGER NOT NULL,
          containerIdentifier TEXT NOT NULL
        ) STRICT;
        INSERT OR IGNORE INTO main.sqlitedata_icloud_outgoingConfiguration VALUES (1, 1, ?)
        """, arguments: [containerIdentifier ?? ""])
      let config = try Row.fetchOne(db, sql: "SELECT * FROM main.sqlitedata_icloud_outgoingConfiguration")!
      guard config["version"] as Int == 1, config["containerIdentifier"] as String == (containerIdentifier ?? "") else {
        throw ConfigurationMismatch()
      }
      try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS main.\(table) (
          recordName TEXT NOT NULL, zoneName TEXT NOT NULL, ownerName TEXT NOT NULL,
          revision TEXT NOT NULL, isDelete INTEGER NOT NULL CHECK(isDelete IN (0, 1)),
          blocked INTEGER NOT NULL DEFAULT 0,
          recordPrimaryKey TEXT, recordType TEXT,
          parentRecordPrimaryKey TEXT, parentRecordType TEXT,
          lastKnownServerRecord BLOB, _lastKnownServerRecordAllFields BLOB, share BLOB,
          userModificationTime INTEGER NOT NULL,
          PRIMARY KEY(recordName, zoneName, ownerName)
        ) STRICT
        """)
    }

    struct ConfigurationMismatch: Error {}

    /// Restore the metadata needed to encode pending user values with their original clocks.
    /// Do not let an old-zone tombstone replace the metadata of the identity's new zone.
    static func restoreMetadata(in db: Database) throws {
      try db.execute(sql: """
        INSERT INTO sqlitedata_icloud_metadata
          (recordPrimaryKey, recordType, zoneName, ownerName, parentRecordPrimaryKey,
           parentRecordType, lastKnownServerRecord, _lastKnownServerRecordAllFields,
           share, userModificationTime, _isDeleted)
        SELECT recordPrimaryKey, recordType, zoneName, ownerName, parentRecordPrimaryKey,
          parentRecordType, lastKnownServerRecord, _lastKnownServerRecordAllFields,
          share, userModificationTime, isDelete
        FROM main.\(table) AS intent
        WHERE recordPrimaryKey IS NOT NULL AND (isDelete = 0 OR NOT EXISTS (
          SELECT 1 FROM sqlitedata_icloud_metadata AS metadata
          WHERE metadata.recordName = intent.recordName
        ) AND NOT EXISTS (
          SELECT 1 FROM main.\(table) AS saving
          WHERE saving.recordName = intent.recordName AND saving.isDelete = 0
        ))
        ON CONFLICT(recordPrimaryKey, recordType) DO UPDATE SET
          zoneName = excluded.zoneName, ownerName = excluded.ownerName,
          parentRecordPrimaryKey = excluded.parentRecordPrimaryKey,
          parentRecordType = excluded.parentRecordType,
          lastKnownServerRecord = excluded.lastKnownServerRecord,
          _lastKnownServerRecordAllFields = excluded._lastKnownServerRecordAllFields,
          share = excluded.share, userModificationTime = excluded.userModificationTime,
          _isDeleted = excluded._isDeleted
        """)
    }

    /// Adopt a legacy serialized pending change without replacing a newer captured intent.
    static func adopt(_ change: CKSyncEngine.PendingRecordZoneChange, db: Database) throws {
      let id: CKRecord.ID
      let isDelete: Bool
    var blocked = false
      switch change {
      case .saveRecord(let value): id = value; isDelete = false
      case .deleteRecord(let value): id = value; isDelete = true
      @unknown default: return
      }
      try db.execute(sql: """
        INSERT OR IGNORE INTO main.\(table)
          (recordName, zoneName, ownerName, revision, isDelete, recordPrimaryKey, recordType,
           parentRecordPrimaryKey, parentRecordType, lastKnownServerRecord,
           _lastKnownServerRecordAllFields, share, userModificationTime)
        SELECT ?, ?, ?, lower(hex(randomblob(16))), ?, metadata.recordPrimaryKey, metadata.recordType,
          metadata.parentRecordPrimaryKey, metadata.parentRecordType, metadata.lastKnownServerRecord,
          metadata._lastKnownServerRecordAllFields, metadata.share, coalesce(metadata.userModificationTime, 0)
        FROM (SELECT 1) LEFT JOIN sqlitedata_icloud_metadata AS metadata
          ON metadata.recordName = ? AND metadata.zoneName = ? AND metadata.ownerName = ?
        """, arguments: [id.recordName, id.zoneID.zoneName, id.zoneID.ownerName, isDelete,
                          id.recordName, id.zoneID.zoneName, id.zoneID.ownerName])
    }
  }
#endif
