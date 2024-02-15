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
        callback: @escaping (Bool, String, [UInt8]) -> Void
    ) {
        class CWrapper {
            let callback: (Bool, String, [UInt8]) -> Void
            
            public init(_ callback: @escaping (Bool, String, [UInt8]) -> Void) {
                self.callback = callback
            }
        }
        
        let callbackWrapper: CWrapper = CWrapper(callback)
        let cWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(callbackWrapper).toOpaque()
        var cName: [CChar] = name.cArray.nullTerminated()
        var cDescrption: [CChar] = (description ?? "").cArray.nullTerminated()
        var cDisplayPic: user_profile_pic = user_profile_pic()
        var cMembers: [config_group_member] = members.map { id, name, picUrl, picEncKey in
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
            
            return config_group_member(
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
            &cName,
            &cDescrption,
            cDisplayPic,
            &cMembers,
            cMembers.count,
            { success, groupIdPtr, groupIdentityPrivateKeyPtr, maybeCtx in
                // If we have no context then we can't do anything
                guard
                    let cWrapper: CWrapper = maybeCtx.map({ Unmanaged<CWrapper>.fromOpaque($0).takeRetainedValue() })
                else { return }
                guard
                    success,
                    let groupId: String = groupIdPtr.map({ String(libSessionVal: $0, fixedLength: 66) }),
                    let groupIdentityPrivateKey: [UInt8] = groupIdentityPrivateKeyPtr
                        .map({ Array(Data(bytes: $0, count: 64)) })
                else { return cWrapper.callback(false, "", []) }
                
                cWrapper.callback(success, groupId, groupIdentityPrivateKey)
            },
            cWrapperPtr
        )
    }
    
    func approveGroup(groupSessionId: String, groupIdentityPrivateKey: Data?) {
        var cGroupId: [CChar] = groupSessionId.cArray
        
        // It looks like C doesn't deal will passing pointers to null variables well so we need
        // to explicitly pass 'nil' for the admin key in this case
        switch groupIdentityPrivateKey {
            case .none: state_approve_group(state, &cGroupId, nil)
            case .some(let groupIdentityPrivateKey):
                var cGroupIdentityPrivateKey: [UInt8] = Array(groupIdentityPrivateKey)
                state_approve_group(state, &cGroupId, &cGroupIdentityPrivateKey)
        }
    }
}
    static func removeGroupStateIfNeeded(
        _ db: Database,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) {
        dependencies.mutate(cache: .libSession) { cache in
            cache.setConfig(for: .groupKeys, sessionId: groupSessionId, to: nil)
            cache.setConfig(for: .groupInfo, sessionId: groupSessionId, to: nil)
            cache.setConfig(for: .groupMembers, sessionId: groupSessionId, to: nil)
        }
        
        _ = try? ConfigDump
            .filter(ConfigDump.Columns.sessionId == groupSessionId.hexString)
            .deleteAll(db)
    }
    
    static func saveCreatedGroup(
        _ db: Database,
        group: ClosedGroup,
        groupState: [ConfigDump.Variant: Config],
        using dependencies: Dependencies
    ) throws {
        // Create and save dumps for the configs
        try groupState.forEach { variant, config in
            try LibSession.createDump(
                config: config,
                for: variant,
                sessionId: SessionId(.group, hex: group.id),
                timestampMs: Int64(floor(group.formationTimestamp * 1000)),
                using: dependencies
            )?.upsert(db)
        }
        
        // Add the new group to the USER_GROUPS config message
        try LibSession.add(
            groupSessionId: group.id,
            groupIdentityPrivateKey: group.groupIdentityPrivateKey,
            name: group.name,
            authData: group.authData,
            joinedAt: group.formationTimestamp,
            invited: (group.invited == true),
            using: dependencies
        )
    }
    
    @discardableResult static func createGroupState(
        groupSessionId: SessionId,
        userED25519KeyPair: KeyPair,
        groupIdentityPrivateKey: Data?,
        initialMembers: [(id: String, profile: Profile?)] = [],
        initialAdmin: (id: String, profile: Profile?)? = nil,
        shouldLoadState: Bool,
        using dependencies: Dependencies
    ) throws -> [ConfigDump.Variant: Config] {
        var secretKey: [UInt8] = userED25519KeyPair.secretKey
        var groupIdentityPublicKey: [UInt8] = groupSessionId.publicKey
        
        // Create the new config objects
        var groupKeysConf: UnsafeMutablePointer<config_group_keys>? = nil
        var groupInfoConf: UnsafeMutablePointer<config_object>? = nil
        var groupMembersConf: UnsafeMutablePointer<config_object>? = nil
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        
        func loading(
            admin: (id: String, profile: Profile?)?,
            members: [(id: String, profile: Profile?)],
            into membersConf: UnsafeMutablePointer<config_object>?
        ) throws {
            guard !members.isEmpty else { return }
            
            /// Store the admin data first
            switch admin {
                case .none: break
                case .some((let id, let profile)):
                    try CExceptionHelper.performSafely {
                        var profilePic: user_profile_pic = user_profile_pic()
                        
                        if
                            let picUrl: String = profile?.profilePictureUrl,
                            let picKey: Data = profile?.profileEncryptionKey,
                            !picUrl.isEmpty,
                            picKey.count == DisplayPictureManager.aes256KeyByteLength
                        {
                            profilePic.url = picUrl.toLibSession()
                            profilePic.key = picKey.toLibSession()
                        }
                        
                        var member: config_group_member = config_group_member(
                            session_id: id.toLibSession(),
                            name: (profile?.name ?? "").toLibSession(),
                            profile_pic: profilePic,
                            admin: true,
                            invited: 0,
                            promoted: 0,
                            removed: 0,
                            supplement: false
                        )
                        
                        groups_members_set(membersConf, &member)
                    }
            }
            
            /// Then store the initial members
            struct MemberInfo: Hashable {
                let id: String
                let profile: Profile?
            }
            
            try members
                .map { MemberInfo(id: $0.id, profile: $0.profile) }
                .asSet()
                .forEach { memberInfo in
                    var profilePic: user_profile_pic = user_profile_pic()
                    
                    if
                        let picUrl: String = memberInfo.profile?.profilePictureUrl,
                        let picKey: Data = memberInfo.profile?.profileEncryptionKey,
                        !picUrl.isEmpty,
                        picKey.count == DisplayPictureManager.aes256KeyByteLength
                    {
                        profilePic.url = picUrl.toLibSession()
                        profilePic.key = picKey.toLibSession()
                    }
                    
                    try CExceptionHelper.performSafely {
                        var member: config_group_member = config_group_member(
                            session_id: memberInfo.id.toLibSession(),
                            name: (memberInfo.profile?.name ?? "").toLibSession(),
                            profile_pic: profilePic,
                            admin: false,
                            invited: 1,
                            promoted: 0,
                            removed: 0,
                            supplement: false
                        )
                        
                        groups_members_set(membersConf, &member)
                    }
                }
        }
        
        // It looks like C doesn't deal will passing pointers to null variables well so we need
        // to explicitly pass 'nil' for the admin key in this case
        switch groupIdentityPrivateKey {
            case .some(let privateKeyData):
                var groupIdentityPrivateKey: [UInt8] = Array(privateKeyData)
                
                try groups_info_init(
                    &groupInfoConf,
                    &groupIdentityPublicKey,
                    &groupIdentityPrivateKey,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
                try groups_members_init(
                    &groupMembersConf,
                    &groupIdentityPublicKey,
                    &groupIdentityPrivateKey,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
                try loading(admin: initialAdmin, members: initialMembers, into: groupMembersConf)
                
                try groups_keys_init(
                    &groupKeysConf,
                    &secretKey,
                    &groupIdentityPublicKey,
                    &groupIdentityPrivateKey,
                    groupInfoConf,
                    groupMembersConf,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
                
            case .none:
                try groups_info_init(
                    &groupInfoConf,
                    &groupIdentityPublicKey,
                    nil,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
                try groups_members_init(
                    &groupMembersConf,
                    &groupIdentityPublicKey,
                    nil,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
                try loading(admin: initialAdmin, members: initialMembers, into: groupMembersConf)
                
                try groups_keys_init(
                    &groupKeysConf,
                    &secretKey,
                    &groupIdentityPublicKey,
                    nil,
                    groupInfoConf,
                    groupMembersConf,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
        }
        
        guard
            let keysConf: UnsafeMutablePointer<config_group_keys> = groupKeysConf,
            let infoConf: UnsafeMutablePointer<config_object> = groupInfoConf,
            let membersConf: UnsafeMutablePointer<config_object> = groupMembersConf
        else {
            SNLog("[LibSession Error] Group config objects were null")
            throw LibSessionError.unableToCreateConfigObject
        }
        
        // Define the config state map and load it into memory
        let groupState: [ConfigDump.Variant: Config] = [
            .groupKeys: .groupKeys(keysConf, info: infoConf, members: membersConf),
            .groupInfo: .object(infoConf),
            .groupMembers: .object(membersConf),
        ]
        
        // Only load the state if specified (during initial group creation we want to
        // load the state after populating the different configs incase invalid data
        // was provided)
        if shouldLoadState {
            dependencies.mutate(cache: .libSession) { cache in
                groupState.forEach { variant, config in
                    cache.setConfig(for: variant, sessionId: groupSessionId, to: config)
                }
            }
        }
        
        return groupState
    }
    
    static func isAdmin(
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) -> Bool {
        return (try? dependencies[cache: .libSession]
            .config(for: .groupKeys, sessionId: groupSessionId)
            .wrappedValue
            .map { config in
                guard case .groupKeys(let conf, _, _) = config else { throw LibSessionError.invalidConfigObject }
                
                return groups_keys_is_admin(conf)
            })
            .defaulting(to: false)
    }
    
    static func encrypt(
        message: Data,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws -> Data {
        return try dependencies[cache: .libSession]
            .config(for: .groupKeys, sessionId: groupSessionId)
            .wrappedValue
            .map { config in
                guard case .groupKeys(let conf, _, _) = config else { throw LibSessionError.invalidConfigObject }
                
                var maybeCiphertext: UnsafeMutablePointer<UInt8>? = nil
                var ciphertextLen: Int = 0
                groups_keys_encrypt_message(
                    conf,
                    Array(message),
                    message.count,
                    &maybeCiphertext,
                    &ciphertextLen
                )
                
                guard
                    ciphertextLen > 0,
                    let ciphertext: Data = maybeCiphertext
                        .map({ Data(bytes: $0, count: ciphertextLen) })
                else { throw MessageSenderError.encryptionFailed }
                
                return ciphertext
            } ?? { throw MessageSenderError.encryptionFailed }()
    }
    
    static func decrypt(
        ciphertext: Data,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws -> (plaintext: Data, sender: String) {
        return try dependencies[cache: .libSession]
            .config(for: .groupKeys, sessionId: groupSessionId)
            .wrappedValue
            .map { config -> (Data, String) in
                guard case .groupKeys(let conf, _, _) = config else { throw LibSessionError.invalidConfigObject }
                
                var ciphertext: [UInt8] = Array(ciphertext)
                var cSessionId: [CChar] = [CChar](repeating: 0, count: 67)
                var maybePlaintext: UnsafeMutablePointer<UInt8>? = nil
                var plaintextLen: Int = 0
                let didDecrypt: Bool = groups_keys_decrypt_message(
                    conf,
                    &ciphertext,
                    ciphertext.count,
                    &cSessionId,
                    &maybePlaintext,
                    &plaintextLen
                )
                
                // If we got a reported failure then just stop here
                guard didDecrypt else { throw MessageReceiverError.decryptionFailed }
                
                // We need to manually free 'maybePlaintext' upon a successful decryption
                defer { maybePlaintext?.deallocate() }
                
                guard
                    plaintextLen > 0,
                    let plaintext: Data = maybePlaintext
                        .map({ Data(bytes: $0, count: plaintextLen) })
                else { throw MessageReceiverError.decryptionFailed }
                
                return (plaintext, String(cString: cSessionId))
            } ?? { throw MessageReceiverError.decryptionFailed }()
    }
}

private extension Int32 {
    func orThrow(error: [CChar]) throws {
        guard self != 0 else { return }
        
        SNLog("[LibSession Error] Unable to create group config objects: \(String(cString: error))")
        throw LibSessionError.unableToCreateConfigObject
    }
}
