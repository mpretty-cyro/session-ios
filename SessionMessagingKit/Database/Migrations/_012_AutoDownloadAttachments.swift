// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration replaces the old 'Contact.isTrusted' flag with a new 'SessionThread.autoDownloadAttachments' flag so it
/// can be used across all types of conversations
enum _012_AutoDownloadAttachments: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "AutoDownloadAttachments"
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    
    static func migrate(_ db: Database) throws {
        try db.alter(table: SessionThread.self) { t in
            t.add(.autoDownloadAttachments, .boolean)
        }
        
        // Mark all existing closed groups as approved
        try SessionThread
            .filter(SessionThread.Columns.variant == SessionThread.Variant.contact)
            .joining(
                required: SessionThread.contact
                    .filter(Contact.Columns.isTrusted == true)
            )
            .updateAll(db, SessionThread.Columns.autoDownloadAttachments.set(to: true))
        
        // Retrieve all attachmentDownload jobs
        let attachmentDownloadJobs: [Job] = try Job
            .filter(Job.Columns.variant == Job.Variant.attachmentDownload)
            .fetchAll(db)
        let pendingAttachmentDownloadIds: [String] = attachmentDownloadJobs
            .compactMap { job in
                guard
                    let detailsData: Data = job.details,
                    let details: AttachmentDownloadJob.Details = try? JSONDecoder().decode(AttachmentDownloadJob.Details.self, from: detailsData)
                else { return nil }

                return details.attachmentId
            }

        // Update all attachments which don't have attachmentDownload jobs to 'notScheduled'
        try Attachment
            .filter(
                !pendingAttachmentDownloadIds.contains(Attachment.Columns.id) &&
                Attachment.Columns.state == Attachment.State.pendingDownload
            )
            .updateAll(db, Attachment.Columns.state.set(to: Attachment.State.notScheduled))
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
