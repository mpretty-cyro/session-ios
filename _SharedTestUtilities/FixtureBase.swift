// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

open class FixtureBase {
    let dependencies: TestDependencies = TestDependencies()
    
    public init() {
        dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        dependencies.forceSynchronous = true
    }
    
    public func mock<R, SingletonType>(
        for singleton: SingletonConfig<SingletonType>,
        _ creation: (TestDependencies) -> R
    ) -> R {
        if let existingMock: R = dependencies.get(singleton: singleton) as? R {
            return existingMock
        }
        
        let value: R = creation(dependencies)
        
        guard let conformingValue: SingletonType = value as? SingletonType else {
            fatalError("Type Mismatch: The mock of type '\(type(of: value))' does not conform to the required protocol '\(SingletonType.self)' for the provided singleton key.")
        }
        
        dependencies.set(singleton: singleton, to: conformingValue)
        return value
    }
    
    public func mock<R, MutableCache, ImmutableCache>(
        cache: CacheConfig<MutableCache, ImmutableCache>,
        _ creation: (TestDependencies) -> R
    ) -> R {
        if let existingMock: R = dependencies.get(cache: cache) as? R {
            return existingMock
        }
        
        let value: R = creation(dependencies)
        
        guard let conformingValue: MutableCache = value as? MutableCache else {
            fatalError("Type Mismatch: The mock of type '\(type(of: value))' does not conform to the required protocol '\(MutableCache.self)' for the provided singleton key.")
        }
        
        dependencies.set(cache: cache, to: conformingValue)
        return value
    }
    
    public func mock<T: UserDefaultsType>(
        for defaults: UserDefaultsConfig,
        _ creation: (TestDependencies) -> T
    ) -> T {
        if let existingMock: T = dependencies.get(defaults: defaults) {
            return existingMock
        }
        
        let value: T = creation(dependencies)
        dependencies.set(defaults: defaults, to: value)
        
        return value
    }
    
    private func mock<T>(_ creation: (TestDependencies) -> T) -> T {
        if let existingMock: T = dependencies.get(other: ObjectIdentifier(T.self)) {
            return existingMock
        }
        
        let value: T = creation(dependencies)
        dependencies.set(other: ObjectIdentifier(T.self), to: value)
        
        return value
    }
}
