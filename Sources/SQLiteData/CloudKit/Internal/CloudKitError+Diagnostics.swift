#if canImport(CloudKit)
  import CloudKit

  extension CKError.Code {
    var loggingDescription: String {
      switch self {
      case .internalError: "internalError"
      case .partialFailure: "partialFailure"
      case .networkUnavailable: "networkUnavailable"
      case .networkFailure: "networkFailure"
      case .badContainer: "badContainer"
      case .serviceUnavailable: "serviceUnavailable"
      case .requestRateLimited: "requestRateLimited"
      case .missingEntitlement: "missingEntitlement"
      case .notAuthenticated: "notAuthenticated"
      case .permissionFailure: "permissionFailure"
      case .unknownItem: "unknownItem"
      case .invalidArguments: "invalidArguments"
      case .resultsTruncated: "resultsTruncated"
      case .serverRecordChanged: "serverRecordChanged"
      case .serverRejectedRequest: "serverRejectedRequest"
      case .assetFileNotFound: "assetFileNotFound"
      case .assetFileModified: "assetFileModified"
      case .incompatibleVersion: "incompatibleVersion"
      case .constraintViolation: "constraintViolation"
      case .operationCancelled: "operationCancelled"
      case .changeTokenExpired: "changeTokenExpired"
      case .batchRequestFailed: "batchRequestFailed"
      case .zoneBusy: "zoneBusy"
      case .badDatabase: "badDatabase"
      case .quotaExceeded: "quotaExceeded"
      case .zoneNotFound: "zoneNotFound"
      case .limitExceeded: "limitExceeded"
      case .userDeletedZone: "userDeletedZone"
      case .tooManyParticipants: "tooManyParticipants"
      case .alreadyShared: "alreadyShared"
      case .referenceViolation: "referenceViolation"
      case .managedAccountRestricted: "managedAccountRestricted"
      case .participantMayNeedVerification: "participantMayNeedVerification"
      case .serverResponseLost: "serverResponseLost"
      case .assetNotAvailable: "assetNotAvailable"
      case .accountTemporarilyUnavailable: "accountTemporarilyUnavailable"
      #if canImport(FoundationModels)
        case .participantAlreadyInvited: "participantAlreadyInvited"
      #endif
      @unknown default: "(unknown error)"
      }
    }
  }

#endif
