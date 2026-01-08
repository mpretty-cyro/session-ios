// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Quick

@testable import SessionUtilitiesKit

internal extension TestState {
    init<M, I>(
        wrappedValue: @escaping @autoclosure () -> T?,
        cache: CacheConfig<M, I>,
        in dependenciesRetriever: @escaping @autoclosure () -> TestDependencies?
    ) where T: MutableCacheType {
        self.init(wrappedValue: {
            let dependencies: TestDependencies? = dependenciesRetriever()
            let value: T? = wrappedValue()
            (value as? DependenciesSettable)?.setDependencies(dependencies)
            dependencies?[cache: cache] = (value as! M)
            (value as? (any InitialSetupable))?.performInitialSetup()
            
            return value
        }())
    }
    
    init<S>(
        wrappedValue: @escaping @autoclosure () -> T?,
        singleton: SingletonConfig<S>,
        in dependenciesRetriever: @escaping @autoclosure () -> TestDependencies?
    ) {
        self.init(wrappedValue: {
            let dependencies: TestDependencies? = dependenciesRetriever()
            let value: T? = wrappedValue()
            (value as? DependenciesSettable)?.setDependencies(dependencies)
            dependencies?[singleton: singleton] = (value as! S)
            (value as? (any InitialSetupable))?.performInitialSetup()
            
            return value
        }())
    }
    
    init(
        wrappedValue: @escaping @autoclosure () -> T?,
        defaults: UserDefaultsConfig,
        in dependenciesRetriever: @escaping @autoclosure () -> TestDependencies?
    ) where T: UserDefaultsType {
        self.init(wrappedValue: {
            let dependencies: TestDependencies? = dependenciesRetriever()
            let value: T? = wrappedValue()
            (value as? DependenciesSettable)?.setDependencies(dependencies)
            dependencies?[defaults: defaults] = value
            (value as? (any InitialSetupable))?.performInitialSetup()
            
            return value
        }())
    }
    
    static func create(
        closure: @escaping () async -> T?
    ) -> T? {
        var value: T?
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        Task {
            value = await closure()
            semaphore.signal()
        }
        semaphore.wait()
        
        return value
    }
}
