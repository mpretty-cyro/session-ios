// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil

public enum LibSessionError: LocalizedError {
    case invalidState
    case userDoesNotExist
    case getOrConstructFailedUnexpectedly
    case processingLoopLimitReached
    case failedToRetrieveConfigData
    case cannotMergeInvalidMessageType
    
    case failedToRekeyGroup
    case failedToKeySupplementGroup
    case failedToMakeSubAccountInGroup
    
    case cannotMutateReadOnlyConfigObject
    
    case libSessionError(String)
    case unknown
    
    public init(_ cError: [CChar]) {
        self = LibSessionError.libSessionError(String(cString: cError))
    }
    
    public init(_ errorString: String) {
        switch errorString {
            case String(cString: SESSION_ERROR_READ_ONLY_CONFIG): self = .cannotMutateReadOnlyConfigObject
            default: self = LibSessionError.libSessionError(errorString)
        }
    }
    
    public var errorDescription: String? {
        switch self {
            case .invalidState: return "Invalid state."
            case .userDoesNotExist: return "User does not exist."
            case .getOrConstructFailedUnexpectedly: return "'getOrConstruct' failed unexpectedly."
            case .processingLoopLimitReached: return "Processing loop limit reached."
            case .failedToRetrieveConfigData: return "Failed to retrieve config data."
            case .cannotMergeInvalidMessageType: return "Cannot merge invalid message type."
            
            case .failedToRekeyGroup: return "Failed to rekey group."
            case .failedToKeySupplementGroup: return "Failed to key supplement group."
            case .failedToMakeSubAccountInGroup: return "Failed to make subaccount in group."
                
            case .cannotMutateReadOnlyConfigObject:
                return "Unable to make changes to a read-only config object"
            
            case .libSessionError(let error): return "\(error)\(error.hasSuffix(".") ? "" : ".")"
            case .unknown: return "An unknown error occurred."
        }
    }
}
