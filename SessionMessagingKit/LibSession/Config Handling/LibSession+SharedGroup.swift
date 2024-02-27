// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionUIKit
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

// MARK: - Group Domains

public extension LibSession.Crypto.Domain {
    static var kickedMessage: LibSession.Crypto.Domain = "SessionGroupKickedMessage"   // stringlint:disable
}

// MARK: - Convenience

public extension LibSession.StateManager {
    func createGroup(
        name: String,
        description: String?,
        displayPictureUrl: String?,
        displayPictureEncryptionKey: Data?,
        members: [(id: String, name: String?, picUrl: String?, picEncKey: Data?)],
        callback: @escaping (String, [UInt8], LibSessionError?) -> Void
    ) {
        class CWrapper {
            let callback: (String, [UInt8], LibSessionError?) -> Void
            
            public init(_ callback: @escaping (String, [UInt8], LibSessionError?) -> Void) {
                self.callback = callback
            }
        }
        
        let callbackWrapper: CWrapper = CWrapper(callback)
        let cWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(callbackWrapper).toOpaque()
        let cName: [CChar] = name.cArray.nullTerminated()
        let cDescrption: [CChar] = (description ?? "").cArray.nullTerminated()
        var cDisplayPic: user_profile_pic = user_profile_pic()
        var cMembers: [state_group_member] = members.map { id, name, picUrl, picEncKey in
            var profilePic: user_profile_pic = user_profile_pic()
            
            if
                let picUrl: String = picUrl,
                let picKey: Data = picEncKey,
                !picUrl.isEmpty,
                picKey.count == DisplayPictureManager.aes256KeyByteLength
            {
                profilePic.url = picUrl.toLibSession()
                profilePic.key = picKey.toLibSession()
            }
            
            return state_group_member(
                session_id: id.toLibSession(),
                name: (name ?? "").toLibSession(),
                profile_pic: profilePic,
                admin: false,   // The current user will be added as an admin by libSession automatically
                invited: 0,
                promoted: 0,
                removed: 0,
                supplement: false
            )
        }
        
        if let picUrl: String = displayPictureUrl, let picEncKey: Data = displayPictureEncryptionKey {
            cDisplayPic.url = picUrl.toLibSession()
            cDisplayPic.key = picEncKey.toLibSession()
        }
        
        state_create_group(
            state,
            cName,
            cName.count,
            cDescrption,
            cDescrption.count,
            cDisplayPic,
            &cMembers,
            cMembers.count,
            { groupIdPtr, groupIdentityPrivateKeyPtr, errorPtr, errorLen, maybeCtx in
                // If we have no context then we can't do anything
                guard
                    let cWrapper: CWrapper = maybeCtx.map({ Unmanaged<CWrapper>.fromOpaque($0).takeRetainedValue() })
                else { return }
                guard
                    errorLen == 0,
                    let groupId: String = groupIdPtr.map({ String(cString: $0) }),
                    let groupIdentityPrivateKey: [UInt8] = groupIdentityPrivateKeyPtr
                        .map({ Array(Data(bytes: $0, count: 64)) })
                else {
                    let error: LibSessionError = (String(pointer: errorPtr, length: errorLen, encoding: .utf8)
                        .map { LibSessionError($0) })
                        .defaulting(to: .unknown)
                    return cWrapper.callback("", [], error)
                }
                
                cWrapper.callback(groupId, groupIdentityPrivateKey, nil)
            },
            cWrapperPtr
        )
    }
    
    func approveGroup(groupSessionId: String) {
        let cGroupId: [CChar] = groupSessionId.cArray
        
        state_approve_group(state, cGroupId)
    }
    
    func loadGroupAdminKey(groupSessionId: SessionId, groupIdentitySeed: [UInt8]) throws {
        let cGroupId: [CChar] = groupSessionId.hexString.cArray
        let cGroupIdentitySeed: [UInt8] = groupIdentitySeed
        
        guard state_load_group_admin_key(state, cGroupId, cGroupIdentitySeed) else {
            throw lastErrorForced()
        }
    }
    
    func addGroupMembers(
        groupSessionId: SessionId,
        allowAccessToHistoricMessages: Bool,
        members: [(id: String, name: String?, picUrl: String?, picEncKey: Data?)],
        callback: @escaping (LibSessionError?) -> Void
    ) {
        class CWrapper {
            let callback: (LibSessionError?) -> Void
            
            public init(_ callback: @escaping (LibSessionError?) -> Void) {
                self.callback = callback
            }
        }
        let cGroupId: [CChar] = groupSessionId.hexString.cArray
        let cMembers: [CGroupMember] = members.map { id, name, picUrl, picEncKey in
            var profilePic: user_profile_pic = user_profile_pic()
            
            if
                let picUrl: String = picUrl,
                let picKey: Data = picEncKey,
                !picUrl.isEmpty,
                picKey.count == DisplayPictureManager.aes256KeyByteLength
            {
                profilePic.url = picUrl.toLibSession()
                profilePic.key = picKey.toLibSession()
            }
            
            return CGroupMember(
                session_id: id.toLibSession(),
                name: (name ?? "").toLibSession(),
                profile_pic: profilePic,
                admin: false,
                invited: 1,
                promoted: 0,
                removed: 0,
                supplement: allowAccessToHistoricMessages
            )
        }
        let callbackWrapper: CWrapper = CWrapper(callback)
        let cWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(callbackWrapper).toOpaque()
        
        state_add_group_members(
            state,
            cGroupId,
            allowAccessToHistoricMessages,
            cMembers,
            cMembers.count,
            { errorPtr, errorLen, maybeCtx in
                // If we have no context then we can't do anything
                guard
                    let cWrapper: CWrapper = maybeCtx.map({ Unmanaged<CWrapper>.fromOpaque($0).takeRetainedValue() })
                else { return }
                guard errorLen == 0 else {
                    let error: LibSessionError = (String(pointer: errorPtr, length: errorLen, encoding: .utf8)
                        .map { LibSessionError($0) })
                        .defaulting(to: .unknown)
                    return cWrapper.callback(error)
                }
                
                cWrapper.callback(nil)
            },
            cWrapperPtr
        )
    }
    
    func removeGroup(groupSessionId: SessionId, removeUserState: Bool) {
        let cGroupId: [CChar] = groupSessionId.hexString.cArray
        
        state_erase_group(state, cGroupId, removeUserState)
    }
    
    func isAdmin(groupSessionId: SessionId) -> Bool {
        let cGroupId: [CChar] = groupSessionId.hexString.cArray
        
        return state_is_group_admin(state, cGroupId)
    }
    
    func currentGeneration(groupSessionId: SessionId) -> Int {
        let cGroupId: [CChar] = groupSessionId.hexString.cArray
        
        return Int(state_get_current_group_generation(state, cGroupId))
    }
    
    func tokenSubaccount(groupSessionId: SessionId, memberId: String) throws -> [UInt8] {
        let cGroupId: [CChar] = groupSessionId.hexString.cArray
        let cMemberId: [CChar] = memberId.cArray
        var tokenData: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeSubaccountBytes)
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        
        guard state_get_group_swarm_subaccount_token(
            state,
            cGroupId,
            cMemberId,
            &tokenData,
            &error
        ) else { throw LibSessionError(error) }
        
        return tokenData
    }
    
    func memberAuthData(groupSessionId: SessionId, memberId: String) throws -> [UInt8] {
        let cGroupId: [CChar] = groupSessionId.hexString.cArray
        let cMemberId: [CChar] = memberId.cArray
        var authData: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeAuthDataBytes)
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        
        guard state_make_group_swarm_subaccount(
            state,
            cGroupId,
            cMemberId,
            &authData,
            &error
        ) else { throw LibSessionError(error) }
        
        return authData
    }
    
    func signatureSubaccount(groupSessionId: SessionId, verificationBytes: [UInt8], memberAuthData: Data) throws -> (subaccount: [UInt8], subaccountSig: [UInt8], signature: [UInt8]) {
        let cGroupId: [CChar] = groupSessionId.hexString.cArray
        let cVerificationBytes: [UInt8] = verificationBytes
        let cMemberAuthData: [UInt8] = Array(memberAuthData)
        var subaccount: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeSubaccountBytes)
        var subaccountSig: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeSubaccountSigBytes)
        var signature: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeSubaccountSignatureBytes)
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        
        guard state_sign_group_swarm_subaccount_binary(
            state,
            cGroupId,
            cVerificationBytes,
            cVerificationBytes.count,
            cMemberAuthData,
            &subaccount,
            &subaccountSig,
            &signature,
            &error
        ) else { throw LibSessionError(error) }
        
        return (subaccount, subaccountSig, signature)
    }
    
    func encrypt(message: Data, groupSessionId: SessionId) throws -> Data {
        let cGroupId: [CChar] = groupSessionId.hexString.cArray
        let cMessage: [UInt8] = message.cArray
        var maybeCiphertext: UnsafeMutablePointer<UInt8>? = nil
        var ciphertextLen: Int = 0
        
        state_encrypt_group_message(
            state,
            cGroupId,
            cMessage,
            cMessage.count,
            &maybeCiphertext,
            &ciphertextLen
        )
        
        guard
            ciphertextLen > 0,
            let ciphertext: Data = maybeCiphertext
                .map({ Data(bytes: $0, count: ciphertextLen) })
        else { throw MessageSenderError.encryptionFailed }
        
        // Need to free the ciphertext pointer
        maybeCiphertext?.deallocate()
        
        return ciphertext
    }
    
    func decrypt(ciphertext: Data, groupSessionId: SessionId) throws -> (plaintext: Data, sender: String) {
        let cGroupId: [CChar] = groupSessionId.hexString.cArray
        let cCiphertext: [UInt8] = ciphertext.cArray
        var cSessionId: [CChar] = [CChar](repeating: 0, count: 67)
        var maybePlaintext: UnsafeMutablePointer<UInt8>? = nil
        var plaintextLen: Int = 0
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        let didDecrypt: Bool = state_decrypt_group_message(
            state,
            cGroupId,
            cCiphertext,
            cCiphertext.count,
            &cSessionId,
            &maybePlaintext,
            &plaintextLen,
            &error
        )

        // If we got a reported failure then just stop here
        guard didDecrypt else { throw LibSessionError(error) }

        guard
            plaintextLen > 0,
            let plaintext: Data = maybePlaintext
                .map({ Data(bytes: $0, count: plaintextLen) })
        else { throw LibSessionError(error) }
        
        // We need to manually free 'maybePlaintext' upon a successful decryption
        maybePlaintext?.deallocate()

        return (plaintext, String(cString: cSessionId))
    }
}

internal extension LibSession {
    static func removeGroupStateIfNeeded(
        _ db: Database,
        groupSessionId: SessionId,
        removeUserState: Bool,
        using dependencies: Dependencies
    ) {
        dependencies[singleton: .libSession].removeGroup(
            groupSessionId: groupSessionId,
            removeUserState: removeUserState
        )
        
        _ = try? ConfigDump
            .filter(ConfigDump.Columns.sessionId == groupSessionId.hexString)
            .deleteAll(db)
    }
}
