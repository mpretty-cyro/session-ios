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

public typealias LogLevel = SessionUtil.config_log_level

public typealias CContact = contacts_contact
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
    var lastError: LibSessionError? { get }
    var rawBlindedMessageRequestValue: Int32 { get }
    
    func registerHooks() throws
    func setServiceNodeOffset(_ offset: Int64)
    
    func mutate(mutation: @escaping (UnsafeMutablePointer<mutable_state_user_object>) -> Void)
    func mutate(mutation: @escaping (UnsafeMutablePointer<mutable_state_user_object>) throws -> Void) throws
    func mutate(groupId: SessionId, mutation: @escaping (UnsafeMutablePointer<mutable_state_group_object>) -> Void)
    func mutate(groupId: SessionId, mutation: @escaping (UnsafeMutablePointer<mutable_state_group_object>) throws -> Void) throws
    func merge<T>(sessionIdHexString: String, messages: [T]) throws
    
    // MARK: -- Conversation State
    
    func conversationInConfig(threadId: String, rawThreadVariant: Int, visibleOnly: Bool, using dependencies: Dependencies) -> Bool
    func timestampAlreadyRead(threadId: String, rawThreadVariant: Int, timestampMs: Int64, openGroupServer: String?, openGroupRoomToken: String?) -> Bool
    func wasKickedFromGroup(groupSessionId: SessionId) -> Bool
    
    // MARK: -- Creation
    
    func createGroup(
        name: String,
        description: String?,
        displayPictureUrl: String?,
        displayPictureEncryptionKey: Data?,
        members: [(id: String, name: String?, picUrl: String?, picEncKey: Data?)],
        callback: @escaping (Bool, String, [UInt8]) -> Void
    )
    func approveGroup(groupSessionId: String, groupIdentityPrivateKey: Data?)
    
    // MARK: -- Retrieval
    
    func contact(sessionId: String) -> CContact?
    func group(groupSessionId: String) -> CGroup?
    func community(server: String, roomToken: String) -> CCommunity?
    
    /// When using this method the caller needs to ensure they call `ugroups_legacy_group_free` with the returned value
    func legacyGroup(legacyGroupId: String) -> CLegacyGroup?
    
    func contactOrConstruct(sessionId: String) throws -> CContact
    func groupOrConstruct(groupSessionId: String) throws -> CGroup
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
}

// MARK: - NoopStateManager

public extension LibSession {
    class NoopStateManager: StateManagerType {
        public var lastError: LibSessionError? { return nil }
        public var rawBlindedMessageRequestValue: Int32 { 0 }
        
        public init() {}
        public func registerHooks() throws {}
        public func setServiceNodeOffset(_ offset: Int64) {}
        
        public func mutate(mutation: @escaping (UnsafeMutablePointer<mutable_state_user_object>) -> Void) {}
        public func mutate(mutation: @escaping (UnsafeMutablePointer<mutable_state_user_object>) throws -> Void) throws {}
        public func mutate(groupId: SessionId, mutation: @escaping (UnsafeMutablePointer<mutable_state_group_object>) -> Void) {}
        public func mutate(groupId: SessionId, mutation: @escaping (UnsafeMutablePointer<mutable_state_group_object>) throws -> Void) throws {}
        
        public func merge<T>(sessionIdHexString: String, messages: [T]) throws {}
        
        // MARK: -- Conversation State
        
        public func conversationInConfig(threadId: String, rawThreadVariant: Int, visibleOnly: Bool, using dependencies: Dependencies) -> Bool {
            return false
        }
        public func timestampAlreadyRead(threadId: String, rawThreadVariant: Int, timestampMs: Int64, openGroupServer: String?, openGroupRoomToken: String?) -> Bool {
            return false
        }
        public func wasKickedFromGroup(groupSessionId: SessionId) -> Bool { return true }
        
        // MARK: -- Creation
        
        public func createGroup(
            name: String,
            description: String?,
            displayPictureUrl: String?,
            displayPictureEncryptionKey: Data?,
            members: [(id: String, name: String?, picUrl: String?, picEncKey: Data?)],
            callback: @escaping (Bool, String, [UInt8]) -> Void
        ) {}
        public func approveGroup(groupSessionId: String, groupIdentityPrivateKey: Data?) {}
        
        // MARK: -- Conversation Retrieval
        
        public func contact(sessionId: String) -> CContact? { return nil }
        public func group(groupSessionId: String) -> CGroup? { return nil }
        public func community(server: String, roomToken: String) -> CCommunity? { return nil }
        public func legacyGroup(legacyGroupId: String) -> CLegacyGroup? { return nil }
        
        public func contactOrConstruct(sessionId: String) throws -> CContact { throw StorageError.objectNotFound }
        public func groupOrConstruct(groupSessionId: String) throws -> CGroup { throw StorageError.objectNotFound }
        public func communityOrConstruct(server: String, roomToken: String, publicKey: String) throws -> CCommunity {
            throw StorageError.objectNotFound
        }
        public func legacyGroupOrConstruct(legacyGroupId: String) throws -> CLegacyGroup { throw StorageError.objectNotFound }
        
        public func groupDeleteBefore(groupId: SessionId) -> Int64 { return 0 }
        public func groupAttachDeleteBefore(groupId: SessionId) -> Int64 { return 0 }
        
        public func volatileContact(sessionId: String) -> CVolatileContact? { return nil }
        public func volatileGroup(groupSessionId: String) -> CVolatileGroup? { return nil }
        public func volatileCommunity(server: String, roomToken: String) -> CVolatileCommunity? { return nil }
        public func volatileLegacyGroup(legacyGroupId: String) -> CVolatileLegacyGroup? { return nil }
        public func volatileContactOrConstruct(sessionId: String) throws -> CVolatileContact { throw StorageError.objectNotFound }
        public func volatileGroupOrConstruct(groupSessionId: String) throws -> CVolatileGroup { throw StorageError.objectNotFound }
        public func volatileCommunityOrConstruct(server: String, roomToken: String, publicKey: String) throws -> CVolatileCommunity {
            throw StorageError.objectNotFound
        }
        public func volatileLegacyGroupOrConstruct(legacyGroupId: String) throws -> CVolatileLegacyGroup {
            throw StorageError.objectNotFound
        }
    }
}
