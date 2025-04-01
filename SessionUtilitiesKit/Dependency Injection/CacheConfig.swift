// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - Cache

public class Cache {}

// MARK: - Cache Types

public protocol ImmutableCacheType: Sendable {}
public protocol MutableCacheType: AnyObject, Sendable {}

// MARK: - CacheInfo

public class CacheConfig<M, I>: Cache {
    public let identifier: String
    public let createInstance: (Dependencies) -> M
    internal let erasedInstance: (Dependencies, M) -> MutableCacheType
    internal let immutableInstance: (Dependencies, M) async -> I
    
    fileprivate init(
        identifier: String,
        createInstance: @escaping (Dependencies) -> M,
        erasedInstance: @escaping (Dependencies, M) -> MutableCacheType,
        immutableInstance: @escaping (Dependencies, M) async -> I
    ) {
        self.identifier = identifier
        self.createInstance = createInstance
        self.erasedInstance = erasedInstance
        self.immutableInstance = immutableInstance
    }
}

// MARK: - Creation

public extension Dependencies {
    static func create<M, I, ActorType>(
        identifier: String,
        createInstance: @escaping (Dependencies) -> ActorType,
        mutableInstance: @escaping (ActorType) -> M,
        erasedInstance: @escaping (ActorType) -> MutableCacheType,
        immutableInstance: @escaping (ActorType) async -> I
    ) -> CacheConfig<M, I> {
        return CacheConfig(
            identifier: identifier,
            createInstance: { dependencies in mutableInstance(createInstance(dependencies)) },
            erasedInstance: { dependencies, instance in
                erasedInstance(((instance as? ActorType)) ?? createInstance(dependencies))
            },
            immutableInstance: { dependencies, instance in
                await immutableInstance(((instance as? ActorType)) ?? createInstance(dependencies))
            }
        )
    }
}
