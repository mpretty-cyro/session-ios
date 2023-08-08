// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SignalCoreKit
import SessionUtilitiesKit

public enum GetSnodePoolJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies
    ) {
        let layers: Network.Layers = (dependencies.storage[.networkLayers]
            .map { Int8($0) }
            .map { Network.Layers(rawValue: $0) })
            .defaulting(to: .defaultLayers)
        
        // Force Lokinet to start building (want to do this regardless of the
        // network layer to get a proper status comparison between them)
        if layers.contains(.lokinet) { Lokinet.setupIfNeeded() }
        if layers.contains(.direct) {
            DispatchQueue.main.async(using: dependencies) {
                NotificationCenter.default.post(name: .directNetworkReady, object: nil)
            }
        }
        
        // If we already have cached Snodes then we still want to trigger the 'SnodeAPI.getSnodePool'
        // but we want to succeed this job immediately (since it's marked as blocking), this allows us
        // to block if we have no Snode pool and prevent other jobs from failing but avoids having to
        // wait if we already have a potentially valid snode pool
        guard !SnodeAPI.hasCachedSnodesInclusingExpired() else {
            SNLog("[GetSnodePoolJob] Has valid cached pool, running async instead")
            SnodeAPI
                .getSnodePool()
                .subscribe(on: DispatchQueue.global(qos: .default))
                .handleEvents(
                    receiveSubscription: { _ in
                        Network.requestTiming.mutate { timing in
                            timing[.onionRequest] = (timing[.onionRequest] ?? [:]).setting(
                                "Startup",
                                Network.Timing(
                                    requestType: "Startup",
                                    startTime: CACurrentMediaTime(),
                                    endTime: -1,
                                    didError: false,
                                    didTimeout: false
                                )
                            )
                        }
                    },
                    receiveOutput: { _ in
                        Network.requestTiming.mutate { timing in
                            let updatedTiming: Network.Timing? = (timing[.onionRequest] ?? [:])?["Startup"]?
                                .with(endTime: CACurrentMediaTime())
                            timing[.onionRequest]?["Startup"] = updatedTiming
                        }
                    },
                    receiveCompletion: { result in
                        switch result {
                            case .finished: break
                            case .failure(let error):
                                let isTimeout: Bool = {
                                    switch error {
                                        case HTTPError.timeout: return true
                                        default: return false
                                    }
                                }()
                                
                                Network.requestTiming.mutate { timing in
                                    let updatedTiming: Network.Timing? = (timing[.onionRequest] ?? [:])?["Startup"]?
                                        .with(
                                            endTime: CACurrentMediaTime(),
                                            didError: !isTimeout,
                                            didTimeout: isTimeout
                                        )
                                    timing[.onionRequest]?["Startup"] = updatedTiming
                                }
                        }
                    }
                )
                .sinkUntilComplete()
            return success(job, false, dependencies)
        }
        
        // If we don't have the snode pool cached then we should also try to build the path (this will
        // speed up the onboarding process for new users because it can run before the user is created)
        SnodeAPI.getSnodePool()
            .flatMap { _ in OnionRequestAPI.getPath(excluding: nil, using: dependencies) }
            .subscribe(on: queue)
            .receive(on: queue)
            .handleEvents(
                receiveSubscription: { _ in
                    Network.requestTiming.mutate { timing in
                        timing[.onionRequest] = (timing[.onionRequest] ?? [:]).setting(
                            "Startup",
                            Network.Timing(
                                requestType: "Startup",
                                startTime: CACurrentMediaTime(),
                                endTime: -1,
                                didError: false,
                                didTimeout: false
                            )
                        )
                    }
                },
                receiveOutput: { _ in
                    Network.requestTiming.mutate { timing in
                        let updatedTiming: Network.Timing? = (timing[.onionRequest] ?? [:])?["Startup"]?
                            .with(endTime: CACurrentMediaTime())
                        timing[.onionRequest]?["Startup"] = updatedTiming
                    }
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            let isTimeout: Bool = {
                                switch error {
                                    case HTTPError.timeout: return true
                                    default: return false
                                }
                            }()
                            
                            Network.requestTiming.mutate { timing in
                                let updatedTiming: Network.Timing? = (timing[.onionRequest] ?? [:])?["Startup"]?
                                    .with(
                                        endTime: CACurrentMediaTime(),
                                        didError: !isTimeout,
                                        didTimeout: isTimeout
                                    )
                                timing[.onionRequest]?["Startup"] = updatedTiming
                            }
                    }
                }
            )
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished:
                            SNLog("[GetSnodePoolJob] Completed")
                            success(job, false, dependencies)
                            
                        case .failure(let error):
                            SNLog("[GetSnodePoolJob] Failed due to error: \(error)")
                            failure(job, error, false, dependencies)
                    }
                }
            )
    }
    
    public static func run(using dependencies: Dependencies = Dependencies()) {
        GetSnodePoolJob.run(
            Job(variant: .getSnodePool),
            queue: .global(qos: .background),
            success: { _, _, _ in },
            failure: { _, _, _, _ in },
            deferred: { _, _ in },
            using: dependencies
        )
    }
}
