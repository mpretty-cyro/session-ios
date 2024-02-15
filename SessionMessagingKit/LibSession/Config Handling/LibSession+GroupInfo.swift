// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Size Restrictions

public extension LibSession {
    static var sizeMaxGroupDescriptionBytes: Int { GROUP_INFO_DESCRIPTION_MAX_LENGTH }
    
    static func isTooLong(groupDescription: String) -> Bool {
        return (groupDescription.utf8CString.count > LibSession.sizeMaxGroupDescriptionBytes)
    }
}

// MARK: - UserGroups Wrapper

public extension LibSession.StateManager {
    func groupDeleteBefore(groupId: SessionId) -> Int64 {
        var cGroupId: [CChar] = groupId.hexString.cArray
        var cTimestamp: Int64 = 0
        
        guard state_get_groups_info_delete_before(state, &cGroupId, &cTimestamp) else { return 0 }
        
        return cTimestamp
    }
    
    func groupAttachDeleteBefore(groupId: SessionId) -> Int64 {
        var cGroupId: [CChar] = groupId.hexString.cArray
        var cTimestamp: Int64 = 0
        
        guard state_get_groups_info_attach_delete_before(state, &cGroupId, &cTimestamp) else { return 0 }
        
        return cTimestamp
    }
}

// MARK: - Group Info Handling

internal extension LibSession {
    static let columnsRelatedToGroupInfo: [ColumnExpression] = [
        ClosedGroup.Columns.name,
        ClosedGroup.Columns.groupDescription,
        ClosedGroup.Columns.displayPictureUrl,
        ClosedGroup.Columns.displayPictureEncryptionKey,
        DisappearingMessagesConfiguration.Columns.isEnabled,
        DisappearingMessagesConfiguration.Columns.type,
        DisappearingMessagesConfiguration.Columns.durationSeconds
    ]
    
    // MARK: - Incoming Changes
    
    static func handleGroupInfoUpdate(
        _ db: Database,
        in state: UnsafeMutablePointer<state_object>,
        groupSessionId: SessionId,
        serverTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws {
        var cGroupId: [CChar] = groupSessionId.hexString.cArray
        
        // If the group is destroyed then remove the group date (want to keep the group itself around because
        // the UX of conversations randomly disappearing isn't great) - no other changes matter and this
        // can't be reversed
        guard !state_groups_info_is_destroyed(state, &cGroupId) else {
            try ClosedGroup.removeData(
                db,
                threadIds: [groupSessionId.hexString],
                dataToRemove: [
                    .poller, .pushNotifications, .messages, .members,
                    .encryptionKeys, .authDetails, .libSessionState
                ],
                calledFromConfigHandling: true,
                using: dependencies
            )
            return
        }

        // A group must have a name so if this is null then it's invalid and can be ignored
        var cGroupName: [CChar] = [CChar](repeating: 0, count: LibSession.sizeMaxGroupNameBytes)
        var cGroupDescription: [CChar] = [CChar](repeating: 0, count: LibSession.sizeMaxGroupDescriptionBytes)
        var cFormationTimestamp: Int64 = 0
        
        guard state_get_groups_info_name(state, &cGroupId, &cGroupName) else { return }

        let groupName: String = String(cString: cGroupName)
        var groupDesc: String?
        var formationTimestamp: TimeInterval = 0
        
        if state_get_groups_info_description(state, &cGroupId, &cGroupDescription) {
            groupDesc = String(cString: cGroupDescription)
        }
        
        if state_get_groups_info_created(state, &cGroupId, &cFormationTimestamp) {
            formationTimestamp = TimeInterval(cFormationTimestamp)
        }
        
        // The `displayPic.key` can contain junk data so if the `displayPictureUrl` is null then just
        // set the `displayPictureKey` to null as well
        var displayPic: user_profile_pic = user_profile_pic()
        state_get_groups_info_pic(state, &cGroupId, &displayPic)
        let displayPictureUrl: String? = String(libSessionVal: displayPic.url, nullIfEmpty: true)
        let displayPictureKey: Data? = (displayPictureUrl == nil ? nil :
            Data(
                libSessionVal: displayPic.key,
                count: DisplayPictureManager.aes256KeyByteLength
            )
        )

        // Update the group name
        let existingGroup: ClosedGroup? = try? ClosedGroup
            .filter(id: groupSessionId.hexString)
            .fetchOne(db)
        let needsDisplayPictureUpdate: Bool = (
            existingGroup?.displayPictureUrl != displayPictureUrl ||
            existingGroup?.displayPictureEncryptionKey != displayPictureKey
        )

        let groupChanges: [ConfigColumnAssignment] = [
            ((existingGroup?.name == groupName) ? nil :
                ClosedGroup.Columns.name.set(to: groupName)
            ),
            ((existingGroup?.groupDescription == groupDesc) ? nil :
                ClosedGroup.Columns.groupDescription.set(to: groupDesc)
            ),
            ((existingGroup?.formationTimestamp == formationTimestamp || formationTimestamp == 0) ? nil :
                ClosedGroup.Columns.formationTimestamp.set(to: formationTimestamp)
            ),
            // If we are removing the display picture do so here
            (!needsDisplayPictureUpdate || displayPictureUrl != nil ? nil :
                ClosedGroup.Columns.displayPictureUrl.set(to: nil)
            ),
            (!needsDisplayPictureUpdate || displayPictureUrl != nil ? nil :
                ClosedGroup.Columns.displayPictureFilename.set(to: nil)
            ),
            (!needsDisplayPictureUpdate || displayPictureUrl != nil ? nil :
                ClosedGroup.Columns.displayPictureEncryptionKey.set(to: nil)
            ),
            (!needsDisplayPictureUpdate || displayPictureUrl != nil ? nil :
                ClosedGroup.Columns.lastDisplayPictureUpdate.set(to: (serverTimestampMs / 1000))
            )
        ].compactMap { $0 }

        if !groupChanges.isEmpty {
            try ClosedGroup
                .filter(id: groupSessionId.hexString)
                .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                    db,
                    groupChanges
                )
        }

        // If we have a display picture then start downloading it
        if needsDisplayPictureUpdate, let url: String = displayPictureUrl, let key: Data = displayPictureKey {
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .displayPictureDownload,
                    shouldBeUnique: true,
                    details: DisplayPictureDownloadJob.Details(
                        target: .group(id: groupSessionId.hexString, url: url, encryptionKey: key),
                        timestamp: TimeInterval(Double(serverTimestampMs) / 1000)
                    )
                ),
                canStartJob: true,
                using: dependencies
            )
        }

        // Update the disappearing messages configuration
        var cTargetExpiry: Int32 = 0
        state_get_groups_info_expiry_timer(state, &cGroupId, &cTargetExpiry)
        let targetIsEnable: Bool = (cTargetExpiry > 0)
        let targetConfig: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration(
            threadId: groupSessionId.hexString,
            isEnabled: targetIsEnable,
            durationSeconds: TimeInterval(cTargetExpiry),
            type: (targetIsEnable ? .disappearAfterSend : .unknown),
            lastChangeTimestampMs: serverTimestampMs
        )
        let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
            .fetchOne(db, id: groupSessionId.hexString)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(groupSessionId.hexString))

        if
            let remoteLastChangeTimestampMs = targetConfig.lastChangeTimestampMs,
            let localLastChangeTimestampMs = localConfig.lastChangeTimestampMs,
            remoteLastChangeTimestampMs > localLastChangeTimestampMs
        {
            _ = try localConfig.with(
                isEnabled: targetConfig.isEnabled,
                durationSeconds: targetConfig.durationSeconds,
                type: targetConfig.type,
                lastChangeTimestampMs: targetConfig.lastChangeTimestampMs
            ).upsert(db)
        }
        
        // Check if the user is an admin in the group
        var messageHashesToDelete: Set<String> = []
        let isAdmin: Bool = ((try? ClosedGroup
            .filter(id: groupSessionId.hexString)
            .select(.groupIdentityPrivateKey)
            .asRequest(of: Data.self)
            .fetchOne(db)) != nil)

        // If there is a `delete_before` setting then delete all messages before the provided timestamp
        var cDeleteBeforeTimestamp: Int64 = 0
        
        if state_get_groups_info_delete_before(state, &cGroupId, &cDeleteBeforeTimestamp) {
            if isAdmin {
                let hashesToDelete: Set<String>? = try? Interaction
                    .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                    .filter(Interaction.Columns.timestampMs < (TimeInterval(cDeleteBeforeTimestamp) * 1000))
                    .filter(Interaction.Columns.serverHash != nil)
                    .select(.serverHash)
                    .asRequest(of: String.self)
                    .fetchSet(db)
                messageHashesToDelete.insert(contentsOf: hashesToDelete)
            }
            // TODO: Make sure to delete any known hashes from the server as well when triggering
            let deletionCount: Int = try Interaction
                .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                .filter(Interaction.Columns.timestampMs < (TimeInterval(cDeleteBeforeTimestamp) * 1000))
                .deleteAll(db)
            
            if deletionCount > 0 {
                SNLog("[LibSession] Deleted \(deletionCount) message\(deletionCount == 1 ? "" : "s") from \(groupSessionId.hexString) due to 'delete_before' value.")
            }
        }
        
        // If there is a `attach_delete_before` setting then delete all messages that have attachments before
        // the provided timestamp and schedule a garbage collection job
        var cAttachDeleteBeforeTimestamp: Int64 = 0
        
        if state_get_groups_info_attach_delete_before(state, &cGroupId, &cAttachDeleteBeforeTimestamp) {
            if isAdmin {
                let hashesToDelete: Set<String>? = try? Interaction
                    .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                    .filter(Interaction.Columns.timestampMs < (TimeInterval(cAttachDeleteBeforeTimestamp) * 1000))
                    .filter(Interaction.Columns.serverHash != nil)
                    .joining(required: Interaction.interactionAttachments)
                    .select(.serverHash)
                    .asRequest(of: String.self)
                    .fetchSet(db)
                messageHashesToDelete.insert(contentsOf: hashesToDelete)
            }
            // TODO: Make sure to delete any known hashes from the server as well when triggering
            let deletionCount: Int = try Interaction
                .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                .filter(Interaction.Columns.timestampMs < (TimeInterval(cAttachDeleteBeforeTimestamp) * 1000))
                .joining(required: Interaction.interactionAttachments)
                .deleteAll(db)
            
            if deletionCount > 0 {
                SNLog("[LibSession] Deleted \(deletionCount) message\(deletionCount == 1 ? "" : "s") with attachments from \(groupSessionId.hexString) due to 'attach_delete_before' value.")
                
                // Schedule a grabage collection job to clean up any now-orphaned attachment files
                dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .garbageCollection,
                        details: GarbageCollectionJob.Details(
                            typesToCollect: [.orphanedAttachments, .orphanedAttachmentFiles]
                        )
                    ),
                    canStartJob: true,
                    using: dependencies
                )
            }
        }
        
        // If the current user is a group admin and there are message hashes which should be deleted then
        // send a fire-and-forget API call to delete the messages from the swarm
        if isAdmin && !messageHashesToDelete.isEmpty {
            (try? Authentication.with(
                db,
                sessionIdHexString: groupSessionId.hexString,
                using: dependencies
            )).map { authMethod in
                try? SnodeAPI
                    .preparedDeleteMessages(
                        serverHashes: Array(messageHashesToDelete),
                        requireSuccessfulDeletion: false,
                        authMethod: authMethod,
                        using: dependencies
                    )
                    .send(using: dependencies)
                    .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
                    .sinkUntilComplete()
            }
        }
    }
}

// MARK: - Outgoing Changes

internal extension LibSession {
    static func updatingGroupInfo<T>(
        _ db: Database,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedGroups: [ClosedGroup] = updated as? [ClosedGroup] else { throw StorageError.generic }
        
        // Exclude legacy groups as they aren't managed via LibSession
        let targetGroups: [ClosedGroup] = updatedGroups
            .filter { (try? SessionId(from: $0.id))?.prefix == .group }
        
        // If we only updated the current user contact then no need to continue
        guard !targetGroups.isEmpty else { return updated }
        
        // Loop through each of the groups and update their settings
        try targetGroups.forEach { group in
            dependencies[singleton: .libSession].mutate(groupId: SessionId(.group, hex: group.id)) { state in
                /// Update the name
                ///
                /// **Note:** We indentionally only update the `GROUP_INFO` and not the `USER_GROUPS` as once the
                /// group is synced between devices we want to rely on the proper group config to get display info
                var updatedName: [CChar] = group.name.cArray.nullTerminated()
                state_set_groups_info_name(state, &updatedName)
                
                var updatedDescription: [CChar] = (group.groupDescription ?? "").cArray.nullTerminated()
                state_set_groups_info_description(state, &updatedDescription)
                
                // Either assign the updated display pic, or sent a blank pic (to remove the current one)
                var displayPic: user_profile_pic = user_profile_pic()
                displayPic.url = group.displayPictureUrl.toLibSession()
                displayPic.key = group.displayPictureEncryptionKey.toLibSession()
                state_set_groups_info_pic(state, displayPic)
            }
        }
        
        return updated
    }
    
    static func updatingDisappearingConfigsGroups<T>(
        _ db: Database,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedDisappearingConfigs: [DisappearingMessagesConfiguration] = updated as? [DisappearingMessagesConfiguration] else { throw StorageError.generic }
        
        // Filter out any disappearing config changes not related to updated groups
        let targetUpdatedConfigs: [DisappearingMessagesConfiguration] = updatedDisappearingConfigs
            .filter { (try? SessionId.Prefix(from: $0.id)) == .group }
        
        guard !targetUpdatedConfigs.isEmpty else { return updated }
        
        // We should only sync disappearing messages configs which are associated to existing groups
        let existingGroupIds: [String] = (try? ClosedGroup
            .filter(ids: targetUpdatedConfigs.map { $0.id })
            .select(.threadId)
            .asRequest(of: String.self)
            .fetchAll(db))
            .defaulting(to: [])
        
        // If none of the disappearing messages configs are associated with existing groups then ignore
        // the changes (no need to do a config sync)
        guard !existingGroupIds.isEmpty else { return updated }
        
        // Loop through each of the groups and update their settings
        existingGroupIds
            .compactMap { groupId in targetUpdatedConfigs.first(where: { $0.id == groupId }).map { (groupId, $0) } }
            .forEach { groupId, updatedConfig in
                dependencies[singleton: .libSession].mutate(groupId: SessionId(.group, hex: groupId)) { state in
                    state_set_groups_info_expiry_timer(state, Int32(updatedConfig.durationSeconds))
                }
            }
        
        return updated
    }
}

// MARK: - External Outgoing Changes

public extension LibSession {
    static func update(
        groupSessionId: SessionId,
        disappearingConfig: DisappearingMessagesConfiguration?,
        using dependencies: Dependencies
    ) {
        guard let config: DisappearingMessagesConfiguration = disappearingConfig else { return }
        
        dependencies[singleton: .libSession].mutate(groupId: groupSessionId) { state in
            state_set_groups_info_expiry_timer(state, Int32(config.durationSeconds))
        }
    }
    
    static func deleteMessagesBefore(
        groupSessionId: SessionId,
        timestamp: TimeInterval,
        using dependencies: Dependencies
    ) throws {
        // Do nothing if the timestamp isn't newer than the current value
        guard Int64(timestamp) > dependencies[singleton: .libSession].groupDeleteBefore(groupId: groupSessionId) else { return }
        
        dependencies[singleton: .libSession].mutate(groupId: groupSessionId) { state in
            state_set_groups_info_delete_before(state, Int64(timestamp))
        }
    }
    
    static func deleteAttachmentsBefore(
        groupSessionId: SessionId,
        timestamp: TimeInterval,
        using dependencies: Dependencies
    ) throws {
        // Do nothing if the timestamp isn't newer than the current value
        guard Int64(timestamp) > dependencies[singleton: .libSession].groupAttachDeleteBefore(groupId: groupSessionId) else {
            return
        }
        
        dependencies[singleton: .libSession].mutate(groupId: groupSessionId) { state in
            state_set_groups_info_attach_delete_before(state, Int64(timestamp))
        }
    }
    
    static func deleteGroupForEveryone(
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) throws {
        dependencies[singleton: .libSession].mutate(groupId: groupSessionId) { state in
            state_destroy_group(state)
        }
    }
}
