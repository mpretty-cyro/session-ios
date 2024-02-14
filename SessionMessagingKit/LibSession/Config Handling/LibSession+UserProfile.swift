// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

internal extension LibSession {
    static let columnsRelatedToUserProfile: [Profile.Columns] = [
        Profile.Columns.name,
        Profile.Columns.profilePictureUrl,
        Profile.Columns.profileEncryptionKey
    ]
    
    static let syncedSettings: [String] = [
        Setting.BoolKey.checkForCommunityMessageRequests.rawValue
    ]
    
    // MARK: - Incoming Changes
    
    static func handleUserProfileUpdate(
        _ db: Database,
        in state: UnsafeMutablePointer<state_object>,
        serverTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws {
        // A profile must have a name so if this is null then it's invalid and can be ignored
        guard let profileNamePtr: UnsafePointer<CChar> = state_get_profile_name(state) else { return }
        
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        let profileName: String = String(cString: profileNamePtr)
        let profilePic: user_profile_pic = state_get_profile_pic(state)
        let profilePictureUrl: String? = String(libSessionVal: profilePic.url, nullIfEmpty: true)
        
        // Handle user profile changes
        try Profile.updateIfNeeded(
            db,
            publicKey: userSessionId.hexString,
            name: profileName,
            displayPictureUpdate: {
                guard let profilePictureUrl: String = profilePictureUrl else { return .remove }
                
                return .updateTo(
                    url: profilePictureUrl,
                    key: Data(
                        libSessionVal: profilePic.key,
                        count: DisplayPictureManager.aes256KeyByteLength
                    ),
                    fileName: nil
                )
            }(),
            sentTimestamp: TimeInterval(Double(serverTimestampMs) / 1000),
            calledFromConfigHandling: true,
            using: dependencies
        )
        
        // Update the 'Note to Self' visibility and priority
        let threadInfo: PriorityVisibilityInfo? = try? SessionThread
            .filter(id: userSessionId.hexString)
            .select(.id, .variant, .pinnedPriority, .shouldBeVisible)
            .asRequest(of: PriorityVisibilityInfo.self)
            .fetchOne(db)
        let targetPriority: Int32 = state_get_profile_nts_priority(state)
        
        // Create the 'Note to Self' thread if it doesn't exist
        if let threadInfo: PriorityVisibilityInfo = threadInfo {
            let threadChanges: [ConfigColumnAssignment] = [
                ((threadInfo.shouldBeVisible == LibSession.shouldBeVisible(priority: targetPriority)) ? nil :
                    SessionThread.Columns.shouldBeVisible.set(to: LibSession.shouldBeVisible(priority: targetPriority))
                ),
                (threadInfo.pinnedPriority == targetPriority ? nil :
                    SessionThread.Columns.pinnedPriority.set(to: targetPriority)
                )
            ].compactMap { $0 }
            
            if !threadChanges.isEmpty {
                try SessionThread
                    .filter(id: userSessionId.hexString)
                    .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                        db,
                        threadChanges
                    )
            }
        }
        else {
            try SessionThread
                .fetchOrCreate(
                    db,
                    id: userSessionId.hexString,
                    variant: .contact,
                    shouldBeVisible: LibSession.shouldBeVisible(priority: targetPriority),
                    calledFromConfigHandling: true
                )
            
            try SessionThread
                .filter(id: userSessionId.hexString)
                .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                    db,
                    SessionThread.Columns.pinnedPriority.set(to: targetPriority)
                )
            
            // If the 'Note to Self' conversation is hidden then we should trigger the proper
            // `deleteOrLeave` behaviour (for 'Note to Self' this will leave the conversation
            // but remove the associated interactions)
            if !LibSession.shouldBeVisible(priority: targetPriority) {
                try SessionThread
                    .deleteOrLeave(
                        db,
                        threadId: userSessionId.hexString,
                        threadVariant: .contact,
                        groupLeaveType: .silent,
                        calledFromConfigHandling: true,
                        using: dependencies
                    )
            }
        }
        
        // Update the 'Note to Self' disappearing messages configuration
        let targetExpiry: Int32 = state_get_profile_nts_expiry(state)
        let targetIsEnable: Bool = targetExpiry > 0
        let targetConfig: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration(
            threadId: userSessionId.hexString,
            isEnabled: targetIsEnable,
            durationSeconds: TimeInterval(targetExpiry),
            type: targetIsEnable ? .disappearAfterSend : .unknown,
            lastChangeTimestampMs: serverTimestampMs
        )
        let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
            .fetchOne(db, id: userSessionId.hexString)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(userSessionId.hexString))
        
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

        // Update settings if needed
        let updatedAllowBlindedMessageRequests: Int32 = state_get_profile_blinded_msgreqs(state)
        let updatedAllowBlindedMessageRequestsBoolValue: Bool = (updatedAllowBlindedMessageRequests >= 1)
        
        if
            updatedAllowBlindedMessageRequests >= 0 &&
            updatedAllowBlindedMessageRequestsBoolValue != db[.checkForCommunityMessageRequests]
        {
            db[.checkForCommunityMessageRequests] = updatedAllowBlindedMessageRequestsBoolValue
        }
        
        // Create a contact for the current user if needed (also force-approve the current user
        // in case the account got into a weird state or restored directly from a migration)
        let userContact: Contact = Contact.fetchOrCreate(db, id: userSessionId.hexString)
        
        if !userContact.isTrusted || !userContact.isApproved || !userContact.didApproveMe {
            try userContact.upsert(db)
            try Contact
                .filter(id: userSessionId.hexString)
                .updateAll( // Handling a config update so don't use `updateAllAndConfig`
                    db,
                    Contact.Columns.isTrusted.set(to: true),    // Always trust the current user
                    Contact.Columns.isApproved.set(to: true),
                    Contact.Columns.didApproveMe.set(to: true)
                )
        }
    }
    
    // MARK: - Outgoing Changes
    
    static func update(
        profile: Profile,
        in state: UnsafeMutablePointer<mutable_state_user_object>
    ) {
        // Update the name
        var updatedName: [CChar] = profile.name.cArray.nullTerminated()
        state_set_profile_name(state, &updatedName)
        
        // Either assign the updated profile pic, or sent a blank profile pic (to remove the current one)
        var profilePic: user_profile_pic = user_profile_pic()
        profilePic.url = profile.profilePictureUrl.toLibSession()
        profilePic.key = profile.profileEncryptionKey.toLibSession()
        state_set_profile_pic(state, profilePic)
    }
    
    static func updateNoteToSelf(
        priority: Int32? = nil,
        disappearingMessagesConfig: DisappearingMessagesConfiguration? = nil,
        in state: UnsafeMutablePointer<mutable_state_user_object>
    ) {
        if let priority: Int32 = priority {
            state_set_profile_nts_priority(state, priority)
        }
        
        if let config: DisappearingMessagesConfiguration = disappearingMessagesConfig {
            state_set_profile_nts_expiry(state, Int32(config.durationSeconds))
        }
    }
    
    static func updateSettings(
        checkForCommunityMessageRequests: Bool? = nil,
        in state: UnsafeMutablePointer<mutable_state_user_object>
    ) {
        if let blindedMessageRequests: Bool = checkForCommunityMessageRequests {
            state_set_profile_blinded_msgreqs(state, (blindedMessageRequests ? 1 : 0))
        }
    }
}

// MARK: - Direct Values

public extension LibSession.StateManager {
    var rawBlindedMessageRequestValue: Int32 {
        state_get_profile_blinded_msgreqs(state)
    }
}
