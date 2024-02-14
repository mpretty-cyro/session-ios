// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionUIKit
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

// MARK: - Convenience

public extension LibSession {
    enum Crypto {
        public typealias Domain = String
    }
}

internal extension LibSession {
    /// This is a buffer period within which we will process messages which would result in a config change, any message which would normally
    /// result in a config change which was sent before `lastConfigMessage.timestamp - configChangeBufferPeriod` will not
    /// actually have it's changes applied (info messages would still be inserted though)
    static let configChangeBufferPeriod: TimeInterval = (2 * 60)
    
    static let columnsRelatedToThreads: [ColumnExpression] = [
        SessionThread.Columns.pinnedPriority,
        SessionThread.Columns.shouldBeVisible
    ]
    
    static func assignmentsRequireConfigUpdate(_ assignments: [ConfigColumnAssignment]) -> Bool {
        let targetColumns: Set<ColumnKey> = Set(assignments.map { ColumnKey($0.column) })
        let allColumnsThatTriggerConfigUpdate: Set<ColumnKey> = []
            .appending(contentsOf: columnsRelatedToUserProfile)
            .appending(contentsOf: columnsRelatedToContacts)
            .appending(contentsOf: columnsRelatedToConvoInfoVolatile)
            .appending(contentsOf: columnsRelatedToUserGroups)
            .appending(contentsOf: columnsRelatedToThreads)
            .appending(contentsOf: columnsRelatedToGroupInfo)
            .appending(contentsOf: columnsRelatedToGroupMembers)
            .appending(contentsOf: columnsRelatedToGroupKeys)
            .map { ColumnKey($0) }
            .asSet()
        
        return !allColumnsThatTriggerConfigUpdate.isDisjoint(with: targetColumns)
    }
    
    /// A `0` `priority` value indicates visible, but not pinned
    static let visiblePriority: Int32 = 0
    
    /// A negative `priority` value indicates hidden
    static let hiddenPriority: Int32 = -1
    
    static func shouldBeVisible(priority: Int32) -> Bool {
        return (priority >= LibSession.visiblePriority)
    }
    
    static func pushChangesIfNeeded(
        _ db: Database,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        using dependencies: Dependencies
    ) throws {
        try performAndPushChange(db, for: variant, sessionId: sessionId, using: dependencies) { _ in }
    }
    
    static func performAndPushChange(
        _ db: Database,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        using dependencies: Dependencies,
        change: (Config?) throws -> ()
    ) throws {
        // Since we are doing direct memory manipulation we are using an `Atomic`
        // type which has blocking access in it's `mutate` closure
        let needsPush: Bool
        
        do {
            needsPush = try dependencies[cache: .libSession]
                .config(for: variant, sessionId: sessionId)
                .mutate { config in
                    // Peform the change
                    try change(config)
                    
                    // If an error occurred during the change then actually throw it to prevent
                    // any database change from completing
                    if let lastError: LibSessionError = config?.lastError { throw lastError }

                    // If we don't need to dump the data the we can finish early
                    guard config.needsDump(using: dependencies) else { return config.needsPush }

                    try LibSession.createDump(
                        config: config,
                        for: variant,
                        sessionId: sessionId,
                        timestampMs: SnodeAPI.currentOffsetTimestampMs(using: dependencies),
                        using: dependencies
                    )?.upsert(db)

                    return config.needsPush
                }
        }
        catch {
            SNLog("[LibSession] Failed to update/dump updated \(variant) config data due to error: \(error)")
            throw error
        }
        
        // Make sure we need a push before scheduling one
        guard needsPush else { return }
        
        db.afterNextTransactionNestedOnce(dedupeId: LibSession.syncDedupeId(sessionId.hexString)) { db in
            ConfigurationSyncJob.enqueue(db, sessionIdHexString: sessionId.hexString)
        }
    }
    
    @discardableResult static func updatingThreads<T>(
        _ db: Database,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedThreads: [SessionThread] = updated as? [SessionThread] else {
            throw StorageError.generic
        }
        
        // If we have no updated threads then no need to continue
        guard !updatedThreads.isEmpty else { return updated }
        
        try dependencies[singleton: .libSession].mutate { state in
            try upsert(
                threads: updatedThreads,
                openGroupUrlInfo: try OpenGroupUrlInfo
                    .fetchAll(db, ids: updatedThreads.map { $0.id })
                    .reduce(into: [:]) { result, next in result[next.threadId] = next },
                in: state,
                using: dependencies
            )
        }
        
        return updated
    }
    
    static func upsert(
        threads: [SessionThread],
        openGroupUrlInfo: [String: OpenGroupUrlInfo],
        in state: UnsafeMutablePointer<mutable_state_user_object>,
        using dependencies: Dependencies
    ) throws {
        let userSessionId: SessionId = getUserSessionId(using: dependencies)
        let groupedThreads: [SessionThread.Variant: [SessionThread]] = threads
            .grouped(by: \.variant)
        
        // Update the unread state for the threads first (just in case that's what changed)
        try LibSession.updateMarkedAsUnreadState(
            threads: threads,
            openGroupUrlInfo: openGroupUrlInfo,
            in: state,
            using: dependencies
        )
        
        // Then update the `hidden` and `priority` values
        try groupedThreads.forEach { variant, threads in
            switch variant {
                case .contact:
                    // If the 'Note to Self' conversation is pinned then we need to custom handle it
                    // first as it's part of the UserProfile config
                    if let noteToSelf: SessionThread = threads.first(where: { $0.id == userSessionId.hexString }) {
                        LibSession.updateNoteToSelf(
                            priority: {
                                guard noteToSelf.shouldBeVisible else { return LibSession.hiddenPriority }
                                
                                return noteToSelf.pinnedPriority
                                    .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                    .defaulting(to: LibSession.visiblePriority)
                            }(),
                            in: state
                        )
                    }
                    
                    // Remove the 'Note to Self' convo from the list for updating contact priorities
                    let remainingThreads: [SessionThread] = threads.filter { $0.id != userSessionId.hexString }
                    
                    guard !remainingThreads.isEmpty else { return }
                    
                    try LibSession.upsert(
                        contactData: remainingThreads
                            .map { thread in
                                SyncedContactInfo(
                                    id: thread.id,
                                    priority: {
                                        guard thread.shouldBeVisible else { return LibSession.hiddenPriority }
                                        
                                        return thread.pinnedPriority
                                            .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                            .defaulting(to: LibSession.visiblePriority)
                                    }()
                                )
                            },
                        in: state,
                        using: dependencies
                    )
                    
                case .community:
                    try LibSession.upsert(
                        communities: threads
                            .compactMap { thread -> CommunityInfo? in
                                openGroupUrlInfo[thread.id].map { urlInfo in
                                    CommunityInfo(
                                        urlInfo: urlInfo,
                                        priority: thread.pinnedPriority
                                            .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                            .defaulting(to: LibSession.visiblePriority)
                                    )
                                }
                            },
                        in: state,
                        using: dependencies
                    )
                    
                case .legacyGroup:
                    try LibSession.upsert(
                        legacyGroups: threads
                            .map { thread in
                                LegacyGroupInfo(
                                    id: thread.id,
                                    priority: thread.pinnedPriority
                                        .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                        .defaulting(to: LibSession.visiblePriority)
                                )
                            },
                        in: state,
                        using: dependencies
                    )
                    
                case .group:
                    try LibSession.upsert(
                        groups: threads
                            .map { thread in
                                GroupInfo(
                                    groupSessionId: thread.id,
                                    priority: thread.pinnedPriority
                                        .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                        .defaulting(to: LibSession.visiblePriority)
                                )
                            },
                        in: state,
                        using: dependencies
                    )
            }
        }
    }
    
    static func hasSetting(
        _ db: Database,
        forKey key: String,
        using dependencies: Dependencies
    ) throws -> Bool {
        // Currently the only synced setting is 'checkForCommunityMessageRequests'
        switch key {
            case Setting.BoolKey.checkForCommunityMessageRequests.rawValue:
                return (dependencies[singleton: .libSession].rawBlindedMessageRequestValue >= 0)
            
            default: return false
        }
    }
    
    static func updatingSetting(
        _ updated: Setting?,
        using dependencies: Dependencies
    ) {
        // Ensure the setting is one which should be synced (we also don't currently support any nullable settings)
        guard
            let updatedSetting: Setting = updated,
            LibSession.syncedSettings.contains(updatedSetting.id)
        else { return }
        
        // Currently the only synced setting is 'checkForCommunityMessageRequests'
        switch updatedSetting.id {
            case Setting.BoolKey.checkForCommunityMessageRequests.rawValue:
                dependencies[singleton: .libSession].mutate { state in
                    LibSession.updateSettings(
                        checkForCommunityMessageRequests: updatedSetting.unsafeValue(as: Bool.self),
                        in: state
                    )
                }
                
            default: break
        }
    }
    
    static func kickFromConversationUIIfNeeded(removedThreadIds: [String], using dependencies: Dependencies) {
        guard !removedThreadIds.isEmpty else { return }
        
        // If the user is currently navigating somewhere within the view hierarchy of a conversation
        // we just deleted then return to the home screen
        DispatchQueue.main.async {
            guard
                dependencies.hasInitialised(singleton: .appContext),
                let rootViewController: UIViewController = dependencies[singleton: .appContext].mainWindow?.rootViewController,
                let topBannerController: TopBannerController = (rootViewController as? TopBannerController),
                !topBannerController.children.isEmpty,
                let navController: UINavigationController = topBannerController.children[0] as? UINavigationController
            else { return }
            
            // Extract the ones which will respond to LibSession changes
            let targetViewControllers: [any LibSessionRespondingViewController] = navController
                .viewControllers
                .compactMap { $0 as? LibSessionRespondingViewController }
            let presentedNavController: UINavigationController? = (navController.presentedViewController as? UINavigationController)
            let presentedTargetViewControllers: [any LibSessionRespondingViewController] = (presentedNavController?
                .viewControllers
                .compactMap { $0 as? LibSessionRespondingViewController })
                .defaulting(to: [])
            
            // Make sure we have a conversation list and that one of the removed conversations are
            // in the nav hierarchy
            let rootNavControllerNeedsPop: Bool = (
                targetViewControllers.count > 1 &&
                targetViewControllers.contains(where: { $0.isConversationList }) &&
                targetViewControllers.contains(where: { $0.isConversation(in: removedThreadIds) })
            )
            let presentedNavControllerNeedsPop: Bool = (
                presentedTargetViewControllers.count > 1 &&
                presentedTargetViewControllers.contains(where: { $0.isConversationList }) &&
                presentedTargetViewControllers.contains(where: { $0.isConversation(in: removedThreadIds) })
            )
            
            // Force the UI to refresh if needed (most screens should do this automatically via database
            // observation, but a couple of screens don't so need to be done manually)
            targetViewControllers
                .appending(contentsOf: presentedTargetViewControllers)
                .filter { $0.isConversationList }
                .forEach { $0.forceRefreshIfNeeded() }
            
            switch (rootNavControllerNeedsPop, presentedNavControllerNeedsPop) {
                case (true, false):
                    // Return to the conversation list as the removed conversation will be invalid
                    guard
                        let targetViewController: UIViewController = navController.viewControllers
                            .last(where: { viewController in
                                ((viewController as? LibSessionRespondingViewController)?.isConversationList)
                                    .defaulting(to: false)
                            })
                    else { return }
                    
                    if navController.presentedViewController != nil {
                        navController.dismiss(animated: false) {
                            navController.popToViewController(targetViewController, animated: true)
                        }
                    }
                    else {
                        navController.popToViewController(targetViewController, animated: true)
                    }
                    
                case (false, true):
                    // Return to the conversation list as the removed conversation will be invalid
                    guard
                        let targetViewController: UIViewController = presentedNavController?
                            .viewControllers
                            .last(where: { viewController in
                                ((viewController as? LibSessionRespondingViewController)?.isConversationList)
                                    .defaulting(to: false)
                            })
                    else { return }
                    
                    if presentedNavController?.presentedViewController != nil {
                        presentedNavController?.dismiss(animated: false) {
                            presentedNavController?.popToViewController(targetViewController, animated: true)
                        }
                    }
                    else {
                        presentedNavController?.popToViewController(targetViewController, animated: true)
                    }
                    
                default: break
            }
        }
    }
    
    static func canPerformChange(
        _ db: Database,
        threadId: String,
        targetConfig: ConfigDump.Variant,
        changeTimestampMs: Int64,
        using dependencies: Dependencies = Dependencies()
    ) -> Bool {
        let targetSessionId: String = {
            switch targetConfig {
                case .userProfile, .contacts, .convoInfoVolatile, .userGroups:
                    return getUserSessionId(db, using: dependencies).hexString
                    
                case .groupInfo, .groupMembers, .groupKeys: return threadId
                case .invalid: return ""
            }
        }()
        
        let configDumpTimestampMs: Int64 = (try? ConfigDump
            .filter(
                ConfigDump.Columns.variant == targetConfig &&
                ConfigDump.Columns.sessionId == targetSessionId
            )
            .select(.timestampMs)
            .asRequest(of: Int64.self)
            .fetchOne(db))
            .defaulting(to: 0)
        
        // Ensure the change occurred after the last config message was handled (minus the buffer period)
        return (changeTimestampMs >= (configDumpTimestampMs - Int64(LibSession.configChangeBufferPeriod * 1000)))
    }
    
    static func checkLoopLimitReached(_ loopCounter: inout Int, for variant: ConfigDump.Variant, maxLoopCount: Int = 50000) throws {
        loopCounter += 1
        
        guard loopCounter < maxLoopCount else {
            SNLog("[LibSession] Got stuck in infinite loop processing '\(variant.description)' data")
            throw LibSessionError.processingLoopLimitReached
        }
    }
}

// MARK: - StateManager

public extension LibSession.StateManager {
    func conversationInConfig(threadId: String, rawThreadVariant: Int, visibleOnly: Bool, using dependencies: Dependencies) -> Bool {
        guard let threadVariant: SessionThread.Variant = SessionThread.Variant(rawValue: rawThreadVariant) else {
            return false
        }
        
        let userSessionId: SessionId = getUserSessionId(using: dependencies)
        
        switch threadVariant {
            case .contact:
                // The 'Note to Self' conversation is stored in the 'userProfile' config
                guard threadId != userSessionId.hexString else {
                    return (
                        !visibleOnly ||
                        LibSession.shouldBeVisible(priority: state_get_profile_nts_priority(state))
                    )
                }

                guard let contact: CContact = contact(sessionId: threadId) else { return false }

                /// If the user opens a conversation with an existing contact but doesn't send them a message
                /// then the one-to-one conversation should remain hidden so we want to delete the `SessionThread`
                /// when leaving the conversation
                return (!visibleOnly || LibSession.shouldBeVisible(priority: contact.priority))
                
            case .community:
                guard
                    let urlInfo: LibSession.OpenGroupUrlInfo = dependencies[singleton: .storage]
                        .read({ db in try LibSession.OpenGroupUrlInfo.fetchAll(db, ids: [threadId]) })?
                        .first
                else { return false }

                /// Not handling the `hidden` behaviour for communities so just indicate the existence
                return (community(server: urlInfo.server, roomToken: urlInfo.roomToken) != nil)
                
            case .legacyGroup:
                guard var groupInfo: CLegacyGroup = legacyGroup(legacyGroupId: threadId) else { return false }

                /// Not handling the `hidden` behaviour for legacy groups so just indicate the existence (also need to explicitly free the legacy group object)
                ugroups_legacy_group_free(groupInfo)
                return true
                
            /// Not handling the `hidden` behaviour for legacy groups so just indicate the existence
            case .group: return (group(groupSessionId: threadId) != nil)
        }
    }
}

// MARK: - ColumnKey

internal extension LibSession {
    struct ColumnKey: Equatable, Hashable {
        let sourceType: Any.Type
        let columnName: String
        
        init(_ column: ColumnExpression) {
            self.sourceType = type(of: column)
            self.columnName = column.name
        }
        
        func hash(into hasher: inout Hasher) {
            ObjectIdentifier(sourceType).hash(into: &hasher)
            columnName.hash(into: &hasher)
        }
        
        static func == (lhs: ColumnKey, rhs: ColumnKey) -> Bool {
            return (
                lhs.sourceType == rhs.sourceType &&
                lhs.columnName == rhs.columnName
            )
        }
    }
}

// MARK: - PriorityVisibilityInfo

extension LibSession {
    struct PriorityVisibilityInfo: Codable, FetchableRecord, Identifiable {
        let id: String
        let variant: SessionThread.Variant
        let pinnedPriority: Int32?
        let shouldBeVisible: Bool
    }
}

// MARK: - LibSessionRespondingViewController

public protocol LibSessionRespondingViewController {
    var isConversationList: Bool { get }
    
    func isConversation(in threadIds: [String]) -> Bool
    func forceRefreshIfNeeded()
}

public extension LibSessionRespondingViewController {
    var isConversationList: Bool { false }
    
    func isConversation(in threadIds: [String]) -> Bool { return false }
    func forceRefreshIfNeeded() {}
}
