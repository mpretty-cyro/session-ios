// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB

// MARK: - Cache

public extension Cache {
    static let general: CacheConfig<GeneralCacheType, ImmutableGeneralCacheType> = Dependencies.create(
        identifier: "general",
        createInstance: { _ in General.Cache() },
        mutableInstance: { $0 },
        erasedInstance: { $0 },
        immutableInstance: { $0.immutable }
    )
}

// MARK: - General.Cache

public enum General {
    public actor Cache: GeneralCacheType {
        public struct Immutable: ImmutableGeneralCacheType {
            public let sessionId: SessionId
            public let recentReactionTimestamps: [Int64]
            public let placeholderCache: LRUCache<String, UIImage>
            public let contextualActionLookupMap: [Int: [String: [Int: Sendable]]]
            
            fileprivate init(
                sessionId: SessionId = SessionId.invalid,
                recentReactionTimestamps: [Int64] = [],
                placeholderCache: LRUCache<String, UIImage> = LRUCache(maxCacheSize: 50),
                contextualActionLookupMap: [Int: [String: [Int: Sendable]]] = [:]
            ) {
                self.sessionId = sessionId
                self.recentReactionTimestamps = recentReactionTimestamps
                self.placeholderCache = placeholderCache
                self.contextualActionLookupMap = contextualActionLookupMap
            }
            
            public func with(
                sessionId: SessionId? = nil,
                recentReactionTimestamps: [Int64]? = nil,
                contextualActionLookupMap: [Int: [String: [Int: Sendable]]]? = nil
            ) -> Immutable {
                return Immutable(
                    sessionId: (sessionId ?? self.sessionId),
                    recentReactionTimestamps: (recentReactionTimestamps ?? self.recentReactionTimestamps),
                    placeholderCache: placeholderCache,
                    contextualActionLookupMap: (contextualActionLookupMap ?? self.contextualActionLookupMap)
                )
            }
            
            public func cahcedPlaceholder(for key: String) -> UIImage? {
                return sync { await self.placeholderCache.get(key: key) }
            }
        }
        
        fileprivate var immutable: Immutable = Immutable()
        public var sessionId: SessionId { immutable.sessionId }
        public var recentReactionTimestamps: [Int64] { immutable.recentReactionTimestamps }
        public var placeholderCache: LRUCache<String, UIImage> { immutable.placeholderCache }
        public var contextualActionLookupMap: [Int: [String: [Int: Sendable]]] {
            immutable.contextualActionLookupMap
        }
        
        // MARK: - Functions
        
        public func setCachedSessionId(sessionId: SessionId) async {
            immutable = immutable.with(sessionId: sessionId)
        }
        
        public func addRecentReactionTimestamp(_ timestamp: Int64) async {
            immutable = immutable.with(recentReactionTimestamps: recentReactionTimestamps.appending(timestamp))
        }
        
        public func updateContextualActionLookupMap(
            tableViewHash: Int,
            value: [String: [Int: Sendable]]
        ) async {
            immutable = immutable.with(
                contextualActionLookupMap: immutable.contextualActionLookupMap.setting(tableViewHash, value)
            )
        }
        
        public func removeCachedContextualActionInfo(tableViewHash: Int, keys: [String]) async {
            var updatedLookupMap: [Int: [String: [Int: Sendable]]] = immutable.contextualActionLookupMap
            
            keys.forEach { key in updatedLookupMap[tableViewHash]?[key] = nil }
            
            if updatedLookupMap[tableViewHash]?.isEmpty == true {
                updatedLookupMap[tableViewHash] = nil
            }
            
            immutable = immutable.with(contextualActionLookupMap: updatedLookupMap)
        }
    }
}

// MARK: - GeneralCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol ImmutableGeneralCacheType: ImmutableCacheType {
    var sessionId: SessionId { get }
    var recentReactionTimestamps: [Int64] { get }
    var contextualActionLookupMap: [Int: [String: [Int: Sendable]]] { get }
    
    func cahcedPlaceholder(for key: String) -> UIImage?
}

public protocol GeneralCacheType: MutableCacheType {
    func setCachedSessionId(sessionId: SessionId) async
    func addRecentReactionTimestamp(_ timestamp: Int64) async
    func updateContextualActionLookupMap(tableViewHash: Int, value: [String: [Int: Sendable]]) async
    func removeCachedContextualActionInfo(tableViewHash: Int, keys: [String]) async
    
    // MARK: - ImmutableCacheType Access
    
    var sessionId: SessionId { get async }
    var recentReactionTimestamps: [Int64] { get async }
    var placeholderCache: LRUCache<String, UIImage> { get async }
    var contextualActionLookupMap: [Int: [String: [Int: Sendable]]] { get async }
}
