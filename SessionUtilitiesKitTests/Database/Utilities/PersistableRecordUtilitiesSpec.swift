// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

import Quick
import Nimble

@testable import SessionUtilitiesKit

class PersistableRecordUtilitiesSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var customWriter: DatabaseQueue! = try! DatabaseQueue()
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: customWriter,
            migrationTargets: [
                TestTarget.self
            ],
            using: dependencies
        )
        
        // MARK: - a PersistableRecord
        describe("a PersistableRecord") {
            // MARK: -- before running the add column migration
            context("before running the add column migration") {
                // MARK: ---- fails when using the standard insert
                it("fails when using the standard insert") {
                    mockStorage.write { db in
                        expect {
                            try TestType(columnA: "Test1", columnB: "Test1B").insert(db)
                        }
                        .to(throwError())
                    }
                }
                
                // MARK: ---- fails when using the standard inserted
                it("fails when using the standard inserted") {
                    mockStorage.write { db in
                        expect {
                            try MutableTestType(columnA: "Test2", columnB: "Test2B").inserted(db)
                        }
                        .to(throwError())
                    }
                }
                
                // MARK: ---- fails when using the standard save and the item does not already exist
                it("fails when using the standard save and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            try TestType(columnA: "Test3", columnB: "Test3B").upsert(db)
                        }
                        .to(throwError())
                    }
                }
                
                // MARK: ---- fails when using the standard saved and the item does not already exist
                it("fails when using the standard saved and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            try MutableTestType(columnA: "Test4", columnB: "Test4B").upserted(db)
                        }
                        .to(throwError())
                    }
                }
                
                // MARK: ---- fails when using the standard upsert and the item does not already exist
                it("fails when using the standard upsert and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            try TestType(columnA: "Test5", columnB: "Test5B").upsert(db)
                        }
                        .to(throwError())
                    }
                }
                
                // MARK: ---- fails when using the standard mutable upsert and the item does not already exist
                it("fails when using the standard mutable upsert and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            var result = MutableTestType(columnA: "Test6", columnB: "Test6B")
                            try result.upsert(db)
                            return result
                        }
                        .to(throwError())
                    }
                }
                
                // MARK: ---- fails when using the standard upsert and the item already exists
                it("fails when using the standard upsert and the item already exists") {
                    mockStorage.write { db in
                        expect {
                            try db.execute(
                                sql: "INSERT INTO TestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test19"])
                            )
                            try TestType(columnA: "Test19", columnB: "Test19B").upsert(db)
                        }
                        .to(throwError())
                    }
                }
                
                // MARK: ---- fails when using the standard mutable upsert and the item already exists
                it("fails when using the standard mutable upsert and the item already exists") {
                    mockStorage.write { db in
                        expect {
                            try db.execute(
                                sql: "INSERT INTO MutableTestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test20"])
                            )
                            var result = MutableTestType(id: 1, columnA: "Test20", columnB: "Test20B")
                            try result.upsert(db)
                            return result
                        }
                        .to(throwError())
                    }
                }
                
                // MARK: ---- succeeds when using the migration safe insert
                it("succeeds when using the migration safe insert") {
                    mockStorage.write { db in
                        expect {
                            try TestType(columnA: "Test7", columnB: "Test7B").migrationSafeInsert(db)
                        }
                        .toNot(throwError())
                    }
                    
                    mockStorage.read { db in
                        expect(try TestType.fetchAll(db))
                            .toNot(beNil())
                    }
                }
                
                // MARK: ---- succeeds when using the migration safe inserted
                it("succeeds when using the migration safe inserted") {
                    mockStorage.write { db in
                        expect {
                            try MutableTestType(columnA: "Test8", columnB: "Test8B").migrationSafeInserted(db)
                        }
                        .toNot(throwError())
                        
                        expect {
                            try MutableTestType(columnA: "Test9", columnB: "Test9B")
                                .migrationSafeInserted(db)
                                .id
                        }
                        .toNot(beNil())
                    }
                    
                    mockStorage.read { db in
                        expect(try MutableTestType.fetchAll(db))
                            .toNot(beNil())
                    }
                }
                
                // MARK: ---- succeeds when using the migration safe upsert and the item does not already exist
                it("succeeds when using the migration safe save and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            try TestType(columnA: "Test10", columnB: "Test10B").migrationSafeUpsert(db)
                        }
                        .toNot(throwError())
                    }
                }
                
                // MARK: ---- succeeds when using the migration safe upsert and the item does not already exist
                it("succeeds when using the migration safe saved and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            try MutableTestType(columnA: "Test11", columnB: "Test11B").migrationSafeUpsert(db)
                        }
                        .toNot(throwError())
                        
                        expect {
                            try MutableTestType(columnA: "Test12", columnB: "Test12B").migrationSafeUpsert(db)
                            return try MutableTestType
                                .filter(MutableTestType.Columns.columnA == "Test12")
                                .fetchOne(db)?
                                .id
                        }
                        .toNot(beNil())
                    }
                    
                    mockStorage.read { db in
                        expect(try MutableTestType.fetchAll(db))
                            .toNot(beNil())
                    }
                }
                
                // MARK: ---- succeeds when using the migration safe upsert and the item does not already exist
                it("succeeds when using the migration safe upsert and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            try TestType(columnA: "Test13", columnB: "Test13B").migrationSafeUpsert(db)
                        }
                        .toNot(throwError())
                    }
                }
                
                // MARK: ---- succeeds when using the migration safe mutable upsert and the item does not already exist
                it("succeeds when using the migration safe mutable upsert and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            let result = MutableTestType(columnA: "Test14", columnB: "Test14B")
                            try result.migrationSafeUpsert(db)
                            return result
                        }
                        .toNot(throwError())
                    }
                    
                    mockStorage.read { db in
                        expect(try MutableTestType.fetchAll(db))
                            .toNot(beNil())
                    }
                }
                
                // MARK: ---- succeeds when using the standard save and the item already exists
                it("succeeds when using the standard save and the item already exists") {
                    /// **Note:** The built-in 'update' method only updates existing columns so this shouldn't fail
                    mockStorage.write { db in
                        expect {
                            try db.execute(
                                sql: "INSERT INTO TestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test16"])
                            )
                            try TestType(columnA: "Test16", columnB: "Test16B").save(db)
                        }
                        .toNot(throwError())
                    }
                }
                
                // MARK: ---- succeeds when using the standard saved and the item already exists
                it("succeeds when using the standard saved and the item already exists") {
                    /// **Note:** The built-in 'update' method only updates existing columns so this won't fail
                    /// due to the structure discrepancy but won't update the id as that only happens on insert
                    mockStorage.write { db in
                        expect {
                            try db.execute(
                                sql: "INSERT INTO MutableTestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test17"])
                            )
                            _ = try MutableTestType(id: 1, columnA: "Test17", columnB: "Test17B").saved(db)
                        }
                        .toNot(throwError())
                        
                        expect {
                            try db.execute(
                                sql: "INSERT INTO MutableTestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test18"])
                            )
                            return try MutableTestType(id: 2, columnA: "Test18", columnB: "Test18B")
                                .saved(db)
                                .id
                        }
                        .toNot(beNil())
                    }
                    
                    mockStorage.read { db in
                        let types: [MutableTestType]? = try MutableTestType.fetchAll(db)
                        
                        expect(types).toNot(beNil())
                        expect(types?.compactMap { $0.id }.count).to(equal(types?.count))
                    }
                }
            }
            
            // MARK: -- after running the add column migration
            context("after running the add column migration") {
                beforeEach {
                    var migrator: DatabaseMigrator = DatabaseMigrator()
                    migrator.registerMigration(
                        mockStorage,
                        targetIdentifier: TestAddColumnMigration.target,
                        migration: TestAddColumnMigration.self,
                        using: dependencies
                    )
                    
                    expect { try migrator.migrate(customWriter) }
                        .toNot(throwError())
                }
                
                // MARK: ---- succeeds when using the standard insert
                it("succeeds when using the standard insert") {
                    mockStorage.write { db in
                        expect {
                            try TestType(columnA: "Test1", columnB: "Test1B").insert(db)
                        }
                        .toNot(throwError())
                    }
                    
                    mockStorage.read { db in
                        expect(try TestType.fetchAll(db))
                            .toNot(beNil())
                    }
                }
                
                // MARK: ---- succeeds when using the standard inserted
                it("succeeds when using the standard inserted") {
                    mockStorage.write { db in
                        expect {
                            try MutableTestType(columnA: "Test2", columnB: "Test2B").inserted(db)
                        }
                        .toNot(throwError())
                    }
                    
                    mockStorage.read { db in
                        expect(try MutableTestType.fetchAll(db))
                            .toNot(beNil())
                    }
                }
                
                // MARK: ---- succeeds when using the standard save and the item does not already exist
                it("succeeds when using the standard save and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            try TestType(columnA: "Test3", columnB: "Test3B").upsert(db)
                        }
                        .toNot(throwError())
                    }
                }
                
                // MARK: ---- succeeds when using the standard saved and the item does not already exist
                it("succeeds when using the standard saved and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            try MutableTestType(columnA: "Test3", columnB: "Test3B").upserted(db)
                        }
                        .toNot(throwError())
                    }
                }
                
                // MARK: ---- succeeds when using the standard save and the item already exists
                it("succeeds when using the standard save and the item already exists") {
                    mockStorage.write { db in
                        expect {
                            try db.execute(
                                sql: "INSERT INTO TestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test4"])
                            )
                            try TestType(columnA: "Test4", columnB: "Test4B").upsert(db)
                        }
                        .toNot(throwError())
                    }
                }
                
                // MARK: ---- succeeds when using the standard saved and the item already exists
                it("succeeds when using the standard saved and the item already exists") {
                    /// **Note:** The built-in 'update' method won't update the id as that only happens on insert
                    mockStorage.write { db in
                        expect {
                            try db.execute(
                                sql: "INSERT INTO MutableTestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test5"])
                            )
                            _ = try MutableTestType(id: 1, columnA: "Test5", columnB: "Test5B").upserted(db)
                        }
                        .toNot(throwError())
                        
                        expect {
                            try db.execute(
                                sql: "INSERT INTO MutableTestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test6"])
                            )
                            return try MutableTestType(id: 2, columnA: "Test6", columnB: "Test6B")
                                .saved(db)
                                .id
                        }
                        .toNot(beNil())
                    }
                    
                    mockStorage.read { db in
                        let types: [MutableTestType]? = try MutableTestType.fetchAll(db)
                        
                        expect(types).toNot(beNil())
                        expect(types?.compactMap { $0.id }.count).to(equal(types?.count))
                    }
                }
                
                // MARK: ---- succeeds when using the standard upsert and the item does not already exist
                it("succeeds when using the standard upsert and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            try TestType(columnA: "Test7", columnB: "Test7B").upsert(db)
                        }
                        .toNot(throwError())
                    }
                }
                
                // MARK: ---- succeeds when using the standard mutable upsert and the item does not already exist
                it("succeeds when using the standard mutable upsert and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            var result = MutableTestType(columnA: "Test8", columnB: "Test8B")
                            try result.upsert(db)
                            return result
                        }
                        .toNot(throwError())
                    }
                }
                
                // MARK: ---- succeeds when using the standard upsert and the item already exists
                it("succeeds when using the standard upsert and the item already exists") {
                    mockStorage.write { db in
                        expect {
                            try db.execute(
                                sql: "INSERT INTO TestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test9"])
                            )
                            try TestType(columnA: "Test9", columnB: "Test9B").upsert(db)
                        }
                        .toNot(throwError())
                    }
                }
                
                // MARK: ---- succeeds when using the standard mutable upsert and the item already exists
                it("succeeds when using the standard mutable upsert and the item already exists") {
                    /// **Note:** The built-in 'update' method won't update the id as that only happens on insert
                    mockStorage.write { db in
                        expect {
                            try db.execute(
                                sql: "INSERT INTO MutableTestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test10"])
                            )
                            var result = MutableTestType(id: 1, columnA: "Test10", columnB: "Test10B")
                            try result.upsert(db)
                            return result
                        }
                        .toNot(throwError())
                        
                        expect {
                            try db.execute(
                                sql: "INSERT INTO MutableTestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test11"])
                            )
                            var result = MutableTestType(id: 2, columnA: "Test11", columnB: "Test11B")
                            try result.upsert(db)
                            return result.id
                        }
                        .toNot(beNil())
                    }
                    
                    mockStorage.read { db in
                        let types: [MutableTestType]? = try MutableTestType.fetchAll(db)
                        
                        expect(types).toNot(beNil())
                        expect(types?.compactMap { $0.id }.count).to(equal(types?.count))
                    }
                }
                
                // MARK: ---- succeeds when using the migration safe insert
                it("succeeds when using the migration safe insert") {
                    mockStorage.write { db in
                        expect {
                            try TestType(columnA: "Test12", columnB: "Test12B").migrationSafeInsert(db)
                        }
                        .toNot(throwError())
                    }
                    
                    mockStorage.read { db in
                        expect(try TestType.fetchAll(db))
                            .toNot(beNil())
                    }
                }
                
                // MARK: ---- succeeds when using the migration safe inserted
                it("succeeds when using the migration safe inserted") {
                    mockStorage.write { db in
                        expect {
                            try MutableTestType(columnA: "Test13", columnB: "Test13B").migrationSafeInserted(db)
                        }
                        .toNot(throwError())
                        
                        expect {
                            try MutableTestType(columnA: "Test14", columnB: "Test14B")
                                .migrationSafeInserted(db)
                                .id
                        }
                        .toNot(beNil())
                    }
                    
                    mockStorage.read { db in
                        expect(try MutableTestType.fetchAll(db))
                            .toNot(beNil())
                    }
                }
                
                // MARK: ---- succeeds when using the migration safe insert and the item does not already exist
                it("succeeds when using the migration safe insert and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            try TestType(columnA: "Test15", columnB: "Test15B").migrationSafeInsert(db)
                        }
                        .toNot(throwError())
                    }
                }
                
                // MARK: ---- succeeds when using the migration safe upsert and the item already exists
                it("succeeds when using the migration safe upsert and the item already exists") {
                    mockStorage.write { db in
                        expect {
                            try db.execute(
                                sql: "INSERT INTO TestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test17"])
                            )
                            try TestType(columnA: "Test17", columnB: "Test17B").migrationSafeUpsert(db)
                        }
                        .toNot(throwError())
                    }
                    
                    mockStorage.read { db in
                        let types: [MutableTestType]? = try MutableTestType.fetchAll(db)
                        
                        expect(types).toNot(beNil())
                        expect(types?.compactMap { $0.id }.count).to(equal(types?.count))
                    }
                }
                
                // MARK: ---- succeeds when using the migration safe upsert and the item does not already exist
                it("succeeds when using the migration safe upsert and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            try TestType(columnA: "Test20", columnB: "Test20B").migrationSafeUpsert(db)
                        }
                        .toNot(throwError())
                    }
                }
                
                // MARK: ---- succeeds when using the migration safe mutable upsert and the item does not already exist
                it("succeeds when using the migration safe mutable upsert and the item does not already exist") {
                    mockStorage.write { db in
                        expect {
                            let result = MutableTestType(columnA: "Test21", columnB: "Test21B")
                            try result.migrationSafeUpsert(db)
                            return result
                        }
                        .toNot(throwError())
                    }
                }
                
                // MARK: ---- succeeds when using the migration safe upsert and the item already exists
                it("succeeds when using the migration safe upsert and the item already exists") {
                    mockStorage.write { db in
                        expect {
                            try db.execute(
                                sql: "INSERT INTO TestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test22"])
                            )
                            try TestType(columnA: "Test22", columnB: "Test22B").migrationSafeUpsert(db)
                        }
                        .toNot(throwError())
                    }
                }
                
                // MARK: ---- succeeds when using the migration safe mutable upsert and the item already exists
                it("succeeds when using the migration safe mutable upsert and the item already exists") {
                    /// **Note:** The built-in 'update' method won't update the id as that only happens on insert
                    mockStorage.write { db in
                        expect {
                            try db.execute(
                                sql: "INSERT INTO MutableTestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test23"])
                            )
                            let result = MutableTestType(id: 1, columnA: "Test23", columnB: "Test23B")
                            try result.migrationSafeUpsert(db)
                            return result
                        }
                        .toNot(throwError())
                        
                        expect {
                            try db.execute(
                                sql: "INSERT INTO MutableTestType (columnA) VALUES (?)",
                                arguments: StatementArguments(["Test24"])
                            )
                            let result = MutableTestType(id: 2, columnA: "Test24", columnB: "Test24B")
                            try result.migrationSafeUpsert(db)
                            return result.id
                        }
                        .toNot(beNil())
                    }
                    
                    mockStorage.read { db in
                        let types: [MutableTestType]? = try MutableTestType.fetchAll(db)
                        
                        expect(types).toNot(beNil())
                        expect(types?.compactMap { $0.id }.count).to(equal(types?.count))
                    }
                }
            }
        }
    }
}

// MARK: - Test Types

fileprivate struct TestType: Codable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "TestType" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case columnA
        case columnB
    }
    
    public let columnA: String
    public let columnB: String?
}

fileprivate struct MutableTestType: Codable, FetchableRecord, MutablePersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "MutableTestType" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case columnA
        case columnB
    }
    
    public var id: Int64?
    public let columnA: String
    public let columnB: String?
    
    init(id: Int64? = nil, columnA: String, columnB: String?) {
        self.id = id
        self.columnA = columnA
        self.columnB = columnB
    }
    
    mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }
}

fileprivate enum TestInsertTestTypeMigration: Migration {
    static let target: TargetMigrations.Identifier = .test
    static let identifier: String = "TestInsertTestType"
    static let minExpectedRunDuration: TimeInterval = 0
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(FetchableRecord & TableRecord).Type] = [TestType.self, MutableTestType.self]
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.create(table: TestType.self) { t in
            t.column(.columnA, .text).primaryKey()
        }
        
        try db.create(table: MutableTestType.self) { t in
            t.column(.id, .integer).primaryKey(autoincrement: true)
            t.column(.columnA, .text).unique()
        }
    }
}

fileprivate enum TestAddColumnMigration: Migration {
    static let target: TargetMigrations.Identifier = .test
    static let identifier: String = "TestAddColumn"
    static let minExpectedRunDuration: TimeInterval = 0
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(FetchableRecord & TableRecord).Type] = [TestType.self, MutableTestType.self]
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.alter(table: TestType.self) { t in
            t.add(.columnB, .text)
        }
        
        try db.alter(table: MutableTestType.self) { t in
            t.add(.columnB, .text)
        }
    }
}

fileprivate struct TestTarget: MigratableTarget {
    static func migrations() -> TargetMigrations {
        return TargetMigrations(
            identifier: .test,
            migrations: (0..<100)
                .map { _ in [] }
                .appending([TestInsertTestTypeMigration.self])
        )
    }
}
