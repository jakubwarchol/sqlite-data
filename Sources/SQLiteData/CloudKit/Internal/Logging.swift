#if DEBUG && canImport(CloudKit)
  import CloudKit
  import TabularData
  import os

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension Logger {
    func log(_ event: SyncEngine.Event, syncEngine: any SyncEngineProtocol) {
      let prefix = "SQLiteData (\(syncEngine.database.databaseScope.label).db)"
      var actions: [String] = []
      var recordTypes: [String] = []
      var recordNames: [String] = []
      var zoneNames: [String] = []
      var ownerNames: [String] = []
      var errors: [String] = []
      var reasons: [String] = []
      var tabularDescription: String {
        var dataFrame: DataFrame = [:]
        if !actions.isEmpty {
          dataFrame.append(column: Column<String>(name: "action", contents: actions))
        }
        if !recordTypes.isEmpty {
          dataFrame.append(column: Column<String>(name: "recordType", contents: recordTypes))
        }
        if !recordNames.isEmpty {
          dataFrame.append(column: Column<String>(name: "recordName", contents: recordNames))
        }
        if !zoneNames.isEmpty {
          dataFrame.append(column: Column<String>(name: "zoneName", contents: zoneNames))
        }
        if !ownerNames.isEmpty {
          dataFrame.append(column: Column<String>(name: "ownerName", contents: ownerNames))
        }
        if !errors.isEmpty {
          dataFrame.append(column: Column<String>(name: "error", contents: errors))
        }
        if !reasons.isEmpty {
          dataFrame.append(column: Column<String>(name: "reason", contents: reasons))
        }
        if !recordTypes.isEmpty {
          dataFrame.sort(
            on: ColumnID("action", String.self),
            ColumnID("recordType", String.self),
            ColumnID("recordName", String.self)
          )
        } else if !actions.isEmpty {
          dataFrame.sort(on: ColumnID("action", String.self))
        }
        var formattingOptions = FormattingOptions(
          maximumLineWidth: 300,
          maximumCellWidth: 80,
          maximumRowCount: 1000,
          includesColumnTypes: false
        )
        formattingOptions.includesRowAndColumnCounts = false
        formattingOptions.includesRowIndices = false
        return
          dataFrame
          .description(options: formattingOptions)
          .replacing("\n", with: "\n  ")
      }

      switch event {
      case .stateUpdate:
        debug("\(prefix) stateUpdate")
      case .accountChange(let changeType):
        switch changeType {
        case .signIn(let currentUser):
          debug(
            """
            \(prefix) signIn
              Current user: \(currentUser.recordName).\(currentUser.zoneID.ownerName).\(currentUser.zoneID.zoneName)
            """
          )
        case .signOut(let previousUser):
          debug(
            """
            \(prefix) signOut
              Previous user: \(previousUser.recordName).\(previousUser.zoneID.ownerName).\(previousUser.zoneID.zoneName)
            """
          )
        case .switchAccounts(let previousUser, let currentUser):
          debug(
            """
            \(prefix) switchAccounts:
              Previous user: \(previousUser.recordName).\(previousUser.zoneID.ownerName).\(previousUser.zoneID.zoneName)
              Current user:  \(currentUser.recordName).\(currentUser.zoneID.ownerName).\(currentUser.zoneID.zoneName)
            """
          )
        @unknown default:
          debug("unknown")
        }
      case .fetchedDatabaseChanges(let modifications, let deletions):
        for modification in modifications {
          actions.append("✅ Modified")
          zoneNames.append(modification.zoneName)
          ownerNames.append(modification.ownerName)
          if !deletions.isEmpty {
            reasons.append("")
          }
        }
        for (deletedZoneID, reason) in deletions {
          actions.append("🗑️ Deleted")
          zoneNames.append(deletedZoneID.zoneName)
          ownerNames.append(deletedZoneID.ownerName)
          reasons.append(reason.loggingDescription)
        }
        debug(
          """
          \(prefix) fetchedDatabaseChanges
            \(tabularDescription)
          """
        )
      case .fetchedRecordZoneChanges(let modifications, let deletions):
        for modification in modifications {
          actions.append("✅ Modified")
          recordTypes.append(modification.recordType)
          recordNames.append(modification.recordID.recordName)
        }
        for (deletedRecordID, deletedRecordType) in deletions {
          actions.append("🗑️ Deleted")
          recordTypes.append(deletedRecordType)
          recordNames.append(deletedRecordID.recordName)
        }
        debug(
          """
          \(prefix) fetchedRecordZoneChanges
            \(tabularDescription)
          """
        )
      case .sentDatabaseChanges(
        let savedZones,
        let failedZoneSaves,
        let deletedZoneIDs,
        let failedZoneDeletes
      ):
        for savedZone in savedZones {
          actions.append("✅ Saved")
          zoneNames.append(savedZone.zoneID.zoneName)
          ownerNames.append(savedZone.zoneID.ownerName)
          if !failedZoneSaves.isEmpty || !failedZoneDeletes.isEmpty {
            errors.append("")
          }
        }
        for (failedSaveZone, error) in failedZoneSaves {
          actions.append("🛑 Failed save")
          zoneNames.append(failedSaveZone.zoneID.zoneName)
          ownerNames.append(failedSaveZone.zoneID.ownerName)
          errors.append(error.code.loggingDescription)
        }
        for deletedZoneID in deletedZoneIDs {
          actions.append("🗑️ Deleted")
          zoneNames.append(deletedZoneID.zoneName)
          ownerNames.append(deletedZoneID.ownerName)
          if !failedZoneSaves.isEmpty || !failedZoneDeletes.isEmpty {
            errors.append("")
          }
        }
        for (failedDeleteZoneID, error) in failedZoneDeletes {
          actions.append("🛑 Failed delete")
          zoneNames.append(failedDeleteZoneID.zoneName)
          ownerNames.append(failedDeleteZoneID.ownerName)
          errors.append(error.code.loggingDescription)
        }
        debug(
          """
          \(prefix) sentDatabaseChanges
            \(tabularDescription)
          """
        )
      case .sentRecordZoneChanges(
        let savedRecords,
        let failedRecordSaves,
        let deletedRecordIDs,
        let failedRecordDeletes
      ):
        for savedRecord in savedRecords {
          actions.append("✅ Saved")
          recordTypes.append(savedRecord.recordType)
          recordNames.append(savedRecord.recordID.recordName)
          if !failedRecordSaves.isEmpty || !failedRecordDeletes.isEmpty {
            errors.append("")
          }
        }
        for (failedRecord, error) in failedRecordSaves {
          actions.append("🛑 Save failed")
          recordTypes.append(failedRecord.recordType)
          recordNames.append(failedRecord.recordID.recordName)
          errors.append("\(error.code.loggingDescription) (\(error.errorCode))")
        }
        for deletedRecordID in deletedRecordIDs {
          actions.append("🗑️ Deleted")
          recordTypes.append("")
          recordNames.append(deletedRecordID.recordName)
          if !failedRecordSaves.isEmpty || !failedRecordDeletes.isEmpty {
            errors.append("")
          }
        }
        for (failedDeleteRecordID, error) in failedRecordDeletes {
          actions.append("🛑 Delete failed")
          recordTypes.append("")
          recordNames.append(failedDeleteRecordID.recordName)
          errors.append("\(error.code.loggingDescription) (\(error.errorCode))")
        }
        debug(
          """
          \(prefix) sentRecordZoneChanges
            \(tabularDescription)
          """
        )
      case .willFetchChanges:
        debug("\(prefix) willFetchChanges")
      case .willFetchRecordZoneChanges(let zoneID):
        debug("\(prefix) willFetchRecordZoneChanges: \(zoneID.zoneName)")
      case .didFetchRecordZoneChanges(let zoneID, let error):
        let error = (error?.code.loggingDescription).map { "\n  ❌ \($0)" } ?? ""
        debug(
          """
          \(prefix) willFetchRecordZoneChanges
            ✅ Zone: \(zoneID.zoneName):\(zoneID.ownerName)\(error)
          """
        )
      case .didFetchChanges:
        debug("\(prefix) didFetchChanges")
      case .willSendChanges:
        debug("\(prefix) willSendChanges")
      case .didSendChanges:
        debug("\(prefix) didSendChanges")
      @unknown default:
        warning("\(prefix) ⚠️ unknown event: \(event.description)")
      }
    }
  }

  extension CKDatabase.Scope {
    var label: String {
      switch self {
      case .public: "global"
      case .private: "private"
      case .shared: "shared"
      @unknown default: "unknown"
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension CKDatabase.DatabaseChange.Deletion.Reason {
    fileprivate var loggingDescription: String {
      switch self {
      case .deleted: "deleted"
      case .purged: "purged"
      case .encryptedDataReset: "encryptedDataReset"
      @unknown default: "(unknown reason: \(self))"
      }
    }
  }
#endif
