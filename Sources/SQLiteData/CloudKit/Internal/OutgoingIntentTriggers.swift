#if canImport(CloudKit)
  import CloudKit
  import GRDB
  import Foundation

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension OutgoingIntent {
    static let triggerNames = ["insert", "update", "refresh", "remote_delete"].map { "sqlitedata_icloud_outgoing_\($0)" }

    static func installTriggers(in db: Database) throws {
      // A function only decodes a share's identity. All persistence is SQL in the user transaction.
      db.add(function: DatabaseFunction("sqlitedata_icloud_shareIdentity", argumentCount: 1) { values in
        guard let data = Data.fromDatabaseValue(values[0]),
          let share = CKShare.SystemFieldsRepresentation(queryBinding: .blob(Array(data)))?.queryOutput
        else { return nil }
        return String(data: try JSONSerialization.data(withJSONObject: [
          share.recordID.recordName, share.recordID.zoneID.zoneName, share.recordID.zoneID.ownerName
        ]), encoding: .utf8)
      })
      let fields = ["recordName", "zoneName", "ownerName", "recordPrimaryKey", "recordType",
                    "parentRecordPrimaryKey", "parentRecordType", "lastKnownServerRecord",
                    "_lastKnownServerRecordAllFields", "share", "userModificationTime"]
      let capture = """
        INSERT INTO \(table) (\(fields.joined(separator: ", ")), revision, isDelete)
        VALUES (\(fields.map { "new.\($0)" }.joined(separator: ", ")), lower(hex(randomblob(16))), new._isDeleted)
        ON CONFLICT(recordName, zoneName, ownerName) DO UPDATE SET
          \(fields.dropFirst(3).map { "\($0) = excluded.\($0)" }.joined(separator: ", ")),
          revision = excluded.revision, isDelete = excluded.isDelete, blocked = 0;
        INSERT INTO \(table) (recordName, zoneName, ownerName, revision, isDelete, userModificationTime)
        SELECT json_extract(identity, '$[0]'), json_extract(identity, '$[1]'),
          json_extract(identity, '$[2]'), lower(hex(randomblob(16))), 1, new.userModificationTime
        FROM (SELECT sqlitedata_icloud_shareIdentity(new.share) AS identity)
        WHERE new._isDeleted = 1 AND identity IS NOT NULL
        ON CONFLICT(recordName, zoneName, ownerName) DO UPDATE SET
          revision = excluded.revision, isDelete = 1;
        """
      try db.execute(sql: """
        CREATE TEMP TRIGGER IF NOT EXISTS \(triggerNames[0])
        AFTER INSERT ON sqlitedata_icloud.sqlitedata_icloud_metadata
        WHEN NOT sqlitedata_icloud_syncEngineIsSynchronizingChanges()
        BEGIN \(capture) END
        """)
      // Trigger ordering is unspecified. A zone move must never restore the old zone's CKRecord.
      var captureUpdate = capture
      for field in ["lastKnownServerRecord", "_lastKnownServerRecordAllFields"] {
        captureUpdate = captureUpdate.replacingOccurrences(of: "new.\(field)", with:
          "CASE WHEN old.zoneName != new.zoneName OR old.ownerName != new.ownerName THEN NULL ELSE new.\(field) END")
      }
      try db.execute(sql: """
        CREATE TEMP TRIGGER IF NOT EXISTS \(triggerNames[1])
        AFTER UPDATE ON sqlitedata_icloud.sqlitedata_icloud_metadata
        WHEN NOT sqlitedata_icloud_syncEngineIsSynchronizingChanges()
        BEGIN
          INSERT INTO \(table) (\(fields.joined(separator: ", ")), revision, isDelete)
          SELECT \(fields.map { "old.\($0)" }.joined(separator: ", ")), lower(hex(randomblob(16))), 1
          WHERE old.zoneName != new.zoneName OR old.ownerName != new.ownerName
          ON CONFLICT(recordName, zoneName, ownerName) DO UPDATE SET
            revision = excluded.revision, isDelete = 1;
          \(captureUpdate)
        END
        """)
      try db.execute(sql: """
        CREATE TEMP TRIGGER IF NOT EXISTS \(triggerNames[2])
        AFTER UPDATE ON sqlitedata_icloud.sqlitedata_icloud_metadata
        WHEN sqlitedata_icloud_syncEngineIsSynchronizingChanges()
        BEGIN
          UPDATE \(table) SET
            \(fields.dropFirst(3).map { "\($0) = new.\($0)" }.joined(separator: ", "))
          WHERE recordName = new.recordName AND zoneName = new.zoneName AND ownerName = new.ownerName;
          DELETE FROM \(table) WHERE recordName = new.recordName AND zoneName = new.zoneName
            AND ownerName = new.ownerName AND isDelete = 1 AND old._isDeleted = 1 AND new._isDeleted = 0;
        END
        """)
      // Preserve the existing policy: an applied remote deletion supersedes the local row.
      try db.execute(sql: """
        CREATE TEMP TRIGGER IF NOT EXISTS \(triggerNames[3])
        AFTER DELETE ON sqlitedata_icloud.sqlitedata_icloud_metadata
        WHEN sqlitedata_icloud_syncEngineIsSynchronizingChanges()
        BEGIN
          DELETE FROM \(table) WHERE recordName = old.recordName AND zoneName = old.zoneName
            AND ownerName = old.ownerName;
        END
        """)
    }
  }
#endif
