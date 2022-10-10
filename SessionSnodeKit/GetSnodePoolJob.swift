// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SignalCoreKit
import SessionUtilitiesKit

public extension Setting.EnumKey {
    /// Controls what network layer is used for sending API requests (See `RequestAPI.NetworkLayer` for the options)
    static let debugNetworkLayer: Setting.EnumKey = "debugNetworkLayer"
}

public enum GetSnodePoolJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> (),
        failure: @escaping (Job, Error?, Bool) -> (),
        deferred: @escaping (Job) -> ()
    ) {
        // If the user doesn't exist then don't do anything (when the user registers we run this
        // job directly)
        guard Identity.userExists() else {
            deferred(job)
            return
        }
        
        let layer: RequestAPI.NetworkLayer = Storage.shared[.debugNetworkLayer]
            .defaulting(to: .onionRequest)
        
        switch layer {
            case .onionRequest: break
            case .lokinet:
                // Force Lokinet to start building (want to do this regardless of the
                // network layer to get a proper status comparison between them)
                LokinetWrapper.setupIfNeeded()
                
            default:
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .directNetworkReady, object: nil)
                }
        }
        
        // If we already have cached Snodes then we still want to trigger the 'SnodeAPI.getSnodePool'
        // but we want to succeed this job immediately (since it's marked as blocking), this allows us
        // to block if we have no Snode pool and prevent other jobs from failing but avoids having to
        // wait if we already have a potentially valid snode pool
        guard !SnodeAPI.hasCachedSnodesInclusingExpired() else {
            SnodeAPI.getSnodePool().retainUntilComplete()
            success(job, false)
            return
        }
        
        SnodeAPI.getSnodePool()
            .done(on: queue) { _ in success(job, false) }
            .catch(on: queue) { error in failure(job, error, false) }
            .retainUntilComplete()
    }
    
    public static func run() {
        GetSnodePoolJob.run(
            Job(variant: .getSnodePool),
            queue: DispatchQueue.global(qos: .background),
            success: { _, _ in },
            failure: { _, _, _ in },
            deferred: { _ in }
        )
    }
}
