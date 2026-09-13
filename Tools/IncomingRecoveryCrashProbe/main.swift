import CloudKit
import CryptoKit
import Darwin
import Dependencies
import Foundation
import GRDB
import SQLiteData

@Table("incomingProbe")
struct IncomingProbe {
  @Column(primaryKey: true) var id: String
  var title: String
  var payload: Data
}

struct ProbeFiles: DataManager {
  let temporaryDirectory: URL
  func load(_ url: URL) throws -> Data { try Data(contentsOf: url) }
  func save(_ data: Data, to url: URL) throws { try data.write(to: url) }
  func sha256(of url: URL) -> Data? { (try? load(url)).map { Data(SHA256.hash(data: $0)) } }
}

/// Isolated mock-CloudKit subprocess fixture. Never accepts an application database directory.
@main
struct IncomingRecoveryCrashProbe {
  static func main() async throws {
    guard #available(macOS 14, *) else { fatalError("Requires macOS 14") }
    guard CommandLine.arguments.count == 4 else { fatalError("Expected phase, scenario, directory") }
    let phase = CommandLine.arguments[1], scenario = CommandLine.arguments[2]
    let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    precondition(directory.lastPathComponent.hasPrefix("SQLiteDataIncomingCrash-"))
    try await withDependencies {
      $0.context = .test
      $0.dataManager = ProbeFiles(temporaryDirectory: directory)
    } operation: {
      let containerID = "iCloud.SQLiteData.IncomingCrashProbe"
      var configuration = Configuration()
      configuration.prepareDatabase { db in
        try db.execute(sql: "PRAGMA journal_mode = WAL")
        try db.attachMetadatabase(containerIdentifier: containerID)
      }
      let database = try DatabaseQueue(path: directory.appendingPathComponent("user.sqlite").path,
                                       configuration: configuration)
      try await database.write { db in
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS incomingProbe (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, payload BLOB NOT NULL)")
      }
      let engine = try SyncEngine(for: database, tables: IncomingProbe.self,
        containerIdentifier: containerID, startImmediately: false,
        accountIsolation: .init(environment: .development))
      let container = engine.container as! MockCloudContainer
      if phase == "crash" {
        try await engine.start()
        try await database.write { db in
          try db.execute(sql: "INSERT INTO incomingProbe VALUES ('record', 'local', X'00')")
        }
        try await engine.sendChanges()
        let id = CKRecord.ID(recordName: "record:incomingProbe", zoneID: engine.defaultZone.zoneID)
        if scenario == "account" {
          try await database.write { db in
            try db.execute(sql: "UPDATE incomingProbe SET title = 'offline A' WHERE id = 'record'")
          }
          _exit(73)
        }
        let record = try engine.private.database.record(for: id)
        record.setValue("remote", forKey: "title", at: record.userModificationTime + 1)
        let file = directory.appendingPathComponent("downloaded-asset")
        try Data("durable remote asset".utf8).write(to: file)
        record.setAsset(CKAsset(fileURL: file), forKey: "payload", at: record.userModificationTime + 1)
        try await database.write { db in
          if scenario == "retirement" {
            try db.execute(sql: "CREATE TEMP TRIGGER reject_receipt BEFORE DELETE ON sqlitedata_icloud_incomingJournal WHEN OLD.staged = 0 BEGIN SELECT RAISE(ABORT, 'injected receipt failure'); END")
          } else {
            try db.execute(sql: "CREATE TEMP TRIGGER reject_apply BEFORE \(scenario == "deletion" ? "DELETE" : "INSERT") ON incomingProbe BEGIN SELECT RAISE(ABORT, 'injected incoming failure'); END")
          }
        }
        if scenario == "deletion" || scenario == "retirement" {
          _ = try container.privateCloudDatabase.modifyRecords(deleting: [id])
          try await engine.fetchChanges()
        } else {
          _ = try container.privateCloudDatabase.modifyRecords(saving: [record])
          try await engine.fetchChanges()
        }
        let pending = try await database.read { db in
          try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlitedata_icloud_incomingJournal WHERE staged = 0")
        }
        precondition(pending == 1, "The checkpoint did not retain the failed payload")
        try FileManager.default.removeItem(at: file)
        _exit(73)
      } else if phase == "verify" {
        if scenario == "account" {
          container._userRecordID.withValue { $0 = CKRecord.ID(recordName: "account-B") }
          do { try await engine.start(); fatalError("An account A store started under B") }
          catch SyncAccountIsolationError.differentAccount { }
          precondition(!engine.isRunning)
          let title = try await database.read { try String.fetchOne($0, sql: "SELECT title FROM incomingProbe") }
          precondition(title == "offline A")
          container._userRecordID.withValue { $0 = CKRecord.ID(recordName: "mock-user") }
          try await engine.start()
        } else {
          // A new process has an empty mock server. The original payload can only come from disk.
          try await engine.start()
          try await engine.fetchChangesAndApply()
          let rows = try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM incomingProbe").map { (title: $0["title"] as String, payload: $0["payload"] as Data) }
          }
          if scenario == "deletion" || scenario == "retirement" { precondition(rows.isEmpty) }
          else {
            precondition(rows.count == 1 && rows[0].title == "remote")
            precondition(rows[0].payload == Data("durable remote asset".utf8))
          }
          let pending = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlitedata_icloud_incomingJournal")
          }
          precondition(pending == 0)
          if scenario == "retirement" {
            try await database.write { db in
              try db.execute(sql: "INSERT INTO incomingProbe VALUES ('record', 'recreated', X'00')")
            }
            try await engine.stopAndDrain()
            try await engine.start()
            try await engine.fetchChangesAndApply()
            let title = try await database.read { try String.fetchOne($0, sql: "SELECT title FROM incomingProbe") }
            precondition(title == "recreated", "A retired deletion erased a later recreation")
          }
        }
        try await engine.stopAndDrain()
        print("PASS \(scenario)")
      } else { fatalError("Unknown phase") }
    }
  }
}
