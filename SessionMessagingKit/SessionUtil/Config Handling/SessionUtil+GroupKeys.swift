// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

// MARK: - Size Restrictions

public extension SessionUtil {
    static var sizeAuthDataBytes: Int { 100 }
    static var sizeSubaccountBytes: Int { 36 }
    static var sizeSubaccountSigBytes: Int { 64 }
    static var sizeSubaccountSignatureBytes: Int { 64 }
}

// MARK: - Group Keys Handling

internal extension SessionUtil {
    /// `libSession` manages keys entirely so there is no need for a DB presence
    static let columnsRelatedToGroupKeys: [ColumnExpression] = []
    
    // MARK: - Incoming Changes
    
    static func handleGroupKeysUpdate(
        _ db: Database,
        in config: Config?,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws {
        guard case .groupKeys(let conf, _, _) = config else { throw SessionUtilError.invalidConfigObject }
        
        /// If two admins rekeyed for different member changes at the same time then there is a "key collision" and the "needs rekey" function
        /// will return true to indicate that a 3rd `rekey` needs to be made to have a final set of keys which includes all members
        ///
        /// **Note:** We don't check `needsDump` in this case because the local state _could_ be persisted yet still require a `rekey`
        /// so we should rely solely on `groups_keys_needs_rekey`
        guard groups_keys_needs_rekey(conf) else { return }
        
        try rekey(db, groupSessionId: groupSessionId, using: dependencies)
    }
}

// MARK: - Outgoing Changes

internal extension SessionUtil {
    static func rekey(
        _ db: Database,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws {
        try SessionUtil.performAndPushChange(
            db,
            for: .groupKeys,
            sessionId: groupSessionId,
            using: dependencies
        ) { config in
            guard case .groupKeys(let conf, let infoConf, let membersConf) = config else {
                throw SessionUtilError.invalidConfigObject
            }
            
            // Performing a `rekey` returns the updated key data which we don't use directly, this updated
            // key will now be returned by `groups_keys_pending_config` which the `ConfigurationSyncJob` uses
            // when generating pending changes for group keys so we don't need to push it directly
            var pushResult: UnsafePointer<UInt8>? = nil
            var pushResultLen: Int = 0
            guard groups_keys_rekey(conf, infoConf, membersConf, &pushResult, &pushResultLen) else {
                throw SessionUtilError.failedToRekeyGroup
            }
        }
    }
    
    static func keySupplement(
        _ db: Database,
        groupSessionId: SessionId,
        memberIds: Set<String>,
        using dependencies: Dependencies
    ) throws -> Data {
        try dependencies[cache: .sessionUtil]
            .config(for: .groupKeys, sessionId: groupSessionId)
            .wrappedValue
            .map { config -> Data in
                guard case .groupKeys(let conf, _, _) = config else { throw SessionUtilError.invalidConfigObject }
                
                var cMemberIds: [UnsafePointer<CChar>?] = memberIds
                    .map { id in id.cArray.nullTerminated() }
                    .unsafeCopy()
                
                defer { cMemberIds.forEach { $0?.deallocate() } }
                
                // Performing a `key_supplement` returns the supplemental key changes, since our state doesn't care
                // about the `GROUP_KEYS` needed for other members this change won't result in the `GROUP_KEYS` config
                // going into a pending state or the `ConfigurationSyncJob` getting triggered so return the data so that
                // the caller can push it directly
                var cSupplementData: UnsafeMutablePointer<UInt8>!
                var cSupplementDataLen: Int = 0
                
                guard
                    groups_keys_key_supplement(conf, &cMemberIds, cMemberIds.count, &cSupplementData, &cSupplementDataLen),
                    let cSupplementData: UnsafeMutablePointer<UInt8> = cSupplementData
                else { throw SessionUtilError.failedToKeySupplementGroup }
                
                // Must deallocate on success
                let supplementData: Data = Data(
                    bytes: cSupplementData,
                    count: cSupplementDataLen
                )
                cSupplementData.deallocate()
                
                return supplementData
            } ?? { throw SessionUtilError.invalidConfigObject }()
    }
    
    static func loadAdminKey(
        _ db: Database,
        groupIdentitySeed: Data,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws {
        try SessionUtil
            .performAndPushChange(
                db,
                for: .groupKeys,
                sessionId: groupSessionId,
                using: dependencies
            ) { config in
                guard case .groupKeys(let conf, let infoConf, let membersConf) = config else {
                    throw SessionUtilError.invalidConfigObject
                }
                
                var identitySeed: [UInt8] = Array(groupIdentitySeed)
                try CExceptionHelper.performSafely {
                    groups_keys_load_admin_key(conf, &identitySeed, infoConf, membersConf)
                }
            }
    }
    
    static func currentGeneration(
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws -> Int {
        try dependencies[cache: .sessionUtil]
            .config(for: .groupKeys, sessionId: groupSessionId)
            .wrappedValue
            .map { config -> Int in
                guard case .groupKeys(let conf, _, _) = config else { throw SessionUtilError.invalidConfigObject }
                
                return Int(groups_keys_current_generation(conf))
            } ?? { throw SessionUtilError.invalidConfigObject }()
    }
    
    static func generateSubaccountToken(
        groupSessionId: SessionId,
        memberId: String,
        using dependencies: Dependencies
    ) throws -> [UInt8] {
        try dependencies[singleton: .crypto].tryGenerate(
            .tokenSubaccount(
                config: dependencies[cache: .sessionUtil]
                    .config(for: .groupKeys, sessionId: groupSessionId)
                    .wrappedValue,
                groupSessionId: groupSessionId,
                memberId: memberId
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
                config: dependencies[cache: .sessionUtil]
                    .config(for: .groupKeys, sessionId: groupSessionId)
                    .wrappedValue,
                groupSessionId: groupSessionId,
                memberId: memberId
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
                config: dependencies[cache: .sessionUtil]
                    .config(for: .groupKeys, sessionId: groupSessionId)
                    .wrappedValue,
                verificationBytes: verificationBytes,
                memberAuthData: memberAuthData
            )
        )
    }
}
