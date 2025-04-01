// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

// TODO: [ACTOR CHANGES] Can we remove these?
@discardableResult public func sync<T>(_ closure: @escaping () async -> T) -> T {
    let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
    var result: T!
    
    Task<Void, Never> {
        result = await closure()
        semaphore.signal()
    }
    semaphore.wait()
    return result
}

@discardableResult public func sync<T>(_ closure: @escaping () async throws -> T) throws -> T {
    let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
    var result: T!
    var closureError: Error?
    
    Task<Void, Error> {
        do { result = try await closure() }
        catch { closureError = error }
        semaphore.signal()
    }
    semaphore.wait()
    
    switch closureError {
        case .some(let error): throw error
        default: return result
    }
}
