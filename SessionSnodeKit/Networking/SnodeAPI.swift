// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import PromiseKit
import Sodium
import GRDB
import SessionUtilitiesKit

public final class SnodeAPI {
    internal static let sodium: Atomic<Sodium> = Atomic(Sodium())
    
    private static var hasLoadedSnodePool: Atomic<Bool> = Atomic(false)
    private static var loadedSwarms: Atomic<Set<String>> = Atomic([])
    private static var getSnodePoolPromise: Atomic<Promise<Set<Snode>>?> = Atomic(nil)
    
    /// - Note: Should only be accessed from `Threading.workQueue` to avoid race conditions.
    internal static var snodeFailureCount: Atomic<[Snode: UInt]> = Atomic([:])
    /// - Note: Should only be accessed from `Threading.workQueue` to avoid race conditions.
    internal static var snodePool: Atomic<Set<Snode>> = Atomic([])

    /// The offset between the user's clock and the Service Node's clock. Used in cases where the
    /// user's clock is incorrect.
    ///
    /// - Note: Should only be accessed from `Threading.workQueue` to avoid race conditions.
    public static var clockOffset: Atomic<Int64> = Atomic(0)
    /// - Note: Should only be accessed from `Threading.workQueue` to avoid race conditions.
    public static var swarmCache: Atomic<[String: Set<Snode>]> = Atomic([:])
    
    // MARK: - Hardfork version
    
    public static var hardfork = UserDefaults.standard[.hardfork]
    public static var softfork = UserDefaults.standard[.softfork]

    // MARK: - Settings
    
    private static let maxRetryCount: UInt = 8
    private static let minSwarmSnodeCount: Int = 3
    private static let seedNodePool: Set<String> = {
        guard !Features.useTestnet else {
            return [ "http://public.loki.foundation:38157" ]
        }
        
        return [
            "https://storage.seed1.loki.network:4433",
            "https://storage.seed3.loki.network:4433",
            "https://public.loki.foundation:4433"
        ]
    }()
    private static let snodeFailureThreshold: Int = 3
    private static let targetSwarmSnodeCount: Int = 2
    private static let minSnodePoolCount: Int = 12
    
    private static func offsetTimestampMsNow() -> UInt64 {
        return UInt64(
            Int64(floor(Date().timeIntervalSince1970 * 1000)) +
            SnodeAPI.clockOffset.wrappedValue
        )
    }

    // MARK: Snode Pool Interaction
    
    private static var hasInsufficientSnodes: Bool { snodePool.wrappedValue.count < minSnodePoolCount }
    
    private static func loadSnodePoolIfNeeded() {
        guard !hasLoadedSnodePool.wrappedValue else { return }
        
        let fetchedSnodePool: Set<Snode> = Storage.shared
            .read { db in try Snode.fetchSet(db) }
            .defaulting(to: [])
        
        snodePool.mutate { $0 = fetchedSnodePool }
        hasLoadedSnodePool.mutate { $0 = true }
    }
    
    private static func setSnodePool(to newValue: Set<Snode>, db: Database? = nil) {
        snodePool.mutate { $0 = newValue }
        
        if let db: Database = db {
            _ = try? Snode.deleteAll(db)
            newValue.forEach { try? $0.save(db) }
        }
        else {
            Storage.shared.write { db in
                _ = try? Snode.deleteAll(db)
                newValue.forEach { try? $0.save(db) }
            }
        }
    }
    
    private static func dropSnodeFromSnodePool(_ snode: Snode) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(Threading.workQueue))
        #endif
        var snodePool = SnodeAPI.snodePool.wrappedValue
        snodePool.remove(snode)
        setSnodePool(to: snodePool)
    }
    
    @objc public static func clearSnodePool() {
        snodePool.mutate { $0.removeAll() }
        
        Threading.workQueue.async {
            setSnodePool(to: [])
        }
    }
    
    // MARK: - Swarm Interaction
    
    private static func loadSwarmIfNeeded(for publicKey: String) {
        guard !loadedSwarms.wrappedValue.contains(publicKey) else { return }
        
        let updatedCacheForKey: Set<Snode> = Storage.shared
           .read { db in try Snode.fetchSet(db, publicKey: publicKey) }
           .defaulting(to: [])
        
        swarmCache.mutate { $0[publicKey] = updatedCacheForKey }
        loadedSwarms.mutate { $0.insert(publicKey) }
    }
    
    private static func setSwarm(to newValue: Set<Snode>, for publicKey: String, persist: Bool = true) {
        swarmCache.mutate { $0[publicKey] = newValue }
        
        guard persist else { return }
        
        Storage.shared.write { db in
            try? newValue.save(db, key: publicKey)
        }
    }
    
    public static func dropSnodeFromSwarmIfNeeded(_ snode: Snode, publicKey: String) {
        let swarmOrNil = swarmCache.wrappedValue[publicKey]
        guard var swarm = swarmOrNil, let index = swarm.firstIndex(of: snode) else { return }
        swarm.remove(at: index)
        setSwarm(to: swarm, for: publicKey)
    }

    // MARK: - Public API
    
    public static func hasCachedSnodesInclusingExpired() -> Bool {
        loadSnodePoolIfNeeded()
        
        return !hasInsufficientSnodes
    }
    
    public static func getSnodePool() -> Promise<Set<Snode>> {
        loadSnodePoolIfNeeded()
        let now = Date()
        let hasSnodePoolExpired = given(Storage.shared[.lastSnodePoolRefreshDate]) {
            now.timeIntervalSince($0) > 2 * 60 * 60
        }.defaulting(to: true)
        let snodePool: Set<Snode> = SnodeAPI.snodePool.wrappedValue
        
        guard hasInsufficientSnodes || hasSnodePoolExpired else {
            return Promise.value(snodePool)
        }
        
        if let getSnodePoolPromise = getSnodePoolPromise.wrappedValue { return getSnodePoolPromise }
        
        let promise: Promise<Set<Snode>>
        if snodePool.count < minSnodePoolCount {
            promise = getSnodePoolFromSeedNode()
        }
        else {
            promise = getSnodePoolFromSnode().recover2 { _ in
                getSnodePoolFromSeedNode()
            }
        }
        
        getSnodePoolPromise.mutate { $0 = promise }
        promise.map2 { snodePool -> Set<Snode> in
            guard !snodePool.isEmpty else { throw SnodeAPIError.snodePoolUpdatingFailed }
            
            return snodePool
        }
        
        promise.then2 { snodePool -> Promise<Set<Snode>> in
            let (promise, seal) = Promise<Set<Snode>>.pending()
            
            Storage.shared.writeAsync(
                updates: { db in
                    db[.lastSnodePoolRefreshDate] = now
                    setSnodePool(to: snodePool, db: db)
                },
                completion: { _, _ in
                    seal.fulfill(snodePool)
                }
            )
            
            return promise
        }
        promise.done2 { _ in
            getSnodePoolPromise.mutate { $0 = nil }
        }
        promise.catch2 { _ in
            getSnodePoolPromise.mutate { $0 = nil }
        }
        
        return promise
    }
    
    public static func getSessionID(for onsName: String) -> Promise<String> {
        let validationCount = 3
        
        // The name must be lowercased
        let onsName = onsName.lowercased()
        
        // Hash the ONS name using BLAKE2b
        let nameAsData = [UInt8](onsName.data(using: String.Encoding.utf8)!)
        
        guard let nameHash = sodium.wrappedValue.genericHash.hash(message: nameAsData) else {
            return Promise(error: SnodeAPIError.hashingFailed)
        }
        
        // Ask 3 different snodes for the Session ID associated with the given name hash
        let base64EncodedNameHash = nameHash.toBase64()
        
        let promises = (0..<validationCount).map { _ in
            return getRandomSnode().then2 { snode in
                attempt(maxRetryCount: 4, recoveringOn: Threading.workQueue) {
                    send(
                        request: SnodeRequest(
                            endpoint: .oxenDaemonRPCCall,
                            body: OxenDaemonRPCRequest(
                                endpoint: .daemonOnsResolve,
                                body: ONSResolveRequest(
                                    type: 0, // type 0 means Session
                                    base64EncodedNameHash: base64EncodedNameHash
                                )
                            )
                        ),
                        to: snode,
                        associatedWith: nil
                    )
                    .decoded(as: ONSResolveResponse.self, on: Threading.workQueue)
                }
            }
        }
        let (promise, seal) = Promise<String>.pending()
        
        when(resolved: promises).done2 { results in
            var sessionIDs: [String] = []
            for result in results {
                switch result {
                    case .rejected(let error): return seal.reject(error)
                        
                    case .fulfilled(let responseData):
                        sessionIDs.append(try responseData.1.sessionId(sodium: sodium.wrappedValue, nameBytes: nameAsData, nameHashBytes: nameHash))
                }
            }
            
            guard sessionIDs.count == validationCount && Set(sessionIDs).count == 1 else {
                return seal.reject(SnodeAPIError.validationFailed)
            }
            
            seal.fulfill(sessionIDs.first!)
        }
        
        return promise
    }
    
    public static func getTargetSnodes(for publicKey: String) -> Promise<[Snode]> {
        // shuffled() uses the system's default random generator, which is cryptographically secure
        return getSwarm(for: publicKey).map2 { Array($0.shuffled().prefix(targetSwarmSnodeCount)) }
    }

    public static func getSwarm(
        for publicKey: String,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> Promise<Set<Snode>> {
        loadSwarmIfNeeded(for: publicKey)
        
        if let cachedSwarm = swarmCache.wrappedValue[publicKey], cachedSwarm.count >= minSwarmSnodeCount {
            return Promise<Set<Snode>> { $0.fulfill(cachedSwarm) }
        }
        
        SNLog("Getting swarm for: \((publicKey == getUserHexEncodedPublicKey()) ? "self" : publicKey).")
        let targetPublicKey: String = (Features.useTestnet ?
            publicKey.removingIdPrefixIfNeeded() :
            publicKey
        )
        
        return getRandomSnode()
            .then2 { snode in
                attempt(maxRetryCount: 4, recoveringOn: Threading.workQueue) {
                    SnodeAPI.send(
                        request: SnodeRequest(
                            endpoint: .getSwarm,
                            body: GetSwarmRequest(pubkey: targetPublicKey)
                        ),
                        to: snode,
                        associatedWith: publicKey,
                        using: dependencies
                    )
                }
            }
            .map2 { _, responseData in
                let swarm = parseSnodes(from: responseData)
                
                setSwarm(to: swarm, for: publicKey)
                return swarm
            }
    }

    // MARK: - Retrieve
    
    public static func getMessages(
        in namespaces: [SnodeAPI.Namespace],
        from snode: Snode,
        associatedWith publicKey: String,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> Promise<[SnodeAPI.Namespace: (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?)]> {
        let (promise, seal) = Promise<[SnodeAPI.Namespace: (info: ResponseInfoType, data: (messages: [SnodeReceivedMessage], lastHash: String?)?)]>.pending()
        
        Threading.workQueue.async {
            let targetPublicKey: String = (Features.useTestnet ?
                publicKey.removingIdPrefixIfNeeded() :
                publicKey
            )
            let namespaceLastHash: [SnodeAPI.Namespace: String] = namespaces
                .reduce(into: [:]) { result, namespace in
                    // Prune expired message hashes for this namespace on this service node
                    SnodeReceivedMessageInfo.pruneExpiredMessageHashInfo(
                        for: snode,
                        namespace: namespace,
                        associatedWith: publicKey
                    )
                    
                    let maybeLastHash: String? = SnodeReceivedMessageInfo
                        .fetchLastNotExpired(
                            for: snode,
                            namespace: namespace,
                            associatedWith: publicKey
                        )?
                        .hash
                    
                    guard let lastHash: String = maybeLastHash else { return }
                    
                    result[namespace] = lastHash
                }
            var userED25519KeyPair: Box.KeyPair?
            
            do {
                let requests: [SnodeAPI.BatchRequest.Info] = try namespaces
                    .map { namespace -> SnodeAPI.BatchRequest.Info in
                        // Check if this namespace requires authentication
                        guard namespace.requiresReadAuthentication else {
                            return BatchRequest.Info(
                                request: SnodeRequest(
                                    endpoint: .getMessages,
                                    body: LegacyGetMessagesRequest(
                                        pubkey: targetPublicKey,
                                        lastHash: (namespaceLastHash[namespace] ?? ""),
                                        namespace: namespace
                                    )
                                ),
                                responseType: GetMessagesResponse.self
                            )
                        }
                        
                        // Generate the signature
                        guard let keyPair: Box.KeyPair = (userED25519KeyPair ?? Storage.shared.read { db in Identity.fetchUserEd25519KeyPair(db) }) else {
                            throw SnodeAPIError.signingFailed
                        }
                        
                        userED25519KeyPair = keyPair
                        
                        return BatchRequest.Info(
                            request: SnodeRequest(
                                endpoint: .getMessages,
                                body: GetMessagesRequest(
                                    lastHash: (namespaceLastHash[namespace] ?? ""),
                                    namespace: namespace,
                                    pubkey: targetPublicKey,
                                    subkey: nil,
                                    timestampMs: SnodeAPI.offsetTimestampMsNow(),
                                    ed25519PublicKey: keyPair.publicKey,
                                    ed25519SecretKey: keyPair.secretKey
                                )
                            ),
                            responseType: GetMessagesResponse.self
                        )
                    }
                let responseTypes = requests.map { $0.responseType }
                
                SnodeAPI.send(
                    request: SnodeRequest(
                        endpoint: .batch,
                        body: BatchRequest(requests: requests)
                    ),
                    to: snode,
                    associatedWith: publicKey,
                    using: dependencies
                )
                .decoded(as: responseTypes, on: Threading.workQueue, using: dependencies)
                .map2 { batchResponse -> [SnodeAPI.Namespace: (ResponseInfoType, ([SnodeReceivedMessage], String?)?)] in
                    return zip(namespaces, batchResponse)
                        .reduce(into: [:]) { result, next in
                            guard let messageResponse: GetMessagesResponse = (next.1.1 as? HTTP.BatchSubResponse<GetMessagesResponse>)?.body else {
                                return
                            }
                            
                            let namespace: SnodeAPI.Namespace = next.0
                            let requestInfo: ResponseInfoType = next.1.0
                                    
                            result[namespace] = (
                                requestInfo,
                                (
                                    messageResponse.messages
                                        .compactMap { rawMessage -> SnodeReceivedMessage? in
                                            SnodeReceivedMessage(
                                                snode: snode,
                                                publicKey: publicKey,
                                                namespace: namespace,
                                                rawMessage: rawMessage
                                            )
                                        },
                                    namespaceLastHash[namespace]
                                )
                            )
                        }
                }
                .done2 { seal.fulfill($0) }
                .catch2 { seal.reject($0) }
            }
            catch let error {
                seal.reject(error)
            }
        }
        
        return promise
    }
    
    // MARK: Store
    
    public static func sendMessage(
        _ message: SnodeMessage,
        in namespace: Namespace,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> Promise<Set<Promise<(any ResponseInfoType, SendMessagesResponse)>>> {
        let (promise, seal) = Promise<Set<Promise<(any ResponseInfoType, SendMessagesResponse)>>>.pending()
        let publicKey: String = (Features.useTestnet ?
            message.recipient.removingIdPrefixIfNeeded() :
            message.recipient
        )
        
        Threading.workQueue.async {
            getTargetSnodes(for: publicKey)
                .map2 { targetSnodes -> Set<Promise<(any ResponseInfoType, SendMessagesResponse)>> in
                    targetSnodes
                        .map { targetSnode in
                            attempt(maxRetryCount: maxRetryCount, recoveringOn: Threading.workQueue) {
                                guard namespace.requiresWriteAuthentication else {
                                    return SnodeAPI
                                        .send(
                                            request: SnodeRequest(
                                                endpoint: .sendMessage,
                                                body: LegacySendMessagesRequest(
                                                    message: message,
                                                    namespace: namespace
                                                )
                                            ),
                                            to: targetSnode,
                                            associatedWith: publicKey,
                                            using: dependencies
                                        )
                                        .decoded(as: SendMessagesResponse.self, on: Threading.workQueue, using: dependencies)
                                }
                                
                                guard let userED25519KeyPair: Box.KeyPair = Storage.shared.read({ db in Identity.fetchUserEd25519KeyPair(db) }) else {
                                    return Promise(error: SnodeAPIError.noKeyPair)
                                }
                                
                                return SnodeAPI
                                    .send(
                                        request: SnodeRequest(
                                            endpoint: .sendMessage,
                                            body: SendMessageRequest(
                                                message: message,
                                                namespace: namespace,
                                                subkey: nil,
                                                timestampMs: SnodeAPI.offsetTimestampMsNow(),
                                                ed25519PublicKey: userED25519KeyPair.publicKey,
                                                ed25519SecretKey: userED25519KeyPair.secretKey
                                            )
                                        ),
                                        to: targetSnode,
                                        associatedWith: publicKey,
                                        using: dependencies
                                    )
                                    .decoded(as: SendMessagesResponse.self, on: Threading.workQueue, using: dependencies)
                            }
                        }
                        .asSet()
                }
                .done2 { seal.fulfill($0) }
                .catch2 { seal.reject($0) }
        }
        
        return promise
    }
    
    // MARK: Edit
    
    public static func updateExpiry(
        publicKey: String,
        serverHashes: [String],
        updatedExpiryMs: UInt64,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> Promise<[String: (hashes: [String], expiry: UInt64)]> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Promise(error: SnodeAPIError.noKeyPair)
        }
        
        let publicKey: String = (Features.useTestnet ?
            publicKey.removingIdPrefixIfNeeded() :
            publicKey
        )
        
        return attempt(maxRetryCount: maxRetryCount, recoveringOn: Threading.workQueue) {
            getSwarm(for: publicKey)
                .then2 { swarm -> Promise<[String: (hashes: [String], expiry: UInt64)]> in
                    guard let snode: Snode = swarm.randomElement() else {
                        throw SnodeAPIError.generic
                    }
                    
                    return attempt(maxRetryCount: maxRetryCount, recoveringOn: Threading.workQueue) {
                        return SnodeAPI
                            .send(
                                request: SnodeRequest(
                                    endpoint: .expire,
                                    body: UpdateExpiryRequest(
                                        messageHashes: serverHashes,
                                        expiryMs: updatedExpiryMs,
                                        pubkey: publicKey,
                                        ed25519PublicKey: userED25519KeyPair.publicKey,
                                        ed25519SecretKey: userED25519KeyPair.secretKey,
                                        subkey: nil
                                    )
                                ),
                                to: snode,
                                associatedWith: publicKey,
                                using: dependencies
                            )
                            .decoded(as: UpdateExpiryResponse.self, on: Threading.workQueue, using: dependencies)
                            .map(on: Threading.workQueue) { _, response in
                                try response.validResultMap(
                                    userX25519PublicKey: getUserHexEncodedPublicKey(),
                                    messageHashes: serverHashes,
                                    sodium: sodium.wrappedValue
                                )
                            }
                    }
                }
        }
    }
    
    public static func revokeSubkey(
        publicKey: String,
        subkeyToRevoke: String,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> Promise<Void> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Promise(error: SnodeAPIError.noKeyPair)
        }
        
        let publicKey: String = (Features.useTestnet ?
            publicKey.removingIdPrefixIfNeeded() :
            publicKey
        )
        
        return attempt(maxRetryCount: maxRetryCount, recoveringOn: Threading.workQueue) {
            getSwarm(for: publicKey)
                .then2 { swarm -> Promise<Void> in
                    guard let snode: Snode = swarm.randomElement() else {
                        throw SnodeAPIError.generic
                    }
                    
                    return attempt(maxRetryCount: maxRetryCount, recoveringOn: Threading.workQueue) {
                        return SnodeAPI
                            .send(
                                request: SnodeRequest(
                                    endpoint: .revokeSubkey,
                                    body: RevokeSubkeyRequest(
                                        subkeyToRevoke: subkeyToRevoke,
                                        pubkey: publicKey,
                                        ed25519PublicKey: userED25519KeyPair.publicKey,
                                        ed25519SecretKey: userED25519KeyPair.secretKey
                                    )
                                ),
                                to: snode,
                                associatedWith: publicKey,
                                using: dependencies
                            )
                            .decoded(as: RevokeSubkeyResponse.self, on: Threading.workQueue, using: dependencies)
                            .map(on: Threading.workQueue) { _, response in
                                try response.validateResult(
                                    userX25519PublicKey: getUserHexEncodedPublicKey(),
                                    subkeyToRevoke: subkeyToRevoke,
                                    sodium: sodium.wrappedValue
                                )
                                
                                return ()
                            }
                    }
                }
        }
    }
    
    // MARK: Delete
    
    public static func deleteMessages(
        publicKey: String,
        serverHashes: [String],
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> Promise<[String: Bool]> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Promise(error: SnodeAPIError.noKeyPair)
        }
        
        let publicKey: String = (Features.useTestnet ?
            publicKey.removingIdPrefixIfNeeded() :
            publicKey
        )
        
        return attempt(maxRetryCount: maxRetryCount, recoveringOn: Threading.workQueue) {
            getSwarm(for: publicKey)
                .then2 { swarm -> Promise<[String: Bool]> in
                    attempt(maxRetryCount: maxRetryCount, recoveringOn: Threading.workQueue) {
                        guard let snode: Snode = swarm.randomElement() else {
                            return Promise(error: SnodeAPIError.generic)
                        }
                        
                        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
                        
                        return SnodeAPI
                            .send(
                                request: SnodeRequest(
                                    endpoint: .deleteMessages,
                                    body: DeleteMessagesRequest(
                                        messageHashes: serverHashes,
                                        requireSuccessfulDeletion: false,
                                        pubkey: userX25519PublicKey,
                                        ed25519PublicKey: userED25519KeyPair.publicKey,
                                        ed25519SecretKey: userED25519KeyPair.secretKey
                                    )
                                ),
                                to: snode,
                                associatedWith: publicKey,
                                using: dependencies
                            )
                            .decoded(as: DeleteMessagesResponse.self, on: Threading.workQueue, using: dependencies)
                            .map(on: Threading.workQueue) { _, response in
                                let validResultMap: [String: Bool] = response.validResultMap(
                                    userX25519PublicKey: userX25519PublicKey,
                                    serverHashes: serverHashes,
                                    sodium: sodium.wrappedValue
                                )
                                
                                // If at least one service node deleted successfully then we should
                                // mark the hash as invalid so we don't try to fetch updates using
                                // that hash going forward (if we do we would end up re-fetching
                                // all old messages)
                                if validResultMap.values.contains(true) {
                                    Storage.shared.writeAsync { db in
                                        try? SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                                            db,
                                            potentiallyInvalidHashes: serverHashes
                                        )
                                    }
                                }
                                
                                return validResultMap
                            }
                    }
                }
        }
    }
    
    /// Clears all the user's data from their swarm. Returns a dictionary of snode public key to deletion confirmation.
    public static func deleteAllMessages(
        namespace: SnodeAPI.Namespace? = nil,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> Promise<[String: Bool]> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Promise(error: SnodeAPIError.noKeyPair)
        }
        
        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
        
        return attempt(maxRetryCount: maxRetryCount, recoveringOn: Threading.workQueue) {
            getSwarm(for: userX25519PublicKey)
                .then2 { swarm -> Promise<[String: Bool]> in
                    guard let snode: Snode = swarm.randomElement() else {
                        return Promise(error: SnodeAPIError.generic)
                    }
                    
                    let userX25519PublicKey: String = getUserHexEncodedPublicKey()
                    
                    return attempt(maxRetryCount: maxRetryCount, recoveringOn: Threading.workQueue) {
                        getNetworkTime(from: snode).then2 { timestampMs -> Promise<[String: Bool]> in
                            SnodeAPI
                                .send(
                                    request: SnodeRequest(
                                        endpoint: .deleteAll,
                                        body: DeleteAllMessagesRequest(
                                            namespace: namespace,
                                            pubkey: userX25519PublicKey,
                                            timestampMs: timestampMs,
                                            ed25519PublicKey: userED25519KeyPair.publicKey,
                                            ed25519SecretKey: userED25519KeyPair.secretKey
                                        )
                                    ),
                                    to: snode,
                                    associatedWith: nil,
                                    using: dependencies
                                )
                                .decoded(as: DeleteAllMessagesResponse.self, on: Threading.workQueue, using: dependencies)
                                .map(on: Threading.workQueue) { _, response in
                                    let validResultMap: [String: Bool] = response.validResultMap(
                                        userX25519PublicKey: userX25519PublicKey,
                                        timestampMs: timestampMs,
                                        sodium: sodium.wrappedValue
                                    )
                                    
                                    return validResultMap
                                }
                        }
                }
            }
        }
    }
    
    /// Clears all the user's data from their swarm. Returns a dictionary of snode public key to deletion confirmation.
    public static func deleteAllMessages(
        beforeMs: UInt64,
        namespace: SnodeAPI.Namespace? = nil,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> Promise<[String: Bool]> {
        guard let userED25519KeyPair = Identity.fetchUserEd25519KeyPair() else {
            return Promise(error: SnodeAPIError.noKeyPair)
        }
        
        let userX25519PublicKey: String = getUserHexEncodedPublicKey()
        
        return attempt(maxRetryCount: maxRetryCount, recoveringOn: Threading.workQueue) {
            getSwarm(for: userX25519PublicKey)
                .then2 { swarm -> Promise<[String: Bool]> in
                    guard let snode: Snode = swarm.randomElement() else {
                        return Promise(error: SnodeAPIError.generic)
                    }
                    
                    let userX25519PublicKey: String = getUserHexEncodedPublicKey()
                    
                    return attempt(maxRetryCount: maxRetryCount, recoveringOn: Threading.workQueue) {
                        getNetworkTime(from: snode).then2 { timestampMs -> Promise<[String: Bool]> in
                            SnodeAPI
                                .send(
                                    request: SnodeRequest(
                                        endpoint: .deleteAllBefore,
                                        body: DeleteAllBeforeRequest(
                                            beforeMs: beforeMs,
                                            namespace: namespace,
                                            pubkey: userX25519PublicKey,
                                            timestampMs: timestampMs,
                                            ed25519PublicKey: userED25519KeyPair.publicKey,
                                            ed25519SecretKey: userED25519KeyPair.secretKey
                                        )
                                    ),
                                    to: snode,
                                    associatedWith: nil,
                                    using: dependencies
                                )
                                .decoded(as: DeleteAllBeforeResponse.self, on: Threading.workQueue, using: dependencies)
                                .map(on: Threading.workQueue) { _, response in
                                    let validResultMap: [String: Bool] = response.validResultMap(
                                        userX25519PublicKey: userX25519PublicKey,
                                        beforeMs: beforeMs,
                                        sodium: sodium.wrappedValue
                                    )
                                    
                                    return validResultMap
                                }
                        }
                }
            }
        }
    }
    
    // MARK: - Internal API
    
    private static func getNetworkTime(
        from snode: Snode,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> Promise<UInt64> {
        return SnodeAPI
            .send(
                request: SnodeRequest<[String: String]>(
                    endpoint: .getInfo,
                    body: [:]
                ),
                to: snode,
                associatedWith: nil
            )
            .decoded(as: GetNetworkTimestampResponse.self, on: Threading.workQueue, using: dependencies)
            .map2 { _, response in response.timestamp }
    }
    
    internal static func getRandomSnode() -> Promise<Snode> {
        // randomElement() uses the system's default random generator, which is cryptographically secure
        return getSnodePool().map2 { $0.randomElement()! }
    }
    
    private static func getSnodePoolFromSeedNode(
        dependencies: SSKDependencies = SSKDependencies()
    ) -> Promise<Set<Snode>> {
        let request: SnodeRequest = SnodeRequest(
            endpoint: .jsonGetNServiceNodes,
            body: GetServiceNodesRequest(
                activeOnly: true,
                limit: 256,
                fields: GetServiceNodesRequest.Fields(
                    publicIp: true,
                    storagePort: true,
                    pubkeyEd25519: true,
                    pubkeyX25519: true
                )
            )
        )
        
        guard let target: String = seedNodePool.randomElement() else {
            return Promise(error: SnodeAPIError.snodePoolUpdatingFailed)
        }
        guard let payload: Data = try? JSONEncoder().encode(request) else {
            return Promise(error: HTTPError.invalidJSON)
        }
        
        let url: String = "\(target)/json_rpc"
        let (promise, seal) = Promise<Set<Snode>>.pending()
        SNLog("Populating snode pool using seed node: \(target).")
        
        Threading.workQueue.async {
            attempt(maxRetryCount: 4, recoveringOn: Threading.workQueue) {
                HTTP.execute(.post, url, body: payload, useSeedNodeURLSession: true)
                    .decoded(as: SnodePoolResponse.self, on: Threading.workQueue, using: dependencies)
                    .recover2 { error -> Promise<SnodePoolResponse> in
                        switch error {
                            case HTTPError.parsingFailed:
                                return Promise(error: SnodeAPIError.snodePoolUpdatingFailed)
                                
                            default: return Promise(error: error)
                        }
                    }
                    .map2 { snodePool -> Set<Snode> in
                        snodePool.result
                            .serviceNodeStates
                            .compactMap { $0.value }
                            .asSet()
                    }
            }
            .done2 { snodePool in
                SNLog("Got snode pool from seed node: \(target).")
                seal.fulfill(snodePool)
            }
            .catch2 { error in
                SNLog("Failed to contact seed node at: \(target).")
                seal.reject(error)
            }
        }
        
        return promise
    }
    
    private static func getSnodePoolFromSnode(
        dependencies: SSKDependencies = SSKDependencies()
    ) -> Promise<Set<Snode>> {
        var snodePool = SnodeAPI.snodePool.wrappedValue
        var snodes: Set<Snode> = []
        (0..<3).forEach { _ in
            guard let snode = snodePool.randomElement() else { return }
            
            snodePool.remove(snode)
            snodes.insert(snode)
        }
        
        let snodePoolPromises: [Promise<Set<Snode>>] = snodes.map { snode in
            attempt(maxRetryCount: 4, recoveringOn: Threading.workQueue) {
                // Don't specify a limit in the request. Service nodes return a shuffled
                // list of nodes so if we specify a limit the 3 responses we get might have
                // very little overlap.
                SnodeAPI
                    .send(
                        request: SnodeRequest(
                            endpoint: .oxenDaemonRPCCall,
                            body: OxenDaemonRPCRequest(
                                endpoint: .daemonGetServiceNodes,
                                body: GetServiceNodesRequest(
                                    activeOnly: true,
                                    limit: nil,
                                    fields: GetServiceNodesRequest.Fields(
                                        publicIp: true,
                                        storagePort: true,
                                        pubkeyEd25519: true,
                                        pubkeyX25519: true
                                    )
                                )
                            )
                        ),
                        to: snode,
                        associatedWith: nil
                    )
                    .decoded(as: SnodePoolResponse.self, on: Threading.workQueue, using: dependencies)
                    .recover2 { error -> Promise<(ResponseInfoType, SnodePoolResponse)> in
                        switch error {
                            case HTTPError.parsingFailed:
                                return Promise(error: SnodeAPIError.snodePoolUpdatingFailed)
                                
                            default: return Promise(error: error)
                        }
                    }
                    .map2 { _, snodePool -> Set<Snode> in
                        snodePool.result
                            .serviceNodeStates
                            .compactMap { $0.value }
                            .asSet()
                    }
            }
        }
        
        let promise = when(fulfilled: snodePoolPromises).map2 { results -> Set<Snode> in
            let result: Set<Snode> = results.reduce(Set()) { prev, next in prev.intersection(next) }
            
            // We want the snodes to agree on at least this many snodes
            guard result.count > 24 else { throw SnodeAPIError.inconsistentSnodePools }
            
            // Limit the snode pool size to 256 so that we don't go too long without
            // refreshing it
            return Set(result.prefix(256))
        }
        
        return promise
    }
    
    private static func send<T: Encodable>(
        request: SnodeRequest<T>,
        to snode: Snode,
        associatedWith publicKey: String?,
        using dependencies: SSKDependencies = SSKDependencies()
    ) -> Promise<(ResponseInfoType, Data?)> {
        guard let payload: Data = try? JSONEncoder().encode(request) else {
            return Promise(error: HTTPError.invalidJSON)
        }
        
        guard Features.useOnionRequests else {
            return HTTP
                .execute(
                    .post,
                    "\(snode.address):\(snode.port)/storage_rpc/v1",
                    body: payload
                )
                .map2 { response in (HTTP.ResponseInfo(code: -1, headers: [:]), response) }
                .recover2 { error -> Promise<(ResponseInfoType, Data?)> in
                    guard case HTTPError.httpRequestFailed(let statusCode, let data) = error else {
                        throw error
                    }
                    
                    throw SnodeAPI.handleError(withStatusCode: statusCode, data: data, forSnode: snode, associatedWith: publicKey) ?? error
                }
        }
        
        return dependencies.onionApi
            .sendOnionRequest(
                payload,
                to: snode
            )
            .map2 { response in
                // Extract and store hard fork information if returned
                if
                    let responseData: Data = response.1,
                    let snodeResponse: SnodeResponse = try? JSONDecoder()
                        .decode(SnodeResponse.self, from: responseData)
                {
                    if snodeResponse.hardFork[1] > softfork {
                        softfork = snodeResponse.hardFork[1]
                        UserDefaults.standard[.softfork] = softfork
                    }
                    
                    if snodeResponse.hardFork[0] > hardfork {
                        hardfork = snodeResponse.hardFork[0]
                        UserDefaults.standard[.hardfork] = hardfork
                        softfork = snodeResponse.hardFork[1]
                        UserDefaults.standard[.softfork] = softfork
                    }
                }
                
                return response
            }
            .recover2 { error -> Promise<(ResponseInfoType, Data?)> in
                guard case OnionRequestAPIError.httpRequestFailedAtDestination(let statusCode, let data, _) = error else {
                    throw error
                }
                
                throw SnodeAPI.handleError(withStatusCode: statusCode, data: data, forSnode: snode, associatedWith: publicKey) ?? error
            }
    }
    
    // MARK: - Parsing
    
    // The parsing utilities below use a best attempt approach to parsing; they warn for parsing failures but don't throw exceptions.

    private static func parseSnodes(from responseData: Data?) -> Set<Snode> {
        guard
            let responseData: Data = responseData,
            let responseJson: JSON = try? JSONSerialization.jsonObject(
                with: responseData,
                options: [ .fragmentsAllowed ]
            ) as? JSON
        else {
            SNLog("Failed to parse snodes from response data.")
            return []
        }
        guard let rawSnodes = responseJson["snodes"] as? [JSON] else {
            SNLog("Failed to parse snodes from: \(responseJson).")
            return []
        }
        
        guard let snodeData: Data = try? JSONSerialization.data(withJSONObject: rawSnodes, options: []) else {
            return []
        }
        
        // FIXME: Hopefully at some point this different Snode structure will be deprecated and can be removed
        if
            let swarmSnodes: [SwarmSnode] = try? JSONDecoder().decode([Failable<SwarmSnode>].self, from: snodeData).compactMap({ $0.value }),
            !swarmSnodes.isEmpty
        {
            return swarmSnodes.map { $0.toSnode() }.asSet()
        }
        
        return ((try? JSONDecoder().decode([Failable<Snode>].self, from: snodeData)) ?? [])
            .compactMap { $0.value }
            .asSet()
    }

    // MARK: - Error Handling
    
    /// - Note: Should only be invoked from `Threading.workQueue` to avoid race conditions.
    @discardableResult
    internal static func handleError(withStatusCode statusCode: UInt, data: Data?, forSnode snode: Snode, associatedWith publicKey: String? = nil) -> Error? {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(Threading.workQueue))
        #endif
        func handleBadSnode() {
            let oldFailureCount = (SnodeAPI.snodeFailureCount.wrappedValue[snode] ?? 0)
            let newFailureCount = oldFailureCount + 1
            SnodeAPI.snodeFailureCount.mutate { $0[snode] = newFailureCount }
            SNLog("Couldn't reach snode at: \(snode); setting failure count to \(newFailureCount).")
            if newFailureCount >= SnodeAPI.snodeFailureThreshold {
                SNLog("Failure threshold reached for: \(snode); dropping it.")
                if let publicKey = publicKey {
                    SnodeAPI.dropSnodeFromSwarmIfNeeded(snode, publicKey: publicKey)
                }
                SnodeAPI.dropSnodeFromSnodePool(snode)
                SNLog("Snode pool count: \(snodePool.wrappedValue.count).")
                SnodeAPI.snodeFailureCount.mutate { $0[snode] = 0 }
            }
        }
        
        switch statusCode {
            case 500, 502, 503:
                // The snode is unreachable
                handleBadSnode()
                
            case 404:
                // May caused by invalid open groups
                SNLog("Can't reach the server.")
                
            case 406:
                SNLog("The user's clock is out of sync with the service node network.")
                return SnodeAPIError.clockOutOfSync
                
            case 421:
                // The snode isn't associated with the given public key anymore
                if let publicKey = publicKey {
                    func invalidateSwarm() {
                        SNLog("Invalidating swarm for: \(publicKey).")
                        SnodeAPI.dropSnodeFromSwarmIfNeeded(snode, publicKey: publicKey)
                    }
                    
                    if let data: Data = data {
                        let snodes = parseSnodes(from: data)
                        
                        if !snodes.isEmpty {
                            setSwarm(to: snodes, for: publicKey)
                        }
                        else {
                            invalidateSwarm()
                        }
                    }
                    else {
                        invalidateSwarm()
                    }
                }
                else {
                    SNLog("Got a 421 without an associated public key.")
                }
                
            default:
                handleBadSnode()
                SNLog("Unhandled response code: \(statusCode).")
        }
        
        return nil
    }
}
