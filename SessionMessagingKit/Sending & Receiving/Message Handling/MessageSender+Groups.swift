// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

extension MessageSender {
    private typealias PreparedGroupData = (
        thread: SessionThread,
        members: [GroupMember],
        preparedNotificationsSubscription: HTTP.PreparedRequest<PushNotificationAPI.SubscribeResponse>?
    )
    
    public static func createGroup(
        name: String,
        description: String?,
        displayPictureData: Data?,
        members: [(String, Profile?)],
        using dependencies: Dependencies
    ) -> AnyPublisher<SessionThread, Error> {
        typealias ImageUploadResponse = (downloadUrl: String, fileName: String, encryptionKey: Data)
        
        return Just(())
            .setFailureType(to: Error.self)
            .flatMap { _ -> AnyPublisher<ImageUploadResponse?, Error> in
                guard let displayPictureData: Data = displayPictureData else {
                    return Just(nil)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                return Deferred {
                    Future<ImageUploadResponse?, Error> { resolver in
                        DisplayPictureManager.prepareAndUploadDisplayPicture(
                            queue: DispatchQueue.global(qos: .userInitiated),
                            imageData: displayPictureData,
                            success: { resolver(Result.success($0)) },
                            failure: { resolver(Result.failure($0)) },
                            using: dependencies
                        )
                    }
                }.eraseToAnyPublisher()
            }
            .flatMap { displayPictureInfo -> AnyPublisher<(String, [UInt8]), Error> in
                Deferred {
                    Future<(String, [UInt8]), Error> { resolver in
                        dependencies[singleton: .libSession].createGroup(
                            name: name,
                            description: description,
                            displayPictureUrl: displayPictureInfo?.downloadUrl,
                            displayPictureEncryptionKey: displayPictureInfo?.encryptionKey,
                            members: members.map { ($0.0, $0.1?.name, $0.1?.profilePictureUrl, $0.1?.profileEncryptionKey) }
                        ) { groupId, groupIdentityPrivateKey, error in
                            guard error == nil else {
                                SNLog("Failed to create group due to error: \(error ?? .unknown)")
                                return resolver(Result.failure(error ?? .unknown))
                            }
                            
                            resolver(Result.success((groupId, groupIdentityPrivateKey)))
                        }
                    }
                }.eraseToAnyPublisher()
            }
            .flatMap { groupId, groupIdentityPrivateKey -> AnyPublisher<PreparedGroupData, Error> in
                dependencies[singleton: .storage].writePublisher(using: dependencies) { db -> PreparedGroupData in
                    // Note: These objects should already exist in the database becuase the 'createGroup' triggers the
                    // libSession 'store' hook which will insert them
                    let thread: SessionThread = try SessionThread
                        .fetchOrCreate(
                            db,
                            id: groupId,
                            variant: .group,
                            shouldBeVisible: true,
                            calledFromConfigHandling: false,
                            using: dependencies
                        )
                    let members: [GroupMember] = try GroupMember
                        .filter(GroupMember.Columns.groupId == groupId)
                        .fetchAll(db)
                    
                    // Prepare the notification subscription
                    var preparedNotificationSubscription: HTTP.PreparedRequest<PushNotificationAPI.SubscribeResponse>?
                    
                    if let token: String = dependencies[defaults: .standard, key: .deviceToken] {
                        preparedNotificationSubscription = try? PushNotificationAPI
                            .preparedSubscribe(
                                db,
                                token: Data(hex: token),
                                sessionIds: [SessionId(.group, hex: groupId)],
                                using: dependencies
                            )
                    }
                    
                    return (thread, members, preparedNotificationSubscription)
                }
            }
            .handleEvents(
                receiveOutput: { thread, members, preparedNotificationSubscription in
                    // Start polling
                    dependencies[singleton: .groupsPoller].startIfNeeded(for: thread.id, using: dependencies)
                    
                    // Subscribe for push notifications (if PNs are enabled)
                    preparedNotificationSubscription?
                        .send(using: dependencies)
                        .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                        .sinkUntilComplete()
                    
                    // Save jobs for sending group member invitations
                    dependencies[singleton: .storage].write(using: dependencies) { db in
                        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                        
                        members
                            .filter { $0.profileId != userSessionId.hexString }
                            .compactMap { member -> (GroupMember, GroupInviteMemberJob.Details)? in
                                // Generate authData for the removed member
                                guard
                                    let memberAuthInfo: Authentication.Info = try? LibSession.generateAuthData(
                                        groupSessionId: SessionId(.group, hex: thread.id),
                                        memberId: member.profileId,
                                        using: dependencies
                                    ),
                                    let jobDetails: GroupInviteMemberJob.Details = try? GroupInviteMemberJob.Details(
                                        memberSessionIdHexString: member.profileId,
                                        authInfo: memberAuthInfo
                                    )
                                else { return nil }
                                
                                return (member, jobDetails)
                            }
                            .forEach { member, jobDetails in
                                dependencies[singleton: .jobRunner].add(
                                    db,
                                    job: Job(
                                        variant: .groupInviteMember,
                                        threadId: thread.id,
                                        details: jobDetails
                                    ),
                                    canStartJob: true,
                                    using: dependencies
                                )
                            }
                    }
                }
            )
            .map { thread, _, _ in thread }
            .eraseToAnyPublisher()
    }
    
    public static func updateGroup(
        groupSessionId: String,
        name: String,
        groupDescription: String?,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard let sessionId: SessionId = try? SessionId(from: groupSessionId), sessionId.prefix == .group else {
            // FIXME: Fail with `MessageSenderError.invalidClosedGroupUpdate` once support for legacy groups is removed
            let maybeMemberIds: Set<String>? = dependencies[singleton: .storage].read(using: dependencies) { db in
                try GroupMember
                    .filter(GroupMember.Columns.groupId == groupSessionId)
                    .select(.profileId)
                    .asRequest(of: String.self)
                    .fetchSet(db)
            }
            
            guard let memberIds: Set<String> = maybeMemberIds else {
                return Fail(error: MessageSenderError.invalidClosedGroupUpdate).eraseToAnyPublisher()
            }
            
            return MessageSender.update(
                legacyGroupSessionId: groupSessionId,
                with: memberIds,
                name: name,
                using: dependencies
            )
        }
        
        return dependencies[singleton: .storage]
            .writePublisher { db in
                guard let closedGroup: ClosedGroup = try? ClosedGroup.fetchOne(db, id: sessionId.hexString) else {
                    throw MessageSenderError.invalidClosedGroupUpdate
                }
                
                let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                let changeTimestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs(using: dependencies)
                
                var groupChanges: [ConfigColumnAssignment] = []
                
                if name != closedGroup.name { groupChanges.append(ClosedGroup.Columns.name.set(to: name)) }
                if groupDescription != closedGroup.groupDescription {
                    groupChanges.append(ClosedGroup.Columns.groupDescription.set(to: groupDescription))
                }
                
                // Update the group (this will be propagated to libSession configs automatically)
                if !groupChanges.isEmpty {
                    _ = try ClosedGroup
                        .filter(id: sessionId.hexString)
                        .updateAllAndConfig(
                            db,
                            ClosedGroup.Columns.name.set(to: name),
                            ClosedGroup.Columns.groupDescription.set(to: groupDescription),
                            using: dependencies
                        )
                }
                
                // Add a record of the name change to the conversation
                if name != closedGroup.name {
                    _ = try Interaction(
                        threadId: groupSessionId,
                        authorId: userSessionId.hexString,
                        variant: .infoGroupInfoUpdated,
                        body: ClosedGroup.MessageInfo
                            .updatedName(name)
                            .infoString(using: dependencies),
                        timestampMs: changeTimestampMs
                    ).inserted(db)
                    
                    // Schedule the control message to be sent to the group
                    try MessageSender.send(
                        db,
                        message: GroupUpdateInfoChangeMessage(
                            changeType: .name,
                            updatedName: name,
                            sentTimestamp: UInt64(changeTimestampMs),
                            authMethod: try Authentication.with(
                                db,
                                sessionIdHexString: groupSessionId,
                                using: dependencies
                            ),
                            using: dependencies
                        ),
                        interactionId: nil,
                        threadId: sessionId.hexString,
                        threadVariant: .group,
                        using: dependencies
                    )
                }
            }
            .eraseToAnyPublisher()
    }
    
    public static func updateGroup(
        groupSessionId: String,
        displayPictureUpdate: DisplayPictureManager.Update,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard let sessionId: SessionId = try? SessionId(from: groupSessionId), sessionId.prefix == .group else {
            return Fail(error: MessageSenderError.invalidClosedGroupUpdate).eraseToAnyPublisher()
        }
        
        return dependencies[singleton: .storage]
            .writePublisher { db in
                let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                let changeTimestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs(using: dependencies)
                
                switch displayPictureUpdate {
                    case .remove:
                        try ClosedGroup
                            .filter(id: groupSessionId)
                            .updateAllAndConfig(
                                db,
                                ClosedGroup.Columns.displayPictureUrl.set(to: nil),
                                ClosedGroup.Columns.displayPictureEncryptionKey.set(to: nil),
                                ClosedGroup.Columns.displayPictureFilename.set(to: nil),
                                ClosedGroup.Columns.lastDisplayPictureUpdate.set(to: dependencies.dateNow)
                            )
                        
                    case .updateTo(let url, let key, let fileName):
                        try ClosedGroup
                            .filter(id: groupSessionId)
                            .updateAllAndConfig(
                                db,
                                ClosedGroup.Columns.displayPictureUrl.set(to: url),
                                ClosedGroup.Columns.displayPictureEncryptionKey.set(to: key),
                                ClosedGroup.Columns.displayPictureFilename.set(to: fileName),
                                ClosedGroup.Columns.lastDisplayPictureUpdate.set(to: dependencies.dateNow)
                            )
                        
                    default: throw MessageSenderError.invalidClosedGroupUpdate
                }
                
                // Add a record of the change to the conversation
                _ = try Interaction(
                    threadId: groupSessionId,
                    authorId: userSessionId.hexString,
                    variant: .infoGroupInfoUpdated,
                    body: ClosedGroup.MessageInfo
                        .updatedDisplayPicture
                        .infoString(using: dependencies),
                    timestampMs: changeTimestampMs
                ).inserted(db)
                
                // Schedule the control message to be sent to the group
                try MessageSender.send(
                    db,
                    message: GroupUpdateInfoChangeMessage(
                        changeType: .avatar,
                        sentTimestamp: UInt64(changeTimestampMs),
                        authMethod: try Authentication.with(
                            db,
                            sessionIdHexString: groupSessionId,
                            using: dependencies
                        ),
                        using: dependencies
                    ),
                    interactionId: nil,
                    threadId: sessionId.hexString,
                    threadVariant: .group,
                    using: dependencies
                )
            }
            .eraseToAnyPublisher()
    }
    
    public static func addGroupMembers(
        groupSessionId: String,
        members: [(id: String, profile: Profile?)],
        allowAccessToHistoricMessages: Bool,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard let sessionId: SessionId = try? SessionId(from: groupSessionId), sessionId.prefix == .group else {
            return Fail(error: MessageSenderError.invalidClosedGroupUpdate).eraseToAnyPublisher()
        }
        
        return Deferred {
            Future<Void, Error> { resolver in
                dependencies[singleton: .libSession].addGroupMembers(
                    groupSessionId: sessionId,
                    allowAccessToHistoricMessages: allowAccessToHistoricMessages,
                    members: members.map { ($0.id, $0.profile?.name, $0.profile?.profilePictureUrl, $0.profile?.profileEncryptionKey) }
                ) { [dependencies] error in
                    // Invite process failed to update libSession
                    guard error == nil else { return resolver(Result.failure(error ?? LibSessionError.unknown)) }
                    
                    dependencies[singleton: .storage].writeAsync(using: dependencies) { db in
                        guard
                            let groupIdentityPrivateKey: Data = try? ClosedGroup
                                .filter(id: sessionId.hexString)
                                .select(.groupIdentityPrivateKey)
                                .asRequest(of: Data.self)
                                .fetchOne(db)
                        else { throw MessageSenderError.invalidClosedGroupUpdate }
                        
                        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                        let changeTimestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs(using: dependencies)
                        
                        /// Generate the data needed to send the new members invitations to the group
                        let memberJobData: [(id: String, profile: Profile?, jobDetails: GroupInviteMemberJob.Details, subaccountToken: [UInt8])] = try members
                            .map { id, profile in
                                // Generate authData for the newly added member
                                let subaccountToken: [UInt8] = try LibSession.generateSubaccountToken(
                                    groupSessionId: sessionId,
                                    memberId: id,
                                    using: dependencies
                                )
                                let memberAuthInfo: Authentication.Info = try LibSession.generateAuthData(
                                    groupSessionId: sessionId,
                                    memberId: id,
                                    using: dependencies
                                )
                                let inviteDetails: GroupInviteMemberJob.Details = try GroupInviteMemberJob.Details(
                                    memberSessionIdHexString: id,
                                    authInfo: memberAuthInfo
                                )
                                
                                return (id, profile, inviteDetails, subaccountToken)
                            }
                        
                        /// Unrevoke the newly added members just in case they had previously gotten their access to the group
                        /// revoked (fire-and-forget this request, we don't want it to be blocking - if the invited user still can't access
                        /// the group the admin can resend their invitation which will also attempt to unrevoke their subaccount)
                        try SnodeAPI.preparedUnrevokeSubaccounts(
                            subaccountsToUnrevoke: memberJobData.map { _, _, _, subaccountToken in subaccountToken },
                            authMethod: Authentication.groupAdmin(
                                groupSessionId: sessionId,
                                ed25519SecretKey: Array(groupIdentityPrivateKey)
                            ),
                            using: dependencies
                        )
                        .send(using: dependencies)
                        .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
                        .sinkUntilComplete()
                        
                        /// Make the required changes for each added member
                        try memberJobData.forEach { id, profile, inviteJobDetails, _ in
                            /// Add the member to the database
                            try GroupMember(
                                groupId: sessionId.hexString,
                                profileId: id,
                                role: .standard,
                                roleStatus: .sending,
                                isHidden: false
                            ).upsert(db)
                            
                            /// Schedule a job to send an invitation to the newly added member
                            dependencies[singleton: .jobRunner].add(
                                db,
                                job: Job(
                                    variant: .groupInviteMember,
                                    threadId: sessionId.hexString,
                                    details: inviteJobDetails
                                ),
                                canStartJob: true,
                                using: dependencies
                            )
                        }
                        
                        /// Add a record of the change to the conversation
                        _ = try Interaction(
                            threadId: groupSessionId,
                            authorId: userSessionId.hexString,
                            variant: .infoGroupMembersUpdated,
                            body: ClosedGroup.MessageInfo
                                .addedUsers(
                                    names: members.map { id, profile in
                                        profile?.displayName(for: .group) ??
                                        Profile.truncated(id: id, truncating: .middle)
                                    }
                                )
                                .infoString(using: dependencies),
                            timestampMs: changeTimestampMs
                        ).inserted(db)
                        
                        /// Schedule the control message to be sent to the group
                        try MessageSender.send(
                            db,
                            message: GroupUpdateMemberChangeMessage(
                                changeType: .added,
                                memberSessionIds: members.map { $0.id },
                                sentTimestamp: UInt64(changeTimestampMs),
                                authMethod: try Authentication.with(
                                    db,
                                    sessionIdHexString: groupSessionId,
                                    using: dependencies
                                ),
                                using: dependencies
                            ),
                            interactionId: nil,
                            threadId: sessionId.hexString,
                            threadVariant: .group,
                            using: dependencies
                        )
                    }
                    
                    // Invite process successfully updated libSession
                    resolver(Result.success(()))
                }
            }
        }.eraseToAnyPublisher()
    }
    
    public static func resendInvitation(
        groupSessionId: String,
        memberId: String,
        using dependencies: Dependencies
    ) {
        guard let sessionId: SessionId = try? SessionId(from: groupSessionId), sessionId.prefix == .group else { return }
        
        dependencies[singleton: .storage].writeAsync(using: dependencies) { [dependencies] db in
            guard
                let groupIdentityPrivateKey: Data = try? ClosedGroup
                    .filter(id: groupSessionId)
                    .select(.groupIdentityPrivateKey)
                    .asRequest(of: Data.self)
                    .fetchOne(db)
            else { throw MessageSenderError.invalidClosedGroupUpdate }
            
            let subaccountToken: [UInt8] = try LibSession.generateSubaccountToken(
                groupSessionId: sessionId,
                memberId: memberId,
                using: dependencies
            )
            let inviteDetails: GroupInviteMemberJob.Details = try GroupInviteMemberJob.Details(
                memberSessionIdHexString: memberId,
                authInfo: try LibSession.generateAuthData(
                    groupSessionId: sessionId,
                    memberId: memberId,
                    using: dependencies
                )
            )
            
            /// Unrevoke the member just in case they had previously gotten their access to the group revoked and the
            /// unrevoke request when initially added them failed (fire-and-forget this request, we don't want it to be blocking)
            try SnodeAPI
                .preparedUnrevokeSubaccounts(
                    subaccountsToUnrevoke: [subaccountToken],
                    authMethod: Authentication.groupAdmin(
                        groupSessionId: sessionId,
                        ed25519SecretKey: Array(groupIdentityPrivateKey)
                    ),
                    using: dependencies
                )
                .send(using: dependencies)
                .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
                .sinkUntilComplete()
            
            try LibSession.updateMemberStatus(
                groupSessionId: SessionId(.group, hex: groupSessionId),
                memberId: memberId,
                role: .standard,
                status: .sending,
                using: dependencies
            )
            
            /// If the current `GroupMember` is in the `failed` state then change them back to `sending`
            let existingMember: GroupMember? = try GroupMember
                .filter(GroupMember.Columns.groupId == groupSessionId)
                .filter(GroupMember.Columns.profileId == memberId)
                .fetchOne(db)
            
            switch (existingMember?.role, existingMember?.roleStatus) {
                case (.standard, .failed):
                    try GroupMember
                        .filter(GroupMember.Columns.groupId == groupSessionId)
                        .filter(GroupMember.Columns.profileId == memberId)
                        .updateAllAndConfig(
                            db,
                            GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.sending),
                            using: dependencies
                        )
                    
                default: break
            }
            
            /// Schedule a job to send an invitation to the newly added member
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .groupInviteMember,
                    threadId: groupSessionId,
                    details: inviteDetails
                ),
                canStartJob: true,
                using: dependencies
            )
        }
    }
    
    public static func removeGroupMembers(
        groupSessionId: String,
        memberIds: Set<String>,
        removeTheirMessages: Bool,
        sendMemberChangedMessage: Bool,
        changeTimestampMs: Int64? = nil,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard let sessionId: SessionId = try? SessionId(from: groupSessionId), sessionId.prefix == .group else {
            return Just(()).setFailureType(to: Error.self).eraseToAnyPublisher()
        }
        
        let targetChangeTimestampMs: Int64 = (
            changeTimestampMs ??
            SnodeAPI.currentOffsetTimestampMs(using: dependencies)
        )
        
        return dependencies[singleton: .storage]
            .writePublisher(using: dependencies) { db in
                guard
                    let groupIdentityPrivateKey: Data = try? ClosedGroup
                        .filter(id: sessionId.hexString)
                        .select(.groupIdentityPrivateKey)
                        .asRequest(of: Data.self)
                        .fetchOne(db)
                else { throw MessageSenderError.invalidClosedGroupUpdate }
                
                /// Flag the members for removal
                try LibSession.flagMembersForRemoval(
                    groupSessionId: sessionId,
                    memberIds: memberIds,
                    removeMessages: removeTheirMessages,
                    using: dependencies
                )
                
                /// Remove the members from the database (will result in the UI being updated, we do this now even though the
                /// change hasn't been properly processed yet because after flagging members for removal they will no longer be
                /// considered part of the group when processing `GROUP_MEMBERS` config messages)
                try GroupMember
                    .filter(GroupMember.Columns.groupId == sessionId.hexString)
                    .filter(memberIds.contains(GroupMember.Columns.profileId))
                    .deleteAll(db)
                
                /// Schedule a job to process the removals
                dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .processPendingGroupMemberRemovals,
                        threadId: sessionId.hexString,
                        details: ProcessPendingGroupMemberRemovalsJob.Details(
                            changeTimestampMs: changeTimestampMs
                        )
                    ),
                    canStartJob: true,
                    using: dependencies
                )
                
                /// Send the member changed message if desired
                if sendMemberChangedMessage {
                    let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                    let removedMemberProfiles: [String: Profile] = (try? Profile
                        .filter(ids: memberIds)
                        .fetchAll(db))
                        .defaulting(to: [])
                        .reduce(into: [:]) { result, next in result[next.id] = next }
                    
                    /// Add a record of the change to the conversation
                    _ = try Interaction(
                        threadId: sessionId.hexString,
                        authorId: userSessionId.hexString,
                        variant: .infoGroupMembersUpdated,
                        body: ClosedGroup.MessageInfo
                            .removedUsers(
                                names: memberIds.map { id in
                                    removedMemberProfiles[id]?.displayName(for: .group) ??
                                    Profile.truncated(id: id, truncating: .middle)
                                }
                            )
                            .infoString(using: dependencies),
                        timestampMs: targetChangeTimestampMs
                    ).inserted(db)
                    
                    /// Schedule the control message to be sent to the group
                    try MessageSender.send(
                        db,
                        message: GroupUpdateMemberChangeMessage(
                            changeType: .removed,
                            memberSessionIds: Array(memberIds),
                            sentTimestamp: UInt64(targetChangeTimestampMs),
                            authMethod: Authentication.groupAdmin(
                                groupSessionId: sessionId,
                                ed25519SecretKey: Array(groupIdentityPrivateKey)
                            ),
                            using: dependencies
                        ),
                        interactionId: nil,
                        threadId: sessionId.hexString,
                        threadVariant: .group,
                        using: dependencies
                    )
                }
            }
            .eraseToAnyPublisher()
    }
    
    public static func promoteGroupMembers(
        groupSessionId: SessionId,
        members: [(id: String, profile: Profile?)],
        sendAdminChangedMessage: Bool,
        using dependencies: Dependencies
    ) {
        let changeTimestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs(using: dependencies)
        
        dependencies[singleton: .storage].writeAsync(using: dependencies) { db in
            // Update the libSession status for each member and schedule a job to send
            // the promotion message
            try members.forEach { memberId, _ in
                try LibSession.updateMemberStatus(
                    groupSessionId: groupSessionId,
                    memberId: memberId,
                    role: .admin,
                    status: .sending,
                    using: dependencies
                )
                
                /// If the current `GroupMember` is in the `failed` state then change them back to `sending`
                let existingMember: GroupMember? = try GroupMember
                    .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
                    .filter(GroupMember.Columns.profileId == memberId)
                    .fetchOne(db)
                
                switch (existingMember?.role, existingMember?.roleStatus) {
                    case (.standard, _):
                        try GroupMember
                            .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
                            .filter(GroupMember.Columns.profileId == memberId)
                            .updateAllAndConfig(
                                db,
                                GroupMember.Columns.role.set(to: GroupMember.Role.admin),
                                GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.sending),
                                using: dependencies
                            )
                        
                    case (.admin, .failed):
                        try GroupMember
                            .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
                            .filter(GroupMember.Columns.profileId == memberId)
                            .updateAllAndConfig(
                                db,
                                GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.sending),
                                using: dependencies
                            )
                        
                    default: break
                }
                
                dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .groupPromoteMember,
                        threadId: groupSessionId.hexString,
                        details: GroupPromoteMemberJob.Details(
                            memberSessionIdHexString: memberId
                        )
                    ),
                    canStartJob: true,
                    using: dependencies
                )
            }
            
            /// Send the admin changed message if desired
            if sendAdminChangedMessage {
                let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                _ = try Interaction(
                    threadId: groupSessionId.hexString,
                    authorId: userSessionId.hexString,
                    variant: .infoGroupMembersUpdated,
                    body: ClosedGroup.MessageInfo
                        .promotedUsers(
                            names: members.map { id, profile in
                                profile?.displayName(for: .group) ??
                                Profile.truncated(id: id, truncating: .middle)
                            }
                        )
                        .infoString(using: dependencies),
                    timestampMs: changeTimestampMs
                ).inserted(db)
                
                /// Schedule the control message to be sent to the group
                try MessageSender.send(
                    db,
                    message: GroupUpdateMemberChangeMessage(
                        changeType: .promoted,
                        memberSessionIds: members.map { $0.id },
                        sentTimestamp: UInt64(changeTimestampMs),
                        authMethod: try Authentication.with(
                            db,
                            sessionIdHexString: groupSessionId.hexString,
                            using: dependencies
                        ),
                        using: dependencies
                    ),
                    interactionId: nil,
                    threadId: groupSessionId.hexString,
                    threadVariant: .group,
                    using: dependencies
                )
            }
        }
    }
    
    /// Leave the group with the given `groupPublicKey`. If the current user is the only admin, the group is disbanded entirely.
    ///
    /// This function also removes all encryption key pairs associated with the closed group and the group's public key, and
    /// unregisters from push notifications.
    public static func leave(
        _ db: Database,
        groupPublicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        
        // Notify the user
        let interaction: Interaction = try Interaction(
            threadId: groupPublicKey,
            authorId: userSessionId.hexString,
            variant: .infoGroupCurrentUserLeaving,
            body: "group_you_leaving".localized(),
            timestampMs: SnodeAPI.currentOffsetTimestampMs(using: dependencies)
        ).inserted(db)
        
        dependencies[singleton: .jobRunner].upsert(
            db,
            job: Job(
                variant: .groupLeaving,
                threadId: groupPublicKey,
                interactionId: interaction.id,
                details: GroupLeavingJob.Details(
                    behaviour: .leave
                )
            ),
            canStartJob: true,
            using: dependencies
        )
    }
}
