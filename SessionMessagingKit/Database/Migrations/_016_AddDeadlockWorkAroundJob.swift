// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

/// This migration adds the `DeadLockWorkAroundJob` to run when the app becomes active
enum _016_AddDeadlockWorkAroundJob: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "AddDeadlockWorkAroundJob"
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    
    static func migrate(_ db: Database) throws {
        _ = try Job(
            variant: .processDeadlockWorkAround,
            behaviour: .recurringOnActive,
            shouldBlock: true
        ).migrationSafeInserted(db)
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}
