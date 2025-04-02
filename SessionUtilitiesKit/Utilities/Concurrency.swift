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

public extension Task where Success == Never, Failure == Never {
    /// Suspends the current task until the given deadline (compatibility version).
    @available(iOS, introduced: 13.0, obsoleted: 16.0, message: "Use built-in Task.sleep(for:) accepting Swift.Duration on iOS 16+")
    static func sleep(for interval: DispatchTimeInterval) async throws {
        let nanosecondsToSleep: UInt64 = (UInt64(interval.milliseconds) * 1_000_000)
        try await Task.sleep(nanoseconds: nanosecondsToSleep)
    }
}
