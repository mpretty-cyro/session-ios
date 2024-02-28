// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

public extension LibSession {
    class StateManager: StateManagerType {
        private let dependencies: Dependencies
        internal let state: UnsafeMutablePointer<state_object>
        private let userSessionId: SessionId
        private var afterSendCallbacks: [String: [UUID: (Error?) -> ()]] = [:]
        
        public var hasPendingSend: Bool {
            return state_has_pending_send(state)
        }
        
        // MARK: - Initialization
        
        init(_ db: Database, using dependencies: Dependencies) throws {
            // Ensure we have the ed25519 key and that we haven't already loaded the state before
            // we continue
            guard let ed25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db, using: dependencies) else {
                throw LibSessionError.userDoesNotExist
            }
            
            // Retrieve the existing dumps from the database and load them into the state
            let dumps: [ConfigDump] = Array(try ConfigDump.fetchSet(db))
            let cPubkeys: [UnsafePointer<CChar>?] = dumps
                .map { dump in dump.sessionId.hexString.cArray }
                .unsafeCopy()
            let cDumpData: [UnsafePointer<UInt8>?] = dumps
                .map { dump in Array(dump.data) }
                .unsafeCopy()
            var cDumps: [state_namespaced_dump] = try dumps.enumerated().map { index, dump in
                state_namespaced_dump(
                    namespace_: try dump.variant.cNamespace,
                    pubkey_hex: cPubkeys[index],
                    data: cDumpData[index],
                    datalen: dump.data.count
                )
            }
            
            // Initialise the state
            var maybeState: UnsafeMutablePointer<state_object>? = nil
            var secretKey: [UInt8] = ed25519KeyPair.secretKey
            var error: [CChar] = [CChar](repeating: 0, count: 256)
            
            guard
                state_init(&maybeState, &secretKey, &cDumps, cDumps.count, &error),
                let state: UnsafeMutablePointer<state_object> = maybeState
            else {
                cPubkeys.forEach { $0?.deallocate() }
                cDumpData.forEach { $0?.deallocate() }
                throw LibSessionError(error)
            }
            
            self.dependencies = dependencies
            self.state = state
            self.userSessionId = getUserSessionId(db, using: dependencies)
            cPubkeys.forEach { $0?.deallocate() }
            cDumpData.forEach { $0?.deallocate() }
            
            // Set the current snode timestamp (incase a request was made before this was called)
            setServiceNodeOffset(dependencies[cache: .snodeAPI].clockOffsetMs)
            
            // If an error occurred during any setup process then we want to throw it
            switch self.lastError() {
                case .some(let error): throw error
                case .none: SNLog("[LibSession] Completed loadState")
            }
        }
        
        deinit {
            state_free(state)
        }
        
        // MARK: - Internal Functions
        
        private func store(
            _ namespace: NAMESPACE,
            _ pubkey: UnsafePointer<CChar>?,
            _ timestamp_ms: UInt64,
            _ dataPtr: UnsafePointer<UInt8>?,
            _ dataLen: Int
        ) {
            guard
                let variant: ConfigDump.Variant = ConfigDump.Variant(cNamespace: namespace),
                let sessionIdHex: String = pubkey.map({ String(cString: $0) }),
                dataLen > 0,
                let dumpData: Data = dataPtr.map({ Data(bytes: $0, count: dataLen) })
            else { return SNLog("[LibSession] Failed to store due to invalid parameters") }
            
            dependencies[singleton: .storage].writeAsync(
                updates: { [state, dependencies] db in
                    // Save the updated dump to the database
                    try ConfigDump(
                        variant: variant,
                        sessionId: sessionIdHex,
                        data: dumpData,
                        timestampMs: Int64(timestamp_ms)
                    ).upsert(db)
                    
                    // Apply the updated states to the database
                    switch variant {
                        case .userProfile:
                            try LibSession.handleUserProfileUpdate(
                                db,
                                in: state,
                                serverTimestampMs: Int64(timestamp_ms),
                                using: dependencies
                            )
                            
                            case .contacts:
                                try LibSession.handleContactsUpdate(
                                    db,
                                    in: state,
                                    serverTimestampMs: Int64(timestamp_ms),
                                    using: dependencies
                                )
    
                            case .convoInfoVolatile:
                                try LibSession.handleConvoInfoVolatileUpdate(
                                    db,
                                    in: state,
                                    using: dependencies
                                )

                            case .userGroups:
                                try LibSession.handleUserGroupsUpdate(
                                    db,
                                    in: state,
                                    serverTimestampMs: Int64(timestamp_ms),
                                    using: dependencies
                                )
    
                            case .groupInfo:
                                try LibSession.handleGroupInfoUpdate(
                                    db,
                                    in: state,
                                    groupSessionId: SessionId(.group, hex: sessionIdHex),
                                    serverTimestampMs: Int64(timestamp_ms),
                                    using: dependencies
                                )
    
                                case .groupMembers:
                                    try LibSession.handleGroupMembersUpdate(
                                        db,
                                        in: state,
                                        groupSessionId: SessionId(.group, hex: sessionIdHex),
                                        serverTimestampMs: Int64(timestamp_ms),
                                        using: dependencies
                                    )
    
                                case .groupKeys:
                                    try LibSession.handleGroupKeysUpdate(
                                        in: state,
                                        groupSessionId: SessionId(.group, hex: sessionIdHex),
                                        using: dependencies
                                    )
    
                            case .invalid: SNLog("[libSession] Failed to process merge of invalid config namespace")
                    }
                },
                completion: { _, result in
                    switch result {
                        case .success: break
                        case .failure(let error):
                            SNLog("[LibSession] Failed to store updated state of \(variant) due to error: \(error)")
                    }
                }
            )
        }
        
        private func send(
            _ pubkey: UnsafePointer<CChar>?,
            _ dataPtr: UnsafePointer<UInt8>?,
            _ dataLen: Int,
            _ responseCallback: ((Bool, Int16, UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Bool)?,
            _ callbackCtx: UnsafeMutableRawPointer?
        ) {
            guard
                dataLen > 0,
                let publicKey: String = pubkey.map({ String(cString: $0) }),
                let payloadData: Data = dataPtr.map({ Data(bytes: $0, count: dataLen) })
            else {
                // MUST always call the 'responseCallback' even if we don't sent
                _ = responseCallback?(false, -1, nil, 0, callbackCtx)
                return SNLog("[LibSession] Failed to send due to invalid parameters")
            }
            
            guard
                let preparedRequest = try? SnodeAPI.preparedRawSequenceRequest(
                    publicKey: publicKey,
                    payload: payloadData,
                    using: dependencies
                ),
                let targetQueue: DispatchQueue = dependencies[singleton: .jobRunner].queue(for: .configurationSync)
            else {
                // MUST always call the 'responseCallback' even if we don't sent
                _ = responseCallback?(false, -1, nil, 0, callbackCtx)
                return SNLog("[LibSession] Failed to send due to invalid prepared request")
            }
            
            let requestId: UUID = UUID()
            SNLog("[LibSession - Send] Sending for \(publicKey) (reqId: \(requestId))")
            preparedRequest
                .send(using: dependencies)
                .subscribe(on: targetQueue, using: dependencies)
                .receive(on: targetQueue, using: dependencies)
                .catch { error in
                    // MUST call the 'responseCallback' with the failure as well (need to do this here because
                    // if 'responseCallback' throws in the next 'tryMap' it'd already be freed and crash)
                    _ = responseCallback?(false, -1, nil, 0, callbackCtx)
                    return Fail<(ResponseInfoType, Data), Error>(error: error).eraseToAnyPublisher()
                }
                .tryMap { [lastErrorForced] info, data in
                    var cData: [UInt8] = Array(data)
                    
                    guard responseCallback?(true, Int16(info.code), &cData, cData.count, callbackCtx) == true else {
                        throw lastErrorForced()
                    }
                    
                    return Just(())
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                .sinkUntilComplete(
                    receiveCompletion: { [weak self] result in
                        let afterSendCallbacks: [(Error?) -> ()] = (self?.afterSendCallbacks
                            .removeValue(forKey: publicKey)?
                            .values
                            .asArray())
                            .defaulting(to: [])
                        
                        switch result {
                            case .finished:
                                SNLog("[LibSession - Send] Completed for \(publicKey) (reqId: \(requestId))")
                                afterSendCallbacks.forEach { $0(nil) }
                                
                            case .failure(let error):
                                SNLog("[LibSession - Send] For \(publicKey) (reqId: \(requestId)) failed due to error: \(error)")
                                afterSendCallbacks.forEach { $0(error) }
                        }
                    }
                )
        }
        
        // MARK: - Functions
        
        public func lastError() -> LibSessionError? {
            guard state.pointee.last_error != nil else { return nil }
            
            let errorString = String(cString: state.pointee.last_error)
            state.pointee.last_error = nil // Clear the last error so subsequent calls don't get confused
            return LibSessionError(errorString)
        }
        
        public func lastErrorForced() -> LibSessionError {
            return (lastError() ?? .unknown)
        }
        
        /// Once the migrations have completed we need to inform libSession so it can register it's hooks and trigger any pending 'send' and 'store' calls
        public func registerHooks() throws {
            // Register hooks to make API calls and write to the database when libSession needs to
            func manager(_ context: UnsafeMutableRawPointer?, _ hookName: String) -> StateManager? {
                guard let manager: StateManager = context.map({ Unmanaged<StateManager>.fromOpaque($0).takeUnretainedValue() }) else {
                    SNLog("[LibSession] Failed to \(hookName) due to invalid context")
                    return nil
                }
                
                return manager
            }
            
            // Register a hook to be called when libSession logs anything so the logs can be added
            // to the device logs
            state_set_logger(
                state,
                { logLevel, messagePtr, _ in
                    guard
                        let messagePtr = messagePtr
                    else { return }

                    let message: String = String(cString: messagePtr)
                    SNLog("[LibSession] \(message)")
                },
                nil
            )
            
            // Register a hook to be called when libSession decides it needs to save config data
            let storeResult: Bool = state_set_store_callback(
                state,
                { namespace, pubkey, timestamp_ms, dataPtr, dataLen, context in
                    manager(context, "store")?.store(namespace, pubkey, timestamp_ms, dataPtr, dataLen)
                },
                Unmanaged.passUnretained(self).toOpaque()
            )
            
            // Register a hook to be called when libSession decides it needs to send config data
            let sendResult: Bool = state_set_send_callback(
                state,
                { pubkey, dataPtr, dataLen, responseCallback, appCtx, callbackCtx in
                    manager(appCtx, "send")?.send(pubkey, dataPtr, dataLen, responseCallback, callbackCtx)
                },
                Unmanaged.passUnretained(self).toOpaque()
            )
            
            // Ensure the hooks were successfully set
            guard storeResult && sendResult else { throw lastErrorForced() }
        }
        
        public func setServiceNodeOffset(_ offset: Int64) {
            state_set_service_node_offset(state, offset)
        }
        
        public func mutate(mutation: @escaping (UnsafeMutablePointer<mutable_user_state_object>) throws -> Void) throws {
            class CWrapper {
                let mutation: (UnsafeMutablePointer<mutable_user_state_object>) throws -> Void
                
                public init(_ mutation: @escaping (UnsafeMutablePointer<mutable_user_state_object>) throws -> Void) {
                    self.mutation = mutation
                }
            }
            
            let mutationWrapper: CWrapper = CWrapper(mutation)
            let cWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(mutationWrapper).toOpaque()
            
            state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                guard
                    let mutable_state: UnsafeMutablePointer<mutable_user_state_object> = maybe_mutable_state,
                    let ctx: UnsafeMutableRawPointer = maybeCtx
                else { return }
                
                do { try Unmanaged<CWrapper>.fromOpaque(ctx).takeRetainedValue().mutation(mutable_state) }
                catch {
                    var cError: [CChar] = error.localizedDescription.cArray
                    mutable_user_state_set_error_if_empty(mutable_state, &cError, cError.count)
                }
            }, cWrapperPtr)
            
            if let lastError: LibSessionError = self.lastError() {
                throw lastError
            }
        }
        
        public func mutate(groupId: SessionId, mutation: @escaping (UnsafeMutablePointer<mutable_group_state_object>) throws -> Void) throws {
            class CWrapper {
                let mutation: (UnsafeMutablePointer<mutable_group_state_object>) throws -> Void
                
                public init(_ mutation: @escaping (UnsafeMutablePointer<mutable_group_state_object>) throws -> Void) {
                    self.mutation = mutation
                }
            }
            
            let cPubkey: [CChar] = groupId.hexString.cArray
            let mutationWrapper: CWrapper = CWrapper(mutation)
            let cWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(mutationWrapper).toOpaque()
            
            state_mutate_group(state, cPubkey, { maybe_mutable_state, maybeCtx in
                guard
                    let mutable_state: UnsafeMutablePointer<mutable_group_state_object> = maybe_mutable_state,
                    let ctx: UnsafeMutableRawPointer = maybeCtx
                else { return }
                
                do { try Unmanaged<CWrapper>.fromOpaque(ctx).takeRetainedValue().mutation(mutable_state) }
                catch {
                    var cError: [CChar] = error.localizedDescription.cArray
                    mutable_group_state_set_error_if_empty(mutable_state, &cError, cError.count)
                }
            }, cWrapperPtr)
            
            if let lastError: LibSessionError = self.lastError() {
                throw lastError
            }
        }
        
        @discardableResult public func afterNextSend(groupId: SessionId?, closure: @escaping (Error?) -> ()) -> UUID {
            let closureId: UUID = UUID()
            let key: String = (groupId ?? userSessionId).hexString
            afterSendCallbacks[key] = (afterSendCallbacks[key] ?? [:]).setting(closureId, closure)
            
            return closureId
        }
        
        public func removeAfterNextSend(groupId: SessionId?, closureId: UUID) {
            let key: String = (groupId ?? userSessionId).hexString
            afterSendCallbacks[key]?.removeValue(forKey: closureId)
            
            if afterSendCallbacks[key]?.isEmpty != false {
                afterSendCallbacks.removeValue(forKey: key)
            }
        }
        
        public func merge<T>(sessionIdHexString: String, messages: [T]) throws {
            guard !messages.isEmpty else { return }
            guard let messages: [ConfigMessageReceiveJob.Details.MessageInfo] = messages as? [ConfigMessageReceiveJob.Details.MessageInfo] else {
                throw LibSessionError.cannotMergeInvalidMessageType
            }
            
            let cPubkey: [CChar] = sessionIdHexString.cArray
            let cMessageHashes: [UnsafePointer<CChar>?] = messages
                .map { message in message.serverHash.cArray }
                .unsafeCopy()
            let cMessagesData: [UnsafePointer<UInt8>?] = messages
                .map { message in Array(message.data) }
                .unsafeCopy()
            var cConfigMessages: [state_config_message] = try messages.enumerated()
                .map { index, message in
                    state_config_message(
                        namespace_: try message.namespace.cNamespace,
                        hash: cMessageHashes[index],
                        timestamp_ms: UInt64(message.serverTimestampMs),
                        data: cMessagesData[index],
                        datalen: message.data.count
                    )
                }
            defer {
                cMessageHashes.forEach { $0?.deallocate() }
                cMessagesData.forEach { $0?.deallocate() }
            }
            
            guard state_merge(state, cPubkey, &cConfigMessages, cConfigMessages.count, nil) else {
                throw lastErrorForced()
            }
        }
        
        public func currentHashes(sessionId: String) -> [String] {
            let cPubkey: [CChar] = sessionId.cArray
            var cCurrentHashes: UnsafeMutablePointer<session_string_list>?
            
            guard state_current_hashes(state, cPubkey, &cCurrentHashes) else {
                return []
            }

            let result: [String] = (cCurrentHashes
                .map { [String](pointer: $0.pointee.value, count: $0.pointee.len, defaultValue: []) })
                .defaulting(to: [])
            cCurrentHashes?.deallocate()
            
            return result
        }
    }
}

public extension LibSession {
    // MARK: - Loading
    
    static func loadState(_ db: Database, using dependencies: Dependencies) {
        // When running unit tests we will have explicitly set the dependency so don't want to override it
        guard !SNUtilitiesKit.isRunningTests else { return }
        
        do { dependencies.set(singleton: .libSession, to: try StateManager(db, using: dependencies)) }
        catch { SNLog("[LibSession] loadState failed due to error: \(error)") }
    }
    
    static func clearMemoryState(using dependencies: Dependencies) {
        dependencies.set(singleton: .libSession, to: LibSession.NoopStateManager())
    }
}

// MARK: - Convenience

public extension LibSession {
    static func parseCommunity(url: String) -> (room: String, server: String, publicKey: String)? {
        var cFullUrl: [CChar] = url.cArray.nullTerminated()
        var cBaseUrl: [CChar] = [CChar](repeating: 0, count: LibSession.sizeMaxCommunityBaseUrlBytes)
        var cRoom: [CChar] = [CChar](repeating: 0, count: LibSession.sizeMaxCommunityRoomBytes)
        var cPubkey: [UInt8] = [UInt8](repeating: 0, count: LibSession.sizeCommunityPubkeyBytes)
        
        guard
            community_parse_full_url(&cFullUrl, &cBaseUrl, &cRoom, &cPubkey) &&
            !String(cString: cRoom).isEmpty &&
            !String(cString: cBaseUrl).isEmpty &&
            cPubkey.contains(where: { $0 != 0 })
        else { return nil }
        
        // Note: Need to store them in variables instead of returning directly to ensure they
        // don't get freed from memory early (was seeing this happen intermittently during
        // unit tests...)
        let room: String = String(cString: cRoom)
        let baseUrl: String = String(cString: cBaseUrl)
        let pubkeyHex: String = Data(cPubkey).toHexString()
        
        return (room, baseUrl, pubkeyHex)
    }
    
    static func communityUrlFor(server: String, roomToken: String, publicKey: String) -> String {
        var cBaseUrl: [CChar] = server.cArray.nullTerminated()
        var cRoom: [CChar] = roomToken.cArray.nullTerminated()
        var cPubkey: [UInt8] = Data(hex: publicKey).cArray
        var cFullUrl: [CChar] = [CChar](repeating: 0, count: COMMUNITY_FULL_URL_MAX_LENGTH)
        community_make_full_url(&cBaseUrl, &cRoom, &cPubkey, &cFullUrl)
        
        return String(cString: cFullUrl)
    }
}

// MARK: - Convenience

private extension SessionId {
    init(hex: String, dumpVariant: ConfigDump.Variant) {
        switch (try? SessionId(from: hex), dumpVariant) {
            case (.some(let sessionId), _): self = sessionId
            case (_, .userProfile), (_, .contacts), (_, .convoInfoVolatile), (_, .userGroups):
                self = SessionId(.standard, hex: hex)
                
            case (_, .groupInfo), (_, .groupMembers), (_, .groupKeys):
                self = SessionId(.group, hex: hex)
                
            case (_, .invalid): self = SessionId.invalid
        }
    }
}

private extension ConfigDump.Variant {
    init?(cNamespace: NAMESPACE) {
        switch cNamespace {
            case NAMESPACE_CONTACTS: self = .contacts
            case NAMESPACE_CONVO_INFO_VOLATILE: self = .convoInfoVolatile
            case NAMESPACE_USER_GROUPS: self = .userGroups
            case NAMESPACE_USER_PROFILE: self = .userProfile
                
            case NAMESPACE_GROUP_INFO: self = .groupInfo
            case NAMESPACE_GROUP_MEMBERS: self = .groupMembers
            case NAMESPACE_GROUP_KEYS: self = .groupKeys
            default: return nil
        }
    }
    
    var cNamespace: NAMESPACE {
        get throws {
            switch self {
                case .contacts: return NAMESPACE_CONTACTS
                case .convoInfoVolatile: return NAMESPACE_CONVO_INFO_VOLATILE
                case .userGroups: return NAMESPACE_USER_GROUPS
                case .userProfile: return NAMESPACE_USER_PROFILE
                    
                case .groupInfo: return NAMESPACE_GROUP_INFO
                case .groupMembers: return NAMESPACE_GROUP_MEMBERS
                case .groupKeys: return NAMESPACE_GROUP_KEYS
                default: throw LibSessionError.invalidState
            }
        }
    }
}

private extension SnodeAPI.Namespace {
    var cNamespace: SessionUtil.NAMESPACE {
        get throws {
            switch self {
                case .configContacts: return NAMESPACE_CONTACTS
                case .configConvoInfoVolatile: return NAMESPACE_CONVO_INFO_VOLATILE
                case .configUserGroups: return NAMESPACE_USER_GROUPS
                case .configUserProfile: return NAMESPACE_USER_PROFILE
                    
                case .configGroupInfo: return NAMESPACE_GROUP_INFO
                case .configGroupMembers: return NAMESPACE_GROUP_MEMBERS
                case .configGroupKeys: return NAMESPACE_GROUP_KEYS
                default: throw CryptoError.failedToGenerateOutput
            }
        }
    }
}
