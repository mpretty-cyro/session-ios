// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

/// This migration recreates the interaction FTS table and adds the threadId so we can do a performant in-conversation
/// searh (currently it's much slower than the global search)
enum _012_AddClosedGroupInfo: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "AddClosedGroupInfo"
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.5
    
    static func migrate(_ db: Database) throws {
        try db.alter(table: ClosedGroup.self) { t in
            t.add(.groupDescription, .text)
            t.add(.groupImageUrl, .text)
            t.add(.groupImageFileName, .text)
            t.add(.groupImageEncryptionKey, .text)
            t.add(.privateKey, .blob)
            t.add(.memberPrivateKey, .blob)
            t.add(.isApproved, .boolean)
            t.add(.isDeleted, .boolean)
        }
        
        // Mark all existing closed groups as approved
        try ClosedGroup
            .updateAll(db, ClosedGroup.Columns.isApproved.set(to: true))
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
