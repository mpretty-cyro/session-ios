// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public enum ProcessDeadlockWorkAroundJob: JobExecutor {
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
        // Don't run when inactive or not in main app
        guard (UserDefaults.sharedLokiProject?[.isMainAppActive]).defaulting(to: false) else {
            deferred(job, dependencies) // Don't need to do anything if it's not the main app
            return
        }
        
        // Process any DeadlockWorkAround messages
        do {
            try DeadlockWorkAround.readProcessAndRemoveRecords()
            success(job, false, dependencies)
        }
        catch {
            SNLog("[DeadlockWorkAround] Failed due to error: \(error)")
        }
    }
    
    public static func afterAppShare(
        _ shareViewController: UIActivityViewController,
        onShareComplete: ((Bool) -> ())? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> UIActivityViewController.CompletionWithItemsHandler {
        return { [weak shareViewController] _, completed, _, _ in
            shareViewController?.completionWithItemsHandler = nil
            
            guard completed else { return }
            
            // The share extension runs in read only mode and leaves an artifact for the shared content,
            // now that it's completed we need to
            ProcessDeadlockWorkAroundJob.run(
                Job(
                    variant: .processDeadlockWorkAround,
                    behaviour: .runOnce
                ),
                queue: DispatchQueue.global(qos: .default),
                success: { _, _, _ in onShareComplete?(completed) },
                failure: { _, _, _, _ in onShareComplete?(completed) },
                deferred: { _, _ in onShareComplete?(completed) },
                using: dependencies
            )
        }
    }
}
