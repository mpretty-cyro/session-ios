// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine

public extension Publisher {
    func mapToVoid() -> AnyPublisher<Void, Failure> {
        return map { _ -> Void in () }
            .eraseToAnyPublisher()
    }
    
    /// Provides a subject that shares a single subscription to the upstream publisher and replays at most
    /// `bufferSize` items emitted by that publisher
    /// - Parameter bufferSize: limits the number of items that can be replayed
    func shareReplay(_ bufferSize: Int) -> AnyPublisher<Output, Failure> {
        return multicast(subject: ReplaySubject(bufferSize))
            .autoconnect()
            .eraseToAnyPublisher()
    }
    
    func sink(into subject: PassthroughSubject<Output, Failure>, includeCompletions: Bool = false) -> AnyCancellable {
        return sink(
            receiveCompletion: { completion in
                guard includeCompletions else { return }
                
                subject.send(completion: completion)
            },
            receiveValue: { value in subject.send(value) }
        )
    }
}

// MARK: - Convenience

public extension Publisher {
    func sink(into subject: PassthroughSubject<Output, Failure>?, includeCompletions: Bool = false) -> AnyCancellable {
        guard let targetSubject: PassthroughSubject<Output, Failure> = subject else { return AnyCancellable {} }
        
        return sink(into: targetSubject, includeCompletions: includeCompletions)
    }
}
