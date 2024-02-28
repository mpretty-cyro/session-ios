// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtil
import SessionUtilitiesKit

class MockStateManager: Mock<StateManagerType>, StateManagerType {
    var hasPendingSend: Bool { return mock() }
    var rawBlindedMessageRequestValue: Int32 { mock() }
    
    func lastError() -> LibSessionError? { return try? mockThrowing() }
    func lastErrorForced() -> LibSessionError { return mock() }
    func registerHooks() throws { mockNoReturn() }
    func setServiceNodeOffset(_ offset: Int64) { mockNoReturn(args: [offset]) }
    
    public func mutate(mutation: @escaping (UnsafeMutablePointer<mutable_user_state_object>) throws -> Void) throws {
        mockNoReturn(untrackedArgs: [mutation])
    }
    public func mutate(groupId: SessionId, mutation: @escaping (UnsafeMutablePointer<mutable_group_state_object>) throws -> Void) throws {
        mockNoReturn(args: [groupId], untrackedArgs: [mutation])
    }
    
    @discardableResult public func afterNextSend(groupId: SessionId?, closure: @escaping (Error?) -> ()) -> UUID {
        return mock(args: [groupId], untrackedArgs: [closure])
    }
    public func removeAfterNextSend(groupId: SessionId?, closureId: UUID) {
        mockNoReturn(args: [groupId, closureId])
    }
    
    public func merge<T>(sessionIdHexString: String, messages: [T]) throws {
        mockNoReturn(args: [sessionIdHexString, messages])
    }
    
    // MARK: -- Conversation State
    
    public func conversationInConfig(threadId: String, rawThreadVariant: Int, visibleOnly: Bool, using dependencies: Dependencies) -> Bool {
        return mock(args: [threadId, rawThreadVariant, visibleOnly], untrackedArgs: [dependencies])
    }
    public func timestampAlreadyRead(threadId: String, rawThreadVariant: Int, timestampMs: Int64, openGroupServer: String?, openGroupRoomToken: String?) -> Bool {
        return mock(args: [threadId, rawThreadVariant, timestampMs, openGroupServer, openGroupRoomToken])
    }
    public func wasKickedFromGroup(groupSessionId: SessionId) -> Bool {
        return mock(args: [groupSessionId])
    }
    
    // MARK: -- Retrieval
    
    public func currentHashes(sessionId: String) -> [String] { return mock(args: [sessionId]) }
    
    public func contact(sessionId: String) -> CContact? { return try? mockThrowing(args: [sessionId]) }
    public func group(groupSessionId: String) -> CGroup? { return try? mockThrowing(args: [groupSessionId]) }
    public func groupMember(groupSessionId: SessionId, sessionId: String) -> CGroupMember? {
        return try? mockThrowing(args: [groupSessionId, sessionId])
    }
    public func groupMembers(groupSessionId: SessionId) -> [CGroupMember] {
        return ((try? mockThrowing(args: [groupSessionId])) ?? [])
    }
    public func community(server: String, roomToken: String) -> CCommunity? { return try? mockThrowing(args: [server, roomToken]) }
    public func legacyGroup(legacyGroupId: String) -> CLegacyGroup? { return try? mockThrowing(args: [legacyGroupId]) }
    
    public func contactOrConstruct(sessionId: String) throws -> CContact {
        return try mockThrowing(args: [sessionId])
    }
    public func groupOrConstruct(groupSessionId: String) throws -> CGroup {
        return try mockThrowing(args: [groupSessionId])
    }
    public func groupMemberOrConstruct(groupSessionId: SessionId, sessionId: String) throws -> CGroupMember {
        return try mockThrowing(args: [groupSessionId, sessionId])
    }
    public func communityOrConstruct(server: String, roomToken: String, publicKey: String) throws -> CCommunity {
        return try mockThrowing(args: [server, roomToken, publicKey])
    }
    public func legacyGroupOrConstruct(legacyGroupId: String) throws -> CLegacyGroup {
        return try mockThrowing(args: [legacyGroupId])
    }
    
    public func groupDeleteBefore(groupId: SessionId) -> Int64 { return mock(args: [groupId]) }
    public func groupAttachDeleteBefore(groupId: SessionId) -> Int64 { return mock(args: [groupId]) }
    
    public func volatileContact(sessionId: String) -> CVolatileContact? { return try? mockThrowing(args: [sessionId]) }
    public func volatileGroup(groupSessionId: String) -> CVolatileGroup? { return try? mockThrowing(args: [groupSessionId]) }
    public func volatileCommunity(server: String, roomToken: String) -> CVolatileCommunity? {
        return try? mockThrowing(args: [server, roomToken])
    }
    public func volatileLegacyGroup(legacyGroupId: String) -> CVolatileLegacyGroup? { return try? mockThrowing(args: [legacyGroupId]) }
    public func volatileContactOrConstruct(sessionId: String) throws -> CVolatileContact {
        try mockThrowing(args: [sessionId])
    }
    public func volatileGroupOrConstruct(groupSessionId: String) throws -> CVolatileGroup {
        try mockThrowing(args: [groupSessionId])
    }
    public func volatileCommunityOrConstruct(server: String, roomToken: String, publicKey: String) throws -> CVolatileCommunity {
        try mockThrowing(args: [server, roomToken, publicKey])
    }
    public func volatileLegacyGroupOrConstruct(legacyGroupId: String) throws -> CVolatileLegacyGroup {
        try mockThrowing(args: [legacyGroupId])
    }
    
    // MARK: - Groups
    
    public func createGroup(
        name: String,
        description: String?,
        displayPictureUrl: String?,
        displayPictureEncryptionKey: Data?,
        members: [(id: String, name: String?, picUrl: String?, picEncKey: Data?)],
        callback: @escaping (String, [UInt8], LibSessionError?) -> Void
    ) {
        mockNoReturn(
            args: [name, description, displayPictureUrl, displayPictureEncryptionKey, members],
            untrackedArgs: [callback]
        )
    }
    
    public func approveGroup(groupSessionId: String) {
        mockNoReturn(args: [groupSessionId])
    }
    public func loadGroupAdminKey(groupSessionId: SessionId, groupIdentitySeed: [UInt8]) throws {
        mockNoReturn(args: [groupSessionId, groupIdentitySeed])
    }
    public func addGroupMembers(
        groupSessionId: SessionId,
        allowAccessToHistoricMessages: Bool,
        members: [(id: String, name: String?, picUrl: String?, picEncKey: Data?)],
        callback: @escaping (LibSessionError?) -> Void
    ) {
        mockNoReturn(
            args: [groupSessionId, allowAccessToHistoricMessages, members],
            untrackedArgs: [callback]
        )
    }
    
    public func removeGroup(groupSessionId: SessionId, removeUserState: Bool) {
        mockNoReturn(args: [groupSessionId, removeUserState])
    }
    
    public func markAsKicked(groupSessionIds: [String]) throws {
        mockNoReturn(args: [groupSessionIds])
    }
    
    public func isAdmin(groupSessionId: SessionId) -> Bool { return mock(args: [groupSessionId]) }
    public func currentGeneration(groupSessionId: SessionId) -> Int { return mock(args: [groupSessionId]) }
    public func tokenSubaccount(groupSessionId: SessionId, memberId: String) throws -> [UInt8] {
        try mockThrowing(args: [groupSessionId, memberId])
    }
    public func memberAuthData(groupSessionId: SessionId, memberId: String) throws -> [UInt8] {
        try mockThrowing(args: [groupSessionId, memberId])
    }
    public func signatureSubaccount(groupSessionId: SessionId, verificationBytes: [UInt8], memberAuthData: Data) throws -> (subaccount: [UInt8], subaccountSig: [UInt8], signature: [UInt8]) {
        try mockThrowing(args: [groupSessionId, verificationBytes, memberAuthData])
    }
    public func encrypt(message: Data, groupSessionId: SessionId) throws -> Data {
        try mockThrowing(args: [message, groupSessionId])
    }
    public func decrypt(ciphertext: Data, groupSessionId: SessionId) throws -> (plaintext: Data, sender: String) {
        try mockThrowing(args: [ciphertext, groupSessionId])
    }
}

// MARK: - Convenience

extension MockStateManager {
    public static func registerFakeResponse(for state: UnsafeMutablePointer<state_object>?) {
        // Register a hook to be called when libSession decides it needs to send config data
        state_set_send_callback(
            state,
            { pubkey, dataPtr, dataLen, responseCallback, appCtx, callbackCtx in
                let response: String = """
                    {"results":[
                        {"code":200,"body":{"hash": "fakehash1"}},
                        {"code":200,"body":{"hash": "fakehash2"}},
                        {"code":200,"body":{"hash": "fakehash3"}},
                        {"code":200,"body":{"hash": "fakehash4"}},
                        {"code":200,"body":{"hash": "fakehash5"}},
                        {"code":200,"body":{"hash": "fakehash6"}}
                    ]}
                """
                var cData: [UInt8] = response.data(using: .utf8)!.cArray
                _ = responseCallback?(true, 200, &cData, cData.count, callbackCtx)
            },
            nil
        )
    }
}
