#if canImport(CloudKit)
  import CloudKit
  import Foundation
  import CryptoKit
  import StructuredQueries

  /// The record archive alone contains ephemeral CKAsset URLs. Keep asset bytes in SQLite
  /// with the archive so replay never relies on CloudKit's temporary download directory.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  struct IncomingPayload: Codable, Sendable {
    struct Asset: Codable, Sendable {
      var key: String
      var index: Int?
      var bytes: Data
    }
    var version = 1
    var record: Data
    var isShare: Bool
    var assets: [Asset]

    init(_ record: CKRecord, dataManager: any DataManager) throws {
      guard case .blob(let bytes) = CKRecord._AllFieldsRepresentation(queryOutput: record).queryBinding
      else { throw IncomingRecoveryError.invalidPayload }
      self.record = Data(bytes)
      self.isShare = record is CKShare
      self.assets = []
      for key in record.allKeys() {
        if let asset = record[key] as? CKAsset {
          guard let url = asset.fileURL else { throw IncomingRecoveryError.missingAsset }
          assets.append(Asset(key: key, index: nil, bytes: try dataManager.load(url)))
        } else if let array = record[key] as? [CKAsset] {
          for (index, asset) in array.enumerated() {
            guard let url = asset.fileURL else { throw IncomingRecoveryError.missingAsset }
            assets.append(Asset(key: key, index: index, bytes: try dataManager.load(url)))
          }
        }
      }
    }

    func materialize(dataManager: any DataManager) throws -> CKRecord {
      guard version == 1 else { throw IncomingRecoveryError.invalidPayload }
      let record: CKRecord?
      if isShare {
        record = CKShare._AllFieldsRepresentation(queryBinding: .blob(Array(self.record)))?.queryOutput
      } else {
        record = CKRecord._AllFieldsRepresentation(queryBinding: .blob(Array(self.record)))?.queryOutput
      }
      guard let record else { throw IncomingRecoveryError.invalidPayload }
      for asset in assets {
        let digest = Data(SHA256.hash(data: asset.bytes))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        let url = dataManager.temporaryDirectory.appendingPathComponent("SQLiteDataIncoming-\(name)")
        if dataManager.sha256(of: url) != digest { try dataManager.save(asset.bytes, to: url) }
        let value = CKAsset(fileURL: url)
        if let index = asset.index {
          guard var array = record[asset.key] as? [CKAsset], array.indices.contains(index)
          else { throw IncomingRecoveryError.invalidPayload }
          array[index] = value
          record[asset.key] = array
        } else {
          record[asset.key] = value
        }
      }
      return record
    }
  }

  enum IncomingRecoveryError: Error {
    case invalidPayload
    case missingAsset
    case unsupportedZoneDeletion
    case checkpointUnavailable
  }
#endif
