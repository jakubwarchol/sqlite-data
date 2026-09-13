import CloudKit
import Darwin
import Dependencies
import Foundation
import GRDB
import SQLiteData

@Table("outgoingProbe")
struct Probe {
  @Column(primaryKey: true) var id: String
  var title: String
}

/// Invoked only by test-outgoing-durability.py with an isolated temporary directory.
/// The test dependency context guarantees the public initializer uses mock CloudKit.
@main
struct OutgoingIntentCrashProbe {
  static func main() async throws {
    if #available(macOS 14, *) { try await run() }
    else { fatalError("Requires macOS 14") }
  }
  @available(macOS 14, *)
  static func run() async throws {
    guard CommandLine.arguments.count == 4 else { fatalError("Expected phase, operation, directory") }
    let phase = CommandLine.arguments[1]
    let operation = CommandLine.arguments[2]
    let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    guard directory.lastPathComponent.hasPrefix("SQLiteDataOutgoingCrash-") else {
      fatalError("Refusing a non-probe directory")
    }
    try await withDependencies { $0.context = .test } operation: {
      var configuration = Configuration()
      configuration.prepareDatabase { db in
        try db.execute(sql: "PRAGMA journal_mode = WAL")
        try db.attachMetadatabase(containerIdentifier: "iCloud.SQLiteData.OutgoingCrashProbe")
      }
      let database = try DatabaseQueue(path: directory.appendingPathComponent("user.sqlite").path,
                                       configuration: configuration)
      try await database.write { db in
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS outgoingProbe (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL)")
      }
      let engine = try SyncEngine(for: database, tables: Probe.self,
        containerIdentifier: "iCloud.SQLiteData.OutgoingCrashProbe", startImmediately: false)
      if phase == "crash" {
        try await engine.start()
        try await database.write { db in
          try db.execute(sql: "INSERT INTO outgoingProbe VALUES ('existing', 'baseline')")
        }
        try await engine.sendChanges()
        if operation.hasPrefix("stopped-") { engine.stop() }
        try await database.writeWithoutTransaction { db in
          try db.inTransaction {
            switch operation.split(separator: "-").last! {
            case "insert": try db.execute(sql: "INSERT INTO outgoingProbe VALUES ('inserted', 'committed')")
            case "update": try db.execute(sql: "UPDATE outgoingProbe SET title = 'committed' WHERE id = 'existing'")
            case "delete": try db.execute(sql: "DELETE FROM outgoingProbe WHERE id = 'existing'")
            default: fatalError("Unknown operation")
            }
            if operation.hasPrefix("rollback-") { return .rollback }
            return .commit
          }
          // Stay on the occupied writer queue: no scheduled follow-up can flush anything.
          _exit(73)
        }
      } else if phase == "accepted" {
        try await engine.start()
        try await database.write { db in
          try db.execute(sql: "INSERT INTO outgoingProbe VALUES ('existing', 'committed')")
        }
        try await engine.processPendingDatabaseChanges(scope: .private)
        _ = try await engine.sendPendingRecordZoneChanges(scope: .private)
        _ = try engine.private.database.record(for: .init(recordName: "existing:outgoingProbe", zoneID: engine.defaultZone.zoneID))
        // Mock server accepted, but SQLiteData has not received the success callback.
        _exit(73)
      } else if phase == "verify" {
        let rows = try await database.read { db in
          try Row.fetchAll(db, sql: "SELECT recordName, revision, isDelete FROM main.sqlitedata_icloud_outgoingIntents")
            .map { (revision: $0["revision"] as String, isDelete: $0["isDelete"] as Bool) }
        }
        let expected = operation.hasPrefix("rollback-") ? 0 : 1
        precondition(rows.count == expected, "Committed intent did not survive: \(rows.count)")
        if expected == 1 {
          let revision = rows[0].revision
          let isDelete = rows[0].isDelete
          precondition(isDelete == operation.hasSuffix("delete"))
          try await engine.start()
          let after = try await database.read { db in
            try String.fetchOne(db, sql: "SELECT revision FROM main.sqlitedata_icloud_outgoingIntents")
          }
          precondition(after == revision, "Startup changed or discarded a pending revision")
          // A fresh mock server may need an unknown-item retry for a previously uploaded edit.
          for _ in 0..<3 { try await engine.sendChanges() }
          let remaining = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM main.sqlitedata_icloud_outgoingIntents")
          }
          precondition(remaining == 0, "Replay did not acknowledge intent")
          if !isDelete {
            let id = operation.hasSuffix("insert") ? "inserted" : "existing"
            let recordID = CKRecord.ID(recordName: "\(id):outgoingProbe", zoneID: engine.defaultZone.zoneID)
            let record = try engine.private.database.record(for: recordID)
            precondition(record.encryptedValues["title"] as? String == "committed")
          }
        }
        engine.stop()
        print("PASS \(operation)")
      } else { fatalError("Unknown phase") }
    }
  }
}
