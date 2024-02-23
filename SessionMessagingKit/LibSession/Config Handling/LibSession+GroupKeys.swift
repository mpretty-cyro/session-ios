// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Size Restrictions

public extension LibSession {
    static var sizeAuthDataBytes: Int { 100 }
    static var sizeSubaccountBytes: Int { 36 }
    static var sizeSubaccountSigBytes: Int { 64 }
    static var sizeSubaccountSignatureBytes: Int { 64 }
}

// MARK: - Group Keys Handling

internal extension LibSession {
    /// `libSession` manages keys entirely so there is no need for a DB presence
    static let columnsRelatedToGroupKeys: [ColumnExpression] = []
    
    // MARK: - Incoming Changes
    
    static func handleGroupKeysUpdate(
        in state: UnsafeMutablePointer<state_object>,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws {
        let cGroupId: [CChar] = groupSessionId.hexString.cArray
        
        /// If two admins rekeyed for different member changes at the same time then there is a "key collision" and the "needs rekey" function
        /// will return true to indicate that a 3rd `rekey` needs to be made to have a final set of keys which includes all members
        guard state_group_needs_rekey(state, cGroupId) else { return }
        
        try rekey(groupSessionId: groupSessionId, using: dependencies)
    }
}

// MARK: - Outgoing Changes

internal extension LibSession {
    static func rekey(
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws {
        try dependencies[singleton: .libSession].mutate(groupId: groupSessionId) { [dependencies] state in
            guard state_rekey_group(state) else {
                throw dependencies[singleton: .libSession].lastError() ?? LibSessionError.failedToRekeyGroup
            }
        }
    }
    
    static func generateSubaccountToken(
        groupSessionId: SessionId,
        memberId: String,
        using dependencies: Dependencies
    ) throws -> [UInt8] {
        try dependencies[singleton: .crypto].tryGenerate(
            .tokenSubaccount(
                groupSessionId: groupSessionId,
                memberId: memberId,
                using: dependencies
            )
        )
    }
    
    static func generateAuthData(
        groupSessionId: SessionId,
        memberId: String,
        using dependencies: Dependencies
    ) throws -> Authentication.Info {
        try dependencies[singleton: .crypto].tryGenerate(
            .memberAuthData(
                groupSessionId: groupSessionId,
                memberId: memberId,
                using: dependencies
            )
        )
    }
    
    static func generateSubaccountSignature(
        groupSessionId: SessionId,
        verificationBytes: [UInt8],
        memberAuthData: Data,
        using dependencies: Dependencies
    ) throws -> Authentication.Signature {
        try dependencies[singleton: .crypto].tryGenerate(
            .signatureSubaccount(
                groupSessionId: groupSessionId,
                verificationBytes: verificationBytes,
                memberAuthData: memberAuthData,
                using: dependencies
            )
        )
    }
}
