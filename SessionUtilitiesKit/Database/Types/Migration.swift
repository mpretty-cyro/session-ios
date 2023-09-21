// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public protocol Migration {
    static var target: TargetMigrations.Identifier { get }
    static var identifier: String { get }
    static var needsConfigSync: Bool { get }
    static var minExpectedRunDuration: TimeInterval { get }
    static var requirements: [MigrationRequirement] { get }
    
    static func migrate(_ db: Database) throws
}

public extension Migration {
    static var requirements: [MigrationRequirement] { [] }
    
    static func loggedMigrate(
        _ storage: Storage?,
        targetIdentifier: TargetMigrations.Identifier
    ) -> ((_ db: Database) throws -> ()) {
        return { (db: Database) in
            SNLogNotTests("[Migration Info] Starting \(targetIdentifier.key(with: self))")
            storage?.willStartMigration(db, self)
            storage?.internalCurrentlyRunningMigration.mutate { $0 = (targetIdentifier, self) }
            defer { storage?.internalCurrentlyRunningMigration.mutate { $0 = nil } }
            
            try migrate(db)
            SNLogNotTests("[Migration Info] Completed \(targetIdentifier.key(with: self))")
        }
    }
}
