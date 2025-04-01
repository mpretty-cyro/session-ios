// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB

// MARK: - Cache

internal extension Cache {
    static let transactionObserver: CacheConfig<TransactionObserverCacheType, TransactionObserverImmutableCacheType> = Dependencies.create(
        identifier: "transactionObserver",
        createInstance: { dependencies in Storage.TransactionObserverCache(using: dependencies) },
        mutableInstance: { $0 },
        erasedInstance: { $0 },
        immutableInstance: { $0.immutable }
    )
}

public extension Database {
    func makeFTS5Pattern<T>(rawPattern: String, forTable table: T.Type) throws -> FTS5Pattern where T: TableRecord, T: ColumnExpressible {
        return try makeFTS5Pattern(rawPattern: rawPattern, forTable: table.databaseTableName)
    }
    
    /// This is a custom implementation of the `afterNextTransaction` method which executes the closures within their own
    /// transactions to allow for nesting of 'afterNextTransaction' actions
    ///
    /// **Note:** GRDB doesn't notify read-only transactions to transaction observers
    func afterNextTransactionNested(
        using dependencies: Dependencies,
        onCommit: @escaping @Sendable (Database) -> Void,
        onRollback: @escaping @Sendable (Database) -> Void = { _ in }
    ) {
        guard
            let handler: TransactionHandler = dependencies.mutateSync(cache: .transactionObserver, {
                await $0.add(dedupeId: UUID().uuidString, onCommit: onCommit, onRollback: onRollback)
            })
        else { return }
        // TODO: [REFACTOR] Need to test this!!!
        self.add(transactionObserver: handler, extent: .nextTransaction)
    }
    
    func afterNextTransactionNestedOnce(
        dedupeId: String,
        using dependencies: Dependencies,
        onCommit: @escaping @Sendable (Database) -> Void,
        onRollback: @escaping @Sendable (Database) -> Void = { _ in }
    ) {
        guard
            let handler: TransactionHandler = dependencies.mutateSync(cache: .transactionObserver, {
                await $0.add(dedupeId: dedupeId, onCommit: onCommit, onRollback: onRollback)
            })
        else { return }
        // TODO: [REFACTOR] Need to test this!!!
        self.add(transactionObserver: handler, extent: .nextTransaction)
    }
}

internal final class TransactionHandler: TransactionObserver, Sendable {
    private let dependencies: Dependencies
    private let identifier: String
    private let onCommit: @Sendable (Database) -> Void
    private let onRollback: @Sendable (Database) -> Void

    init(
        identifier: String,
        onCommit: @escaping @Sendable (Database) -> Void,
        onRollback: @escaping @Sendable (Database) -> Void,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.identifier = identifier
        self.onCommit = onCommit
        self.onRollback = onRollback
    }
    
    // Ignore changes
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
    func databaseDidChange(with event: DatabaseEvent) { }
    
    func databaseDidCommit(_ db: Database) {
        dependencies.mutateSync(cache: .transactionObserver) { [identifier = self.identifier] observer in
            await observer.remove(for: identifier)
        }
        
        do {
            try db.inTransaction {
                onCommit(db)
                return .commit
            }
        }
        catch {
            Log.warn(.storage, "afterNextTransactionNested onCommit failed")
        }
    }
    
    func databaseDidRollback(_ db: Database) {
        dependencies.mutateSync(cache: .transactionObserver) { [identifier = self.identifier] observer in
            await observer.remove(for: identifier)
        }
        onRollback(db)
    }
}

// MARK: - TransactionObserver Cache

internal extension Storage {
    actor TransactionObserverCache: TransactionObserverCacheType {
        public struct Immutable: TransactionObserverImmutableCacheType {
            public var registeredHandlers: [String: TransactionHandler] = [:]
        }
        
        fileprivate let dependencies: Dependencies
        fileprivate var immutable: Immutable
        public var registeredHandlers: [String: TransactionHandler] { immutable.registeredHandlers }
        
        // MARK: - Initialization
        
        public init(using dependencies: Dependencies) {
            self.dependencies = dependencies
            self.immutable = Immutable(registeredHandlers: [:])
        }
        
        // MARK: - Functions
        
        public func add(
            dedupeId: String,
            onCommit: @escaping @Sendable (Database) -> Void,
            onRollback: @escaping @Sendable (Database) -> Void
        ) async -> TransactionHandler? {
            // Only allow a single observer per `dedupeId` per transaction, this allows us to
            // schedule an action to run at most once per transaction (eg. auto-scheduling a ConfigSyncJob
            // when receiving messages)
            guard immutable.registeredHandlers[dedupeId] == nil else { return nil }
            
            let observer: TransactionHandler = TransactionHandler(
                identifier: dedupeId,
                onCommit: onCommit,
                onRollback: onRollback,
                using: dependencies
            )
            immutable = Immutable(registeredHandlers: immutable.registeredHandlers.setting(dedupeId, observer))
            return observer
        }
        
        public func remove(for identifier: String) async {
            immutable = Immutable(registeredHandlers: immutable.registeredHandlers.removingValue(forKey: identifier))
        }
    }
}

// MARK: - TransactionObserverCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
internal protocol TransactionObserverImmutableCacheType: ImmutableCacheType {
    var registeredHandlers: [String: TransactionHandler] { get }
}

internal protocol TransactionObserverCacheType: MutableCacheType {
    func add(
        dedupeId: String,
        onCommit: @escaping @Sendable (Database) -> Void,
        onRollback: @escaping @Sendable (Database) -> Void
    ) async -> TransactionHandler?
    func remove(for identifier: String) async
    
    // MARK: - TransactionObserverImmutableCacheType Access
    
    var registeredHandlers: [String: TransactionHandler] { get async }
}
