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
        let state: UnsafeMutablePointer<state_object>
        
        var lastError: LibSessionError? {
            guard state.pointee.last_error != nil else { return nil }
            
            let errorString = String(cString: state.pointee.last_error)
            return LibSessionError.libSessionError(errorString)
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
                throw LibSessionError.libSessionError(String(cString: error))
            }
            
            self.dependencies = dependencies
            self.state = state
            cPubkeys.forEach { $0?.deallocate() }
            cDumpData.forEach { $0?.deallocate() }
            
            // Set the current snode timestamp (incase a request was made before this was called)
            setServiceNodeOffset(dependencies[cache: .snodeAPI].clockOffsetMs)
            
            // If an error occurred during any setup process then we want to throw it
            switch self.lastError {
                case .some(let error): throw error
                case .none: SNLog("[LibSession] Completed loadState")
            }
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
                            case .invalid: SNLog("[libSession] Failed to process merge of invalid config namespace")
                            
                        default:
                            break
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
            _ requestCtxPtr: UnsafePointer<UInt8>?,
            _ requestCtxLen: Int
        ) {// TODO: Determine why this is called twice on a name change
            guard
                dataLen > 0,
                let publicKeyPtr: UnsafePointer<CChar> = pubkey,
                let publicKey: String = pubkey.map({ String(cString: $0) }),
                let payloadData: Data = dataPtr.map({ Data(bytes: $0, count: dataLen) }),
                let requestCtx: Data = requestCtxPtr.map({ Data(bytes: $0, count: requestCtxLen) })
            else { return SNLog("[LibSession] Failed to send due to invalid parameters") }
            
            guard
                let preparedRequest = try? SnodeAPI.preparedRawSequenceRequest(
                    publicKey: publicKey,
                    payload: payloadData,
                    using: dependencies
                ),
                let targetQueue: DispatchQueue = dependencies[singleton: .jobRunner].queue(for: .configurationSync)
            else { return SNLog("[LibSession] Failed to send due to invalid prepared request") }
            
            preparedRequest
                .send(using: dependencies)
                .subscribe(on: targetQueue, using: dependencies)
                .receive(on: targetQueue, using: dependencies)
                .tryMap { [weak self, state] info, data in
                    var cResponseData: [UInt8] = Array(data)
                    var cRequestCtx: [UInt8] = Array(requestCtx)
                    
                    guard state_received_send_response(state, publicKeyPtr, &cResponseData, cResponseData.count, &cRequestCtx, cRequestCtx.count) else {
                        throw (self?.lastError ?? LibSessionError.unknown)
                    }
                    
                    return Just(())
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                .sinkUntilComplete(
                    receiveCompletion: { result in
                        switch result {
                            case .finished: SNLog("[LibSession - Send] Completed for \(publicKey) (reqId: \(requestId))")
                            case .failure(let error):
                                SNLog("[LibSession - Send] For \(publicKey) (reqId: \(requestId)) failed due to error: \(error)")
                        }
                    }
                )
        }
        
        // MARK: - Functions
        
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
                { pubkey, dataPtr, dataLen, requestCtxPtr, requestCtxLen, context in
                    manager(context, "send")?.send(pubkey, dataPtr, dataLen, requestCtxPtr, requestCtxLen)
                },
                Unmanaged.passUnretained(self).toOpaque()
            )
            
            // Ensure the hooks were successfully set
            guard storeResult && sendResult else { throw lastError ?? LibSessionError.unknown }
        }
        
        public func setServiceNodeOffset(_ offset: Int64) {
            state_set_service_node_offset(state, offset)
        }
        
        private func performMutation(mutation: @escaping (UnsafeMutablePointer<mutable_state_user_object>) throws -> Void) throws {
            class CWrapper {
                let mutation: (UnsafeMutablePointer<mutable_state_user_object>) throws -> Void
                
                public init(_ mutation: @escaping (UnsafeMutablePointer<mutable_state_user_object>) throws -> Void) {
                    self.mutation = mutation
                }
            }
            
            let mutationWrapper: CWrapper = CWrapper(mutation)
            let cWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(mutationWrapper).toOpaque()
            
            state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                guard
                    let mutable_state: UnsafeMutablePointer<mutable_state_user_object> = maybe_mutable_state,
                    let ctx: UnsafeMutableRawPointer = maybeCtx
                else { return }
                
                do { try Unmanaged<CWrapper>.fromOpaque(ctx).takeRetainedValue().mutation(mutable_state) }
                catch {
                    var cError: [CChar] = error.localizedDescription.cArray
                    mutable_state_user_set_error_if_empty(mutable_state, &cError, cError.count)
                }
            }, cWrapperPtr)
            
            if let lastError: LibSessionError = self.lastError {
                throw lastError
            }
        }
        
        private func performMutation(groupId: SessionId, mutation: @escaping (UnsafeMutablePointer<mutable_state_group_object>) throws -> Void) throws {
            class CWrapper {
                let mutation: (UnsafeMutablePointer<mutable_state_group_object>) throws -> Void
                
                public init(_ mutation: @escaping (UnsafeMutablePointer<mutable_state_group_object>) throws -> Void) {
                    self.mutation = mutation
                }
            }
            
            var cPubkey: [CChar] = groupId.hexString.cArray
            let mutationWrapper: CWrapper = CWrapper(mutation)
            let cWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(mutationWrapper).toOpaque()
            
            state_mutate_group(state, &cPubkey, { maybe_mutable_state, maybeCtx in
                guard
                    let mutable_state: UnsafeMutablePointer<mutable_state_group_object> = maybe_mutable_state,
                    let ctx: UnsafeMutableRawPointer = maybeCtx
                else { return }
                
                do { try Unmanaged<CWrapper>.fromOpaque(ctx).takeRetainedValue().mutation(mutable_state) }
                catch {
                    var cError: [CChar] = error.localizedDescription.cArray
                    mutable_state_group_set_error_if_empty(mutable_state, &cError, cError.count)
                }
            }, cWrapperPtr)
            
            if let lastError: LibSessionError = self.lastError {
                throw lastError
            }
        }
        
        public func mutate(mutation: @escaping (UnsafeMutablePointer<mutable_state_user_object>) -> Void) {
            try? performMutation(mutation: mutation)
        }
        
        public func mutate(mutation: @escaping (UnsafeMutablePointer<mutable_state_user_object>) throws -> Void) throws {
            try performMutation(mutation: mutation)
        }
        
        public func mutate(groupId: SessionId, mutation: @escaping (UnsafeMutablePointer<mutable_state_group_object>) -> Void) {
            try? performMutation(groupId: groupId, mutation: mutation)
        }
        
        public func mutate(groupId: SessionId, mutation: @escaping (UnsafeMutablePointer<mutable_state_group_object>) throws -> Void) throws {
            try performMutation(groupId: groupId, mutation: mutation)
        }
        
        public func merge<T>(sessionIdHexString: String, messages: [T]) throws {
            guard !messages.isEmpty else { return }
            guard let messages: [ConfigMessageReceiveJob.Details.MessageInfo] = messages as? [ConfigMessageReceiveJob.Details.MessageInfo] else {
                throw LibSessionError.cannotMergeInvalidMessageType
            }
            
            let cMessageHashes: [UnsafePointer<CChar>?] = messages
                .map { message in message.serverHash.cArray }
                .unsafeCopy()
            let cMessagesData: [UnsafePointer<UInt8>?] = messages
                .map { message in Array(message.data) }
                .unsafeCopy()
            var configMessages: [state_config_message] = try messages.enumerated()
                .map { index, message in
                    state_config_message(
                        namespace_: try message.namespace.cNamespace,
                        hash: cMessageHashes[index],
                        timestamp_ms: UInt64(message.serverTimestampMs),
                        data: cMessagesData[index],
                        datalen: message.data.count
                    )
                }
            
            var pubkeyHex: [CChar] = sessionIdHexString.cArray
            var cMergedHashesPtr: UnsafeMutablePointer<config_string_list>?
            
            guard state_merge(state, &pubkeyHex, &configMessages, configMessages.count, &cMergedHashesPtr) else {
                throw lastError ?? LibSessionError.unknown
            }
            
            let mergedHashes: [String] = cMergedHashesPtr
                .map { ptr in
                    [String](
                        pointer: ptr.pointee.value,
                        count: ptr.pointee.len,
                        defaultValue: []
                    )
                }
                .defaulting(to: [])
            cMessageHashes.forEach { $0?.deallocate() }
            cMessagesData.forEach { $0?.deallocate() }
            cMergedHashesPtr?.deallocate()
        }
    }
}

public extension LibSession {
    // MARK: - Variables
    
    internal static func syncDedupeId(_ sessionIdHexString: String) -> String {
        return "EnqueueConfigurationSyncJob-\(sessionIdHexString)"   // stringlint:disable
    }    
    
    // MARK: - Loading
    
    static func loadState(_ db: Database, using dependencies: Dependencies) {
        do { dependencies.set(singleton: .libSession, to: try StateManager(db, using: dependencies)) }
        catch { SNLog("[LibSession] loadState failed due to error: \(error)") }
    }
    
    static func clearMemoryState(using dependencies: Dependencies) {
        dependencies.set(singleton: .libSession, to: LibSession.NoopStateManager())
    }
    
    internal static func createDump(
        config: Config?,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        timestampMs: Int64,
        using dependencies: Dependencies
    ) throws -> ConfigDump? {
        // If it doesn't need a dump then do nothing
        guard
            config.needsDump(using: dependencies),
            let dumpData: Data = try config?.dump()
        else { return nil }
        
        return ConfigDump(
            variant: variant,
            sessionId: sessionId.hexString,
            data: dumpData,
            timestampMs: timestampMs
        )
    }
    
    // MARK: - Pushes
    
    static func pendingChanges(
        _ db: Database,
        sessionIdHexString: String,
        using dependencies: Dependencies
    ) throws -> [PushData] {
        guard Identity.userExists(db, using: dependencies) else { throw LibSessionError.userDoesNotExist }
        
        // Get a list of the different config variants for the provided publicKey
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        let targetVariants: [(sessionId: SessionId, variant: ConfigDump.Variant)] = {
            switch (sessionIdHexString, try? SessionId(from: sessionIdHexString)) {
                case (userSessionId.hexString, _):
                    return ConfigDump.Variant.userVariants.map { (userSessionId, $0) }
                    
                case (_, .some(let sessionId)) where sessionId.prefix == .group:
                    return ConfigDump.Variant.groupVariants.map { (sessionId, $0) }
                    
                default: return []
            }
        }()
        
        // Extract any pending changes from the cached config entry for each variant
        return try targetVariants
            .sorted { (lhs: (SessionId, ConfigDump.Variant), rhs: (SessionId, ConfigDump.Variant)) in
                lhs.1.sendOrder < rhs.1.sendOrder
            }
            .compactMap { sessionId, variant -> PushData? in
                try dependencies[cache: .libSession]
                    .config(for: variant, sessionId: sessionId)
                    .wrappedValue
                    .map { config -> PushData? in
                        // Check if the config needs to be pushed
                        guard config.needsPush else { return nil }
                        
                        return try Result(config.push(variant: variant))
                            .onFailure { error in
                                let configCountInfo: String = config.count(for: variant)
                                
                                SNLog("[LibSession] Failed to generate push data for \(variant) config data, size: \(configCountInfo), error: \(error)")
                            }
                            .successOrThrow()
                    }
            }
    }
    
    static func markingAsPushed(
        seqNo: Int64,
        serverHash: String,
        sentTimestamp: Int64,
        variant: ConfigDump.Variant,
        sessionIdHexString: String,
        using dependencies: Dependencies
    ) -> ConfigDump? {
        let sessionId: SessionId = SessionId(hex: sessionIdHexString, dumpVariant: variant)
        
        return dependencies[cache: .libSession]
            .config(for: variant, sessionId: sessionId)
            .mutate { config -> ConfigDump? in
                guard config != nil else { return nil }
                
                // Mark the config as pushed
                config?.confirmPushed(seqNo: seqNo, hash: serverHash)
                
                // Update the result to indicate whether the config needs to be dumped
                guard config.needsPush else { return nil }
                
                return try? LibSession.createDump(
                    config: config,
                    for: variant,
                    sessionId: sessionId,
                    timestampMs: sentTimestamp,
                    using: dependencies
                )
            }
    }
    
    static func configHashes(
        for sessionIdHexString: String,
        using dependencies: Dependencies
    ) -> [String] {
        return dependencies[singleton: .storage]
            .read { db -> Set<ConfigDump.Variant> in
                guard Identity.userExists(db) else { return [] }
                
                return try ConfigDump
                    .select(.variant)
                    .filter(ConfigDump.Columns.publicKey == sessionIdHexString)
                    .asRequest(of: ConfigDump.Variant.self)
                    .fetchSet(db)
            }
            .defaulting(to: [])
            .map { variant -> [String] in
                /// Extract all existing hashes for any dumps associated with the given `sessionIdHexString`
                dependencies[cache: .libSession]
                    .config(for: variant, sessionId: SessionId(hex: sessionIdHexString, dumpVariant: variant))
                    .wrappedValue
                    .map { $0.currentHashes() }
                    .defaulting(to: [])
            }
            .reduce([], +)
    }
    
    // MARK: - Receiving
    
    static func handleConfigMessages(
        _ db: Database,
        sessionIdHexString: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo],
        using dependencies: Dependencies = Dependencies()
    ) throws {
        guard !messages.isEmpty else { return }
        
        do {
            try dependencies[singleton: .libSession].merge(sessionIdHexString: sessionIdHexString, messages: messages)
        }
        catch {
        }
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

private extension Optional where Wrapped == Int32 {
    func toConfig(
        _ maybeConf: UnsafeMutablePointer<config_object>?,
        variant: ConfigDump.Variant,
        error: [CChar]
    ) throws -> LibSession.Config {
        guard self == 0, let conf: UnsafeMutablePointer<config_object> = maybeConf else {
            SNLog("[LibSession Error] Unable to create \(variant.rawValue) config object: \(String(cString: error))")
            throw LibSessionError.unableToCreateConfigObject
        }
        
        switch variant {
            case .userProfile, .contacts, .convoInfoVolatile,
                .userGroups, .groupInfo, .groupMembers:
                return .object(conf)
            
            case .groupKeys, .invalid: throw LibSessionError.unableToCreateConfigObject
        }
    }
}

private extension Int32 {
    func toConfig(
        _ maybeConf: UnsafeMutablePointer<config_group_keys>?,
        info: UnsafeMutablePointer<config_object>,
        members: UnsafeMutablePointer<config_object>,
        variant: ConfigDump.Variant,
        error: [CChar]
    ) throws -> LibSession.Config {
        guard self == 0, let conf: UnsafeMutablePointer<config_group_keys> = maybeConf else {
            SNLog("[LibSession Error] Unable to create \(variant.rawValue) config object: \(String(cString: error))")
            throw LibSessionError.unableToCreateConfigObject
        }

        switch variant {
            case .groupKeys: return .groupKeys(conf, info: info, members: members)
            default: throw LibSessionError.unableToCreateConfigObject
        }
    }
}

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

// MARK: - LibSession Cache

public extension LibSession {
    class Cache: LibSessionCacheType {
        public struct Key: Hashable {
            let variant: ConfigDump.Variant
            let sessionId: SessionId
        }
        
        private var configStore: [LibSession.Cache.Key: Atomic<LibSession.Config?>] = [:]
        
        public var isEmpty: Bool { configStore.isEmpty }
        
        /// Returns `true` if there is a config which needs to be pushed, but returns `false` if the configs are all up to date or haven't been
        /// loaded yet (eg. fresh install)
        public var needsSync: Bool { configStore.contains { _, atomicConf in atomicConf.needsPush } }
        
        // MARK: - Functions
        
        public func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: LibSession.Config?) {
            configStore[Key(variant: variant, sessionId: sessionId)] = config.map { Atomic($0) }
        }
        
        public func config(
            for variant: ConfigDump.Variant,
            sessionId: SessionId
        ) -> Atomic<Config?> {
            return (
                configStore[Key(variant: variant, sessionId: sessionId)] ??
                Atomic(nil)
            )
        }
        
        public func removeAll() {
            configStore.removeAll()
        }
    }
}

public extension Cache {
    static let libSession: CacheConfig<LibSessionCacheType, LibSessionImmutableCacheType> = Dependencies.create(
        identifier: "libSession",
        createInstance: { _ in LibSession.Cache() },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - LibSessionCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol LibSessionImmutableCacheType: ImmutableCacheType {
    var isEmpty: Bool { get }
    var needsSync: Bool { get }
    
    func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> Atomic<LibSession.Config?>
}

public protocol LibSessionCacheType: LibSessionImmutableCacheType, MutableCacheType {
    var isEmpty: Bool { get }
    var needsSync: Bool { get }
    
    func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: LibSession.Config?)
    func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> Atomic<LibSession.Config?>
    func removeAll()
}

// MARK: - Convenience

public extension LibSessionError {
    init(_ state: UnsafeMutablePointer<state_object>) {
        guard state.pointee.last_error != nil else {
            self = .unknown
            return
        }
        
        let errorString = String(cString: state.pointee.last_error)
        self = LibSessionError.libSessionError(errorString)
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
                default: throw LibSessionError.invalidConfigObject
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
