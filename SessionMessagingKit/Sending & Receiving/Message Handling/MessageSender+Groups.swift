// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Sodium
import SessionUtilitiesKit
import SessionSnodeKit

extension MessageSender {
    private typealias PreparedGroupData = (
        groupSessionId: SessionId,
        groupState: [ConfigDump.Variant: SessionUtil.Config],
        thread: SessionThread,
        group: ClosedGroup,
        members: [GroupMember],
        preparedNotificationsSubscription: HTTP.PreparedRequest<PushNotificationAPI.SubscribeResponse>?
    )
    
    public static func createGroup(
        name: String,
        displayPicture: SignalAttachment?,
        members: [(String, Profile?)],
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<SessionThread, Error> {
        return Just(())
            .setFailureType(to: Error.self)
            .flatMap { _ -> AnyPublisher<(url: String, filename: String, encryptionKey: Data)?, Error> in
                guard let displayPicture: SignalAttachment = displayPicture else {
                    return Just(nil)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                // TODO: Upload group image first
                return Just(nil)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            .flatMap { displayPictureInfo -> AnyPublisher<PreparedGroupData, Error> in
                dependencies[singleton: .storage].writePublisher(using: dependencies) { db -> PreparedGroupData in
                    // Create and cache the libSession entries
                    let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                    let currentUserProfile: Profile = Profile.fetchOrCreateCurrentUser(db, using: dependencies)
                    let createdInfo: SessionUtil.CreatedGroupInfo = try SessionUtil.createGroup(
                        db,
                        name: name,
                        displayPictureUrl: displayPictureInfo?.url,
                        displayPictureFilename: displayPictureInfo?.filename,
                        displayPictureEncryptionKey: displayPictureInfo?.encryptionKey,
                        members: members,
                        admins: [(userSessionId.hexString, currentUserProfile)],
                        using: dependencies
                    )
                    
                    // Save the relevant objects to the database
                    let thread: SessionThread = try SessionThread
                        .fetchOrCreate(
                            db,
                            id: createdInfo.group.id,
                            variant: .group,
                            shouldBeVisible: true,
                            using: dependencies
                        )
                    try createdInfo.group.insert(db)
                    try createdInfo.members.forEach { try $0.insert(db) }
                    
                    // Prepare the notification subscription
                    let preparedNotificationSubscription = try? PushNotificationAPI
                        .preparedSubscribe(
                            db,
                            sessionId: createdInfo.groupSessionId,
                            using: dependencies
                        )
                    
                    return (
                        createdInfo.groupSessionId,
                        createdInfo.groupState,
                        thread,
                        createdInfo.group,
                        createdInfo.members,
                        preparedNotificationSubscription
                    )
                }
            }
            .flatMap { preparedGroupData -> AnyPublisher<PreparedGroupData, Error> in
                ConfigurationSyncJob
                    .run(sessionIdHexString: preparedGroupData.groupSessionId.hexString, using: dependencies)
                    .flatMap { _ in
                        dependencies[singleton: .storage].writePublisher(using: dependencies) { db in
                            // Save the successfully created group and add to the user config
                            try SessionUtil.saveCreatedGroup(
                                db,
                                group: preparedGroupData.group,
                                groupState: preparedGroupData.groupState,
                                using: dependencies
                            )
                            
                            return preparedGroupData
                        }
                    }
                    .handleEvents(
                        receiveCompletion: { result in
                            switch result {
                                case .finished: break
                                case .failure:
                                    // Remove the config and database states
                                    dependencies[singleton: .storage].writeAsync(using: dependencies) { db in
                                        SessionUtil.removeGroupStateIfNeeded(
                                            db,
                                            groupSessionId: preparedGroupData.groupSessionId,
                                            using: dependencies
                                        )
                                        
                                        _ = try? preparedGroupData.thread.delete(db)
                                        _ = try? preparedGroupData.group.delete(db)
                                        try? preparedGroupData.members.forEach { try $0.delete(db) }
                                    }
                            }
                        }
                    )
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveOutput: { _, _, thread, _, members, preparedNotificationSubscription in
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
                                    let memberAuthInfo: Authentication.Info = try? SessionUtil.generateAuthData(
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
            .map { _, _, thread, _, _, _ in thread }
            .eraseToAnyPublisher()
    }
    
    public static func updateGroup(
        groupSessionId: String,
        name: String,
        displayPictureUpdate: DisplayPictureManager.Update,
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
                
                // Update name if needed
                if name != closedGroup.name {
                    // Update the group
                    _ = try ClosedGroup
                        .filter(id: sessionId.hexString)
                        .updateAllAndConfig(db, ClosedGroup.Columns.name.set(to: name), using: dependencies)

                    // Update libSession
                    try SessionUtil.update(
                        db,
                        groupSessionId: sessionId,
                        name: name,
                        using: dependencies
                    )
                    
                    // Add a record of the change to the conversation
                    _ = try Interaction(
                        threadId: groupSessionId,
                        authorId: userSessionId.hexString,
                        variant: .infoGroupUpdated,
                        body: ClosedGroup.MessageInfo
                            .updatedName(name)
                            .infoString,
                        timestampMs: changeTimestampMs
                    ).inserted(db)
                    
                    // Schedule the control message to be sent to the group
                    try MessageSender.send(
                        db,
                        message: GroupUpdateInfoChangeMessage(
                            changeType: .name,
                            updatedName: name,
                            sentTimestamp: UInt64(changeTimestampMs)
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
    
    public static func addGroupMembers(
        groupSessionId: String,
        members: [(id: String, profile: Profile?)],
        allowAccessToHistoricMessages: Bool,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard let sessionId: SessionId = try? SessionId(from: groupSessionId), sessionId.prefix == .group else {
            // FIXME: Fail with `MessageSenderError.invalidClosedGroupUpdate` once support for legacy groups is removed
            let groupData: (name: String?, memberIds: Set<String>)? = dependencies[singleton: .storage].read(using: dependencies) { db in
                let name: String? = try ClosedGroup
                    .filter(id: groupSessionId)
                    .select(.name)
                    .asRequest(of: String.self)
                    .fetchOne(db)
                let memberIds: Set<String> = try GroupMember
                    .filter(GroupMember.Columns.groupId == groupSessionId)
                    .select(GroupMember.Columns.profileId)
                    .asRequest(of: String.self)
                    .fetchSet(db)
                
                return (name, memberIds)
            }
            
            guard let name: String = groupData?.name, let memberIds: Set<String> = groupData?.memberIds else {
                return Fail(error: MessageSenderError.invalidClosedGroupUpdate).eraseToAnyPublisher()
            }
            
            return MessageSender.update(
                legacyGroupSessionId: groupSessionId,
                with: memberIds.inserting(contentsOf: members.map { $0.0 }.asSet()),
                name: name,
                using: dependencies
            )
        }
        
        return dependencies[singleton: .storage]
            .writePublisher { db in
                guard
                    let groupIdentityPrivateKey: Data = try? ClosedGroup
                        .filter(id: sessionId.hexString)
                        .select(.groupIdentityPrivateKey)
                        .asRequest(of: Data.self)
                        .fetchOne(db)
                else { throw MessageSenderError.invalidClosedGroupUpdate }
                
                let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                let changeTimestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs(using: dependencies)
                
                /// Add the members to the `GROUP_MEMBERS` config
                try SessionUtil.addMembers(
                    db,
                    groupSessionId: sessionId,
                    members: members,
                    using: dependencies
                )
                
                /// We need to update the group keys when adding new members, this should be done by either supplementing the
                /// current keys (which allows access to existing messages) or by doing a full `rekey` which means new messages
                /// will be encrypted using new keys
                ///
                /// **Note:** This **MUST** be called _after_ the new members have been added to the group, otherwise the
                /// keys may not be generated correctly for the newly added members
                if allowAccessToHistoricMessages {
                
                /// Generate the data needed to send the new members invitations to the group
                let memberJobData: [(id: String, profile: Profile?, jobDetails: GroupInviteMemberJob.Details)] = try members
                    .map { id, profile in
                        // Generate authData for the newly added member
                        let memberAuthInfo: Authentication.Info = try SessionUtil.generateAuthData(
                            groupSessionId: sessionId,
                            memberId: id,
                            using: dependencies
                        )
                        let inviteDetails: GroupInviteMemberJob.Details = try GroupInviteMemberJob.Details(
                            memberSessionIdHexString: id,
                            authInfo: memberAuthInfo
                        )
                        
                        return (id, profile, inviteDetails)
                    }
                
                /// Unrevoke the newly added members just in case they had previously gotten their access to the group
                /// revoked (fire-and-forget this request, we don't want it to be blocking - if the invited user still can't access
                /// the group the admin can resend their invitation which will also attempt to unrevoke their subaccount)
                memberJobData
                    .chunked(by: HTTP.BatchRequest.childRequestLimit)
                    .forEach { memberJobDataChunk in
                        try? SnodeAPI
                            .preparedBatch(
                                db,
                                requests: try memberJobDataChunk.map { id, _, jobDetails in
                                    try SnodeAPI.preparedUnrevokeSubaccount(
                                        subaccountToUnrevoke: jobDetails.memberAuthData.toHexString(),
                                        authMethod: Authentication.groupAdmin(
                                            groupSessionId: sessionId,
                                            ed25519SecretKey: Array(groupIdentityPrivateKey)
                                        ),
                                        using: dependencies
                                    )
                                },
                                requireAllBatchResponses: false,
                                associatedWith: sessionId.hexString,
                                using: dependencies
                            )
                            .send(using: dependencies)
                            .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
                            .sinkUntilComplete()
                    }
                
                /// Make the required changes for each added member
                try memberJobData.forEach { id, profile, inviteJobDetails in
                    /// Add the member to the database
                    try GroupMember(
                        groupId: sessionId.hexString,
                        profileId: id,
                        role: .standard,
                        roleStatus: .pending,
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
                    variant: .infoGroupUpdated,
                    body: ClosedGroup.MessageInfo
                        .addedUsers(
                            names: members.map { id, profile in
                                profile?.displayName(for: .group) ??
                                Profile.truncated(id: id, truncating: .middle)
                            }
                        )
                        .infoString,
                    timestampMs: changeTimestampMs
                ).inserted(db)
                
                /// Schedule the control message to be sent to the group
                try MessageSender.send(
                    db,
                    message: GroupUpdateMemberChangeMessage(
                        changeType: .added,
                        memberPublicKeys: members.map { Data(hex: $0.id) },
                        sentTimestamp: UInt64(changeTimestampMs)
                    ),
                    interactionId: nil,
                    threadId: sessionId.hexString,
                    threadVariant: .group,
                    using: dependencies
                )
            }
    }
    
    public static func removeGroupMembers(
        groupSessionId: String,
        memberIds: Set<String>,
        sendMemberChangedMessage: Bool,
        changeTimestampMs: Int64? = nil,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        let targetChangeTimestampMs: Int64 = (
            changeTimestampMs ??
            SnodeAPI.currentOffsetTimestampMs(using: dependencies)
        )
        
        guard let sessionId: SessionId = try? SessionId(from: groupSessionId), sessionId.prefix == .group else {
            // FIXME: Fail with `MessageSenderError.invalidClosedGroupUpdate` once support for legacy groups is removed
            let groupData: (name: String?, memberIds: Set<String>)? = dependencies[singleton: .storage].read(using: dependencies) { db in
                let name: String? = try ClosedGroup
                    .filter(id: groupSessionId)
                    .select(.name)
                    .asRequest(of: String.self)
                    .fetchOne(db)
                let memberIds: Set<String> = try GroupMember
                    .filter(GroupMember.Columns.groupId == groupSessionId)
                    .select(GroupMember.Columns.profileId)
                    .asRequest(of: String.self)
                    .fetchSet(db)
                
                return (name, memberIds)
            }
            
            guard let name: String = groupData?.name, let allMemberIds: Set<String> = groupData?.memberIds else {
                return Fail(error: MessageSenderError.invalidClosedGroupUpdate).eraseToAnyPublisher()
            }
            
            return MessageSender.update(
                legacyGroupSessionId: groupSessionId,
                with: allMemberIds.removing(contentsOf: memberIds),
                name: name,
                using: dependencies
            )
        }
        
        return dependencies[singleton: .storage]
            .writePublisher { db in
                guard
                    let groupIdentityPrivateKey: Data = try? ClosedGroup
                        .filter(id: sessionId.hexString)
                        .select(.groupIdentityPrivateKey)
                        .asRequest(of: Data.self)
                        .fetchOne(db)
                else { throw MessageSenderError.invalidClosedGroupUpdate }
                
                /// Remove the members from the `GROUP_MEMBERS` config
                try SessionUtil.removeMembers(
                    db,
                    groupSessionId: sessionId,
                    memberIds: memberIds,
                    using: dependencies
                )
                
                /// We need to update the group keys when removing members so they can't decrypt any more group messages
                ///
                /// **Note:** This **MUST** be called _after_ the members have been removed, otherwise the removed members
                /// may still be able to access the keys
                try SessionUtil.rekey(
                    db,
                    groupSessionId: sessionId,
                    using: dependencies
                )
                            .sinkUntilComplete()
                
                /// Revoke the members authData from the group so the server rejects API calls from the ex-members (fire-and-forget
                /// this request, we don't want it to be blocking)
                memberIds
                    .chunked(by: HTTP.BatchRequest.childRequestLimit)
                    .forEach { memberIdsChunk in
                        try? SnodeAPI
                            .preparedBatch(
                                db,
                                requests: memberIdsChunk.compactMap { id -> HTTP.PreparedRequest<Void>? in
                                    // Generate authData for the removed member
                                    guard
                                        let memberAuthInfo: Authentication.Info = try? SessionUtil.generateAuthData(
                                            groupSessionId: sessionId,
                                            memberId: id,
                                            using: dependencies
                                        ),
                                        case .groupMember(_, let memberAuthData) = memberAuthInfo
                                    else { return nil }
                                    
                                    return try? SnodeAPI.preparedRevokeSubaccount(
                                        subaccountToRevoke: memberAuthData.toHexString(),
                                        authMethod: Authentication.groupAdmin(
                                            groupSessionId: sessionId,
                                            ed25519SecretKey: Array(groupIdentityPrivateKey)
                                        ),
                                        using: dependencies
                                    )
                                },
                                requireAllBatchResponses: false,
                                associatedWith: sessionId.hexString,
                                using: dependencies
                            )
                            .send(using: dependencies)
                            .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
                    }
                
                /// Remove the members from the database
                try GroupMember
                    .filter(
                        GroupMember.Columns.groupId == sessionId.hexString &&
                        memberIds.contains(GroupMember.Columns.profileId)
                    )
                    .deleteAll(db)
                
                /// Schedule a `GroupUpdateDeleteMessage` to each of the members (instruct their clients to delete the group content)
                try memberIds.forEach { memberId in
                    try MessageSender.send(
                        db,
                        message: try GroupUpdateDeleteMessage(
                            recipientSessionIdHexString: memberId,
                            groupSessionId: sessionId,
                            sentTimestamp: UInt64(targetChangeTimestampMs),
                            authMethod: Authentication.groupAdmin(
                                groupSessionId: sessionId,
                                ed25519SecretKey: Array(groupIdentityPrivateKey)
                            ),
                            using: dependencies
                        ),
                        interactionId: nil,
                        threadId: memberId,
                        threadVariant: .contact,
                        using: dependencies
                    )
                }
                
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
                        variant: .infoGroupUpdated,
                        body: ClosedGroup.MessageInfo
                            .removedUsers(
                                names: memberIds.map { id in
                                    removedMemberProfiles[id]?.displayName(for: .group) ??
                                    Profile.truncated(id: id, truncating: .middle)
                                }
                            )
                            .infoString,
                        timestampMs: targetChangeTimestampMs
                    ).inserted(db)
                    
                    /// Schedule the control message to be sent to the group
                    try MessageSender.send(
                        db,
                        message: GroupUpdateMemberChangeMessage(
                            changeType: .removed,
                            memberPublicKeys: memberIds.map { Data(hex: $0) },
                            sentTimestamp: UInt64(targetChangeTimestampMs)
                        ),
                        interactionId: nil,
                        threadId: sessionId.hexString,
                        threadVariant: .group,
                        using: dependencies
                    )
                }
            }
    }
    
    public static func promoteGroupMembers(
        groupSessionId: SessionId,
        memberIds: Set<String>,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        return dependencies[singleton: .storage]
            .writePublisher { db in
                // Update the libSession status for each member and schedule a job to send
                // the promotion message
                try memberIds.forEach { memberId in
                    try SessionUtil
                        .updateMemberStatus(
                            db,
                            groupSessionId: groupSessionId,
                            memberId: memberId,
                            role: .admin,
                            status: .pending,
                            using: dependencies
                        )
                    
                    dependencies[singleton: .jobRunner].add(
                        db,
                        job: Job(
                            variant: .groupPromoteMember,
                            details: GroupPromoteMemberJob.Details(
                                memberSessionIdHexString: memberId
                            )
                        ),
                        canStartJob: true,
                        using: dependencies
                    )
                }
            }
    }
}
