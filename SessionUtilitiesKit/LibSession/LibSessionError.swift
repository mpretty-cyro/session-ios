// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum LibSessionError: LocalizedError {
    case unableToCreateConfigObject
    case invalidConfigObject
    case userDoesNotExist
    case getOrConstructFailedUnexpectedly
    case processingLoopLimitReached
    case failedToRetrieveConfigData
    case cannotMergeInvalidMessageType
    
    case failedToRekeyGroup
    case failedToKeySupplementGroup
    case failedToMakeSubAccountInGroup
    
    case failedToStartSuppressingHooks(String?)
    case failedToStopSuppressingHooks(String?)
    
    case libSessionError(String)
    case unknown
    
    public init(_ cError: [CChar]) {
        self = LibSessionError.libSessionError(String(cString: cError))
    }
    
    public var errorDescription: String? {
        switch self {
            case .unableToCreateConfigObject: return "Unable to create config object."
            case .invalidConfigObject: return "Invalid config object."
            case .userDoesNotExist: return "User does not exist."
            case .getOrConstructFailedUnexpectedly: return "'getOrConstruct' failed unexpectedly."
            case .processingLoopLimitReached: return "Processing loop limit reached."
            case .failedToRetrieveConfigData: return "Failed to retrieve config data."
            case .cannotMergeInvalidMessageType: return "Cannot merge invalid message type."
            
            case .failedToRekeyGroup: return "Failed to rekey group."
            case .failedToKeySupplementGroup: return "Failed to key supplement group."
            case .failedToMakeSubAccountInGroup: return "Failed to make subaccount in group."
                
            case .failedToStartSuppressingHooks(let error):
                return "Failed to start suppressing hooks with error: \(error ?? "unknown error")\(error?.hasSuffix(".") == true ? "" : ".")"
                
            case .failedToStopSuppressingHooks(let error):
                return "Failed to stop suppressing hooks with error: \(error ?? "unknown error")\(error?.hasSuffix(".") == true ? "" : ".")"
            
            case .libSessionError(let error): return "\(error)\(error.hasSuffix(".") ? "" : ".")"
            case .unknown: return "An unknown error occurred."
        }
    }
}
