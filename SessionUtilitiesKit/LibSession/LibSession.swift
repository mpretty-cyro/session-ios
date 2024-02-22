// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

// MARK: - Singleton

public extension Singleton {
    static let libSession: SingletonConfig<StateManagerType> = Dependencies.create(
        identifier: "libSession",
        createInstance: { _ in LibSession.NoopStateManager() }
    )
}

// MARK: - LibSession

public typealias LogLevel = SessionUtil.state_log_level

public typealias CContact = contacts_contact
public typealias CGroupMember = state_group_member
public typealias CGroup = ugroups_group_info
public typealias CCommunity = ugroups_community_info
public typealias CLegacyGroup = UnsafeMutablePointer<ugroups_legacy_group_info>
public typealias CVolatileContact = convo_info_volatile_1to1
public typealias CVolatileGroup = convo_info_volatile_group
public typealias CVolatileCommunity = convo_info_volatile_community
public typealias CVolatileLegacyGroup = convo_info_volatile_legacy_group

public enum LibSession {
    public static let logLevel: LogLevel = LOG_LEVEL_INFO
    public static var version: String { String(cString: LIBSESSION_UTIL_VERSION_STR) }
}

// MARK: - StateManagerType

public protocol StateManagerType {
    var hasPendingSend: Bool { get }
    var rawBlindedMessageRequestValue: Int32 { get }
    
    func lastError() -> LibSessionError?
    func lastErrorForced() -> LibSessionError
    
    func registerHooks() throws
    func setServiceNodeOffset(_ offset: Int64)
    
    func mutate(mutation: @escaping (UnsafeMutablePointer<mutable_user_state_object>) throws -> Void) throws
    func mutate(groupId: SessionId, mutation: @escaping (UnsafeMutablePointer<mutable_group_state_object>) throws -> Void) throws
    @discardableResult func afterNextSend(groupId: SessionId?, closure: @escaping (Error?) -> ()) -> UUID
    func removeAfterNextSend(groupId: SessionId?, closureId: UUID)
    func merge<T>(sessionIdHexString: String, messages: [T]) throws
    
    // MARK: -- Conversation State
    
    func conversationInConfig(threadId: String, rawThreadVariant: Int, visibleOnly: Bool, using dependencies: Dependencies) -> Bool
    func timestampAlreadyRead(threadId: String, rawThreadVariant: Int, timestampMs: Int64, openGroupServer: String?, openGroupRoomToken: String?) -> Bool
    func wasKickedFromGroup(groupSessionId: SessionId) -> Bool
    
    // MARK: -- Retrieval
    
    func currentHashes(sessionId: String) -> [String]
    
    func contact(sessionId: String) -> CContact?
    func group(groupSessionId: String) -> CGroup?
    func groupMember(groupSessionId: SessionId, sessionId: String) -> CGroupMember?
    func groupMembers(groupSessionId: SessionId) -> [CGroupMember]
    func community(server: String, roomToken: String) -> CCommunity?
    
    /// When using this method the caller needs to ensure they call `ugroups_legacy_group_free` with the returned value
    func legacyGroup(legacyGroupId: String) -> CLegacyGroup?
    
    func contactOrConstruct(sessionId: String) throws -> CContact
    func groupOrConstruct(groupSessionId: String) throws -> CGroup
    func groupMemberOrConstruct(groupSessionId: SessionId, sessionId: String) throws -> CGroupMember
    func communityOrConstruct(server: String, roomToken: String, publicKey: String) throws -> CCommunity
    
    /// When using this method the caller needs to ensure they call `ugroups_legacy_group_free` with the returned value
    func legacyGroupOrConstruct(legacyGroupId: String) throws -> CLegacyGroup
    
    func groupDeleteBefore(groupId: SessionId) -> Int64
    func groupAttachDeleteBefore(groupId: SessionId) -> Int64
    
    func volatileContact(sessionId: String) -> CVolatileContact?
    func volatileGroup(groupSessionId: String) -> CVolatileGroup?
    func volatileCommunity(server: String, roomToken: String) -> CVolatileCommunity?
    func volatileLegacyGroup(legacyGroupId: String) -> CVolatileLegacyGroup?
    func volatileContactOrConstruct(sessionId: String) throws -> CVolatileContact
    func volatileGroupOrConstruct(groupSessionId: String) throws -> CVolatileGroup
    func volatileLegacyGroupOrConstruct(legacyGroupId: String) throws -> CVolatileLegacyGroup
    func volatileCommunityOrConstruct(server: String, roomToken: String, publicKey: String) throws -> CVolatileCommunity
    
    // MARK: - Groups
    
    func createGroup(
        name: String,
        description: String?,
        displayPictureUrl: String?,
        displayPictureEncryptionKey: Data?,
        members: [(id: String, name: String?, picUrl: String?, picEncKey: Data?)],
        callback: @escaping (String, [UInt8], LibSessionError?) -> Void
    )
    func approveGroup(groupSessionId: String, groupIdentityPrivateKey: [UInt8]?)
    func loadGroupAdminKey(groupSessionId: SessionId, groupIdentitySeed: [UInt8]) throws
    func removeGroup(groupSessionId: SessionId, removeUserState: Bool)
    func isAdmin(groupSessionId: SessionId) -> Bool
    func currentGeneration(groupSessionId: SessionId) -> Int
    func tokenSubaccount(groupSessionId: SessionId, memberId: String) throws -> [UInt8]
    func memberAuthData(groupSessionId: SessionId, memberId: String) throws -> [UInt8]
    func signatureSubaccount(groupSessionId: SessionId, verificationBytes: [UInt8], memberAuthData: Data) throws -> (subaccount: [UInt8], subaccountSig: [UInt8], signature: [UInt8])
    func encrypt(message: Data, groupSessionId: SessionId) throws -> Data
    func decrypt(ciphertext: Data, groupSessionId: SessionId) throws -> (plaintext: Data, sender: String)
}

public extension StateManagerType {
    @discardableResult func afterNextSend(closure: @escaping (Error?) -> ()) -> UUID {
        return afterNextSend(groupId: nil, closure: closure)
    }
    
    func removeAfterNextSend(closureId: UUID) { removeAfterNextSend(groupId: nil, closureId: closureId) }
}

// MARK: - NoopStateManager

public extension LibSession {
    class NoopStateManager: StateManagerType {
        public var hasPendingSend: Bool { return false }
        public var rawBlindedMessageRequestValue: Int32 { 0 }
        
        public init() {}
        public func lastError() -> LibSessionError? { return nil }
        public func lastErrorForced() -> LibSessionError { return .unknown }
        public func registerHooks() throws {}
        public func setServiceNodeOffset(_ offset: Int64) {}
        
        public func mutate(mutation: @escaping (UnsafeMutablePointer<mutable_user_state_object>) throws -> Void) throws {}
        public func mutate(groupId: SessionId, mutation: @escaping (UnsafeMutablePointer<mutable_group_state_object>) throws -> Void) throws {}
        @discardableResult public func afterNextSend(groupId: SessionId?, closure: @escaping (Error?) -> ()) -> UUID {
            closure(nil)
            return UUID()
        }
        public func removeAfterNextSend(groupId: SessionId?, closureId: UUID) {}
        
        public func merge<T>(sessionIdHexString: String, messages: [T]) throws {}
        
        // MARK: -- Conversation State
        
        public func conversationInConfig(threadId: String, rawThreadVariant: Int, visibleOnly: Bool, using dependencies: Dependencies) -> Bool {
            return false
        }
        public func timestampAlreadyRead(threadId: String, rawThreadVariant: Int, timestampMs: Int64, openGroupServer: String?, openGroupRoomToken: String?) -> Bool {
            return false
        }
        public func wasKickedFromGroup(groupSessionId: SessionId) -> Bool { return true }
        
        // MARK: -- Retrieval
        
        public func currentHashes(sessionId: String) -> [String] { return [] }
        
        public func contact(sessionId: String) -> CContact? { return nil }
        public func group(groupSessionId: String) -> CGroup? { return nil }
        public func groupMember(groupSessionId: SessionId, sessionId: String) -> CGroupMember? { return nil }
        public func groupMembers(groupSessionId: SessionId) -> [CGroupMember] { return [] }
        public func community(server: String, roomToken: String) -> CCommunity? { return nil }
        public func legacyGroup(legacyGroupId: String) -> CLegacyGroup? { return nil }
        
        public func contactOrConstruct(sessionId: String) throws -> CContact { throw LibSessionError.invalidState }
        public func groupOrConstruct(groupSessionId: String) throws -> CGroup { throw LibSessionError.invalidState }
        public func groupMemberOrConstruct(groupSessionId: SessionId, sessionId: String) throws -> CGroupMember {
            throw LibSessionError.invalidState
        }
        public func communityOrConstruct(server: String, roomToken: String, publicKey: String) throws -> CCommunity {
            throw LibSessionError.invalidState
        }
        public func legacyGroupOrConstruct(legacyGroupId: String) throws -> CLegacyGroup { throw LibSessionError.invalidState }
        
        public func groupDeleteBefore(groupId: SessionId) -> Int64 { return 0 }
        public func groupAttachDeleteBefore(groupId: SessionId) -> Int64 { return 0 }
        
        public func volatileContact(sessionId: String) -> CVolatileContact? { return nil }
        public func volatileGroup(groupSessionId: String) -> CVolatileGroup? { return nil }
        public func volatileCommunity(server: String, roomToken: String) -> CVolatileCommunity? { return nil }
        public func volatileLegacyGroup(legacyGroupId: String) -> CVolatileLegacyGroup? { return nil }
        public func volatileContactOrConstruct(sessionId: String) throws -> CVolatileContact { throw LibSessionError.invalidState }
        public func volatileGroupOrConstruct(groupSessionId: String) throws -> CVolatileGroup { throw LibSessionError.invalidState }
        public func volatileCommunityOrConstruct(server: String, roomToken: String, publicKey: String) throws -> CVolatileCommunity {
            throw LibSessionError.invalidState
        }
        public func volatileLegacyGroupOrConstruct(legacyGroupId: String) throws -> CVolatileLegacyGroup {
            throw LibSessionError.invalidState
        }
        
        // MARK: - Groups
        
        public func createGroup(
            name: String,
            description: String?,
            displayPictureUrl: String?,
            displayPictureEncryptionKey: Data?,
            members: [(id: String, name: String?, picUrl: String?, picEncKey: Data?)],
            callback: @escaping (String, [UInt8], LibSessionError?) -> Void
        ) { callback("", [], LibSessionError.invalidState) }
        public func approveGroup(groupSessionId: String, groupIdentityPrivateKey: [UInt8]?) {}
        public func loadGroupAdminKey(groupSessionId: SessionId, groupIdentitySeed: [UInt8]) throws {}
        public func removeGroup(groupSessionId: SessionId, removeUserState: Bool) {}
        
        public func isAdmin(groupSessionId: SessionId) -> Bool { return false }
        public func currentGeneration(groupSessionId: SessionId) -> Int { return 0 }
        public func tokenSubaccount(groupSessionId: SessionId, memberId: String) throws -> [UInt8] {
            throw LibSessionError.invalidState
        }
        public func memberAuthData(groupSessionId: SessionId, memberId: String) throws -> [UInt8] {
            throw LibSessionError.invalidState
        }
        public func signatureSubaccount(groupSessionId: SessionId, verificationBytes: [UInt8], memberAuthData: Data) throws -> (subaccount: [UInt8], subaccountSig: [UInt8], signature: [UInt8]) {
            throw LibSessionError.invalidState
        }
        public func encrypt(message: Data, groupSessionId: SessionId) throws -> Data { throw LibSessionError.invalidState }
        public func decrypt(ciphertext: Data, groupSessionId: SessionId) throws -> (plaintext: Data, sender: String) {
            throw LibSessionError.invalidState
        }
    }
}
