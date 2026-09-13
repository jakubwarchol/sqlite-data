#if canImport(CloudKit)
  public import CloudKit
  public import Foundation
  import CryptoKit
  import GRDB

  /// Enables persistent account ownership for a store. The application supplies the effective
  /// CloudKit environment because development and production may use the same container ID.
  public struct SyncAccountIsolation: Sendable {
    public enum Environment: String, Codable, Sendable { case development, production }
    public var environment: Environment
    public init(environment: Environment) { self.environment = environment }
  }

  /// Opaque, engine-scoped proof of which account was offered for an explicit connection.
  /// Capture this when presenting the choice and return the same value on confirmation.
  public struct SyncAccountAdoption: Sendable, Equatable {
    let engine: UUID
    let fingerprint: String
  }

  public enum SyncAccountIsolationError: Error, LocalizedError {
    case adoptionRequired
    case configurationRequired
    case differentAccount
    case differentEnvironment
    case accountUnavailable(CKAccountStatus)
    case accountChangedDuringAdoption

    public var errorDescription: String? {
      switch self {
      case .configurationRequired:
        "Account protection must remain enabled to reopen this workspace."
      case .adoptionRequired:
        "Choose whether to connect this device's existing data to your current iCloud account."
      case .differentAccount:
        "This workspace belongs to another iCloud account. Its data is retained locally. Sign back into that account to resume syncing."
      case .differentEnvironment:
        "This workspace belongs to a different iCloud container or environment. Open its original app configuration to resume syncing."
      case .accountUnavailable:
        "Your iCloud account is unavailable. Local data is retained and syncing is paused."
      case .accountChangedDuringAdoption:
        "The iCloud account changed while connecting. Review the current account before connecting this workspace."
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  enum SyncAccountBinding {
    static let table = "sqlitedata_icloud_accountBinding"

    static func create(_ db: Database) throws {
      try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS main.\(table) (
          singleton INTEGER PRIMARY KEY CHECK(singleton = 1), version INTEGER NOT NULL,
          container TEXT NOT NULL, environment TEXT NOT NULL, account TEXT NOT NULL
        ) STRICT
        """)
    }

    static func fingerprint(_ id: CKRecord.ID, container: String, environment: String) throws -> String {
      let data = try JSONEncoder().encode([container, environment, id.recordName, id.zoneID.zoneName, id.zoneID.ownerName])
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(
      _ db: Database, container: String, environment: String, account: String
    ) throws -> Bool {
      guard let row = try Row.fetchOne(db, sql: "SELECT * FROM main.\(table) WHERE singleton = 1")
      else { return false }
      guard row["version"] as Int == 1, row["container"] as String == container,
        row["environment"] as String == environment else { throw SyncAccountIsolationError.differentEnvironment }
      guard row["account"] as String == account else { throw SyncAccountIsolationError.differentAccount }
      return true
    }

    static func bind(_ db: Database, container: String, environment: String, account: String) throws {
      if try validate(db, container: container, environment: environment, account: account) { return }
      try db.execute(sql: "INSERT INTO main.\(table) VALUES (1, 1, ?, ?, ?)", arguments: [container, environment, account])
    }
  }
#endif
