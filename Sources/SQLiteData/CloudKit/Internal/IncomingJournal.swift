#if canImport(CloudKit)
  import CloudKit
  import Foundation
  import GRDB

  /// Latest complete server state per identity. Application and retirement occur in the
  /// same user-file transaction, so a replayed deletion cannot erase a later local recreation.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  struct IncomingJournal: Sendable {
    static let table = "sqlitedata_icloud_incomingJournal"
    static let checkpoints = "sqlitedata_icloud_incomingCheckpoints"
    enum Kind: Int, Sendable { case record, deletion, zoneDeleted, zonePurged, encryptedDataReset }
    let id: CKRecord.ID
    let recordType: String
    let revision: String
    let kind: Kind
    let payload: Data?
    let sequence: Int64

    static func create(in db: Database) throws {
      try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS main.sqlitedata_icloud_incomingConfiguration (
          singleton INTEGER PRIMARY KEY CHECK(singleton = 1), version INTEGER NOT NULL
        ) STRICT;
        INSERT OR IGNORE INTO main.sqlitedata_icloud_incomingConfiguration VALUES (1, 1);
        """)
      let installed = db.changesCount > 0
      guard try Int.fetchOne(db, sql: "SELECT version FROM main.sqlitedata_icloud_incomingConfiguration") == 1
      else { throw IncomingRecoveryError.invalidPayload }
      try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS main.\(checkpoints) (scope INTEGER PRIMARY KEY, data TEXT NOT NULL) STRICT;
        CREATE TABLE IF NOT EXISTS main.\(table) (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT, recordName TEXT NOT NULL,
          zoneName TEXT NOT NULL, ownerName TEXT NOT NULL, recordType TEXT NOT NULL,
          revision TEXT NOT NULL, kind INTEGER NOT NULL, payload BLOB,
          staged INTEGER NOT NULL DEFAULT 1 CHECK(staged IN (0, 1)),
          isZone INTEGER GENERATED ALWAYS AS (kind >= 2) STORED,
          UNIQUE(recordName, zoneName, ownerName, staged, isZone)
        ) STRICT;
        """)
      if installed {
        try db.execute(sql: """
          INSERT INTO main.\(checkpoints) (scope, data)
          SELECT scope, data FROM sqlitedata_icloud_stateSerialization
          """)
      }
    }

    static func capture(
      id: CKRecord.ID, recordType: String, kind: Kind, payload: Data? = nil, staged: Bool = true, db: Database
    ) throws {
      // DELETE/INSERT gives the replacement its own ordering number and unpredictable revision.
      try db.execute(sql: "DELETE FROM main.\(table) WHERE recordName = ? AND zoneName = ? AND ownerName = ? AND staged = ? AND isZone = ?",
                     arguments: [id.recordName, id.zoneID.zoneName, id.zoneID.ownerName, staged, kind.rawValue >= 2])
      try db.execute(sql: """
        INSERT INTO main.\(table) (recordName, zoneName, ownerName, recordType, revision, kind, payload, staged)
        VALUES (?, ?, ?, ?, lower(hex(randomblob(16))), ?, ?, ?)
        """, arguments: [id.recordName, id.zoneID.zoneName, id.zoneID.ownerName, recordType, kind.rawValue, payload, staged])
    }

    static func fetch(_ db: Database) throws -> [Self] {
      try Row.fetchAll(db, sql: "SELECT * FROM main.\(table) WHERE staged = 0 ORDER BY sequence").map { row in
        guard let kind = Kind(rawValue: row["kind"]) else { throw IncomingRecoveryError.invalidPayload }
        return Self(id: CKRecord.ID(recordName: row["recordName"], zoneID: CKRecordZone.ID(
          zoneName: row["zoneName"], ownerName: row["ownerName"])), recordType: row["recordType"],
          revision: row["revision"], kind: kind, payload: row["payload"], sequence: row["sequence"])
      }
    }

    func isCurrent(_ db: Database) throws -> Bool {
      try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM main.\(Self.table) WHERE revision = ?)",
                        arguments: [revision]) == true
    }

    func acknowledge(_ db: Database) throws {
      try db.execute(sql: "DELETE FROM main.\(Self.table) WHERE revision = ?", arguments: [revision])
    }

    static func checkpoint(_ db: Database, scope: CKDatabase.Scope) throws -> CKSyncEngine.State.Serialization? {
      guard let json = try String.fetchOne(db, sql: "SELECT data FROM main.\(checkpoints) WHERE scope = ?",
                                          arguments: [scope.rawValue]) else { return nil }
      return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: Data(json.utf8))
    }

    static func saveCheckpoint(_ data: CKSyncEngine.State.Serialization, scope: CKDatabase.Scope, db: Database) throws {
      let json = String(decoding: try JSONEncoder().encode(data), as: UTF8.self)
      try commitCheckpoint(json, scope: scope, db: db)
    }

    /// A checkpoint and admission of the changes it covers commit in the same SQLite file.
    /// Until this commit, staged changes must not affect app rows: replay from the previous
    /// checkpoint could otherwise repeat an already-applied deletion after local recreation.
    static func commitCheckpoint(_ json: String, scope: CKDatabase.Scope, db: Database) throws {
      let ownerPredicate = scope == .private ? "ownerName = ?" : "ownerName != ?"
      try db.execute(sql: """
        DELETE FROM main.\(table) AS committed WHERE staged = 0 AND EXISTS (
          SELECT 1 FROM main.\(table) AS incoming WHERE incoming.staged = 1
          AND incoming.recordName = committed.recordName AND incoming.zoneName = committed.zoneName
          AND incoming.ownerName = committed.ownerName AND incoming.isZone = committed.isZone
          AND incoming.\(ownerPredicate)
        )
        """, arguments: [CKCurrentUserDefaultName])
      // A confirmed zone deletion supersedes older queued record payloads in that zone.
      try db.execute(sql: """
        DELETE FROM main.\(table) AS older WHERE isZone = 0 AND EXISTS (
          SELECT 1 FROM main.\(table) AS zone WHERE zone.staged = 1 AND zone.kind IN (2, 3)
          AND zone.zoneName = older.zoneName AND zone.ownerName = older.ownerName
          AND zone.sequence > older.sequence AND zone.\(ownerPredicate)
        )
        """, arguments: [CKCurrentUserDefaultName])
      try db.execute(sql: "UPDATE main.\(table) SET staged = 0 WHERE staged = 1 AND \(ownerPredicate)",
                     arguments: [CKCurrentUserDefaultName])
      try db.execute(sql: "INSERT OR REPLACE INTO main.\(checkpoints) VALUES (?, ?)", arguments: [scope.rawValue, json])
    }
  }
#endif
