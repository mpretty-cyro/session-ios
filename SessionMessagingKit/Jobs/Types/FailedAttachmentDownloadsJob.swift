// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SignalCoreKit
import SessionUtilitiesKit

public enum FailedAttachmentDownloadsJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        dependencies: Dependencies = Dependencies()
    ) {
        // Update all 'sending' message states to 'failed'
        dependencies.storage.write { db in
            let changeCount: Int = try Attachment
                .filter(Attachment.Columns.state == Attachment.State.downloading)
                .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.failedDownload))
        
            Logger.debug("Marked \(changeCount) attachments as failed")
        }
        
        success(job, false, dependencies)
    }
}
