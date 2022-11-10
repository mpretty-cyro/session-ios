// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionUtilitiesKit

extension MessageReceiver {
    public static func handleGroupInvite(_ db: Database, message: GroupInviteMessage) throws {
        guard
            let sender: String = message.sender,
            let sentTimestamp: UInt64 = message.sentTimestamp
        else { return }
        
        let groupPublicKey: String = message.publicKey.toHexString()
        
        // Create the group
        let groupAlreadyExisted: Bool = ((try? SessionThread.exists(db, id: groupPublicKey)) ?? false)
        let thread: SessionThread = try SessionThread
            .fetchOrCreate(db, id: groupPublicKey, variant: .closedGroup)
            .with(shouldBeVisible: true)
            .saved(db)
        let closedGroup: ClosedGroup = try ClosedGroup(
            threadId: groupPublicKey,
            name: message.name,
            formationTimestamp: (TimeInterval(sentTimestamp) / 1000),
            // If the sender of this group invitation is already approved then auto-approve the
            // newly created closed group
            isApproved: (try? Contact
                .filter(id: sender)
                .select(.isApproved)
                .asRequest(of: Bool.self)
                .fetchOne(db))
                .defaulting(to: false)
        ).saved(db)
    }
    
    public static func handleGroupPromote(_ db: Database, message: GroupPromoteMessage) throws {
        guard
            let sender: String = message.sender,
            let groupPublicKey: String = message.groupPublicKey,
            sender == getUserHexEncodedPublicKey(db)
        else { return }
        
        // TODO: Decrypt the 'encryptedPrivateKey' value
        let privateKey: Data = message.encryptedPrivateKey
        
        // Remove the memberPrivateKey (since it won't be used anymore) and store the
        // privateKey for future actions
        try ClosedGroup
            .filter(id: groupPublicKey)
            .updateAll(
                db,
                ClosedGroup.Columns.memberPrivateKey.set(to: nil),
                ClosedGroup.Columns.privateKey.set(to: privateKey)
            )
        
        // Sync the configuration so other devices update correctly
        try MessageSender
            .syncConfiguration(db, forceSyncNow: true)
            .retainUntilComplete()
    }
    
    public static func handleGroupMemberLeft(_ db: Database, message: GroupMemberLeftMessage) throws {
        let userPubilicKey: String = getUserHexEncodedPublicKey(db)
        
        // Ignore this message if the current user is the sender (it'll get synced via user config)
        guard
            let sender: String = message.sender,
            sender != userPubilicKey,
            let groupPublicKey: String = message.groupPublicKey
        else { return }
        
        // Create an info message within the group
        _ = try Interaction(
            serverHash: message.serverHash,
            threadId: groupPublicKey,
            authorId: sender,
            variant: .infoClosedGroupUpdated,
            body: GroupMemberLeftMessage.infoMessage(
                db,
                userPublicKey: userPubilicKey,
                sender: sender
            ),
            timestampMs: (
                message.sentTimestamp.map { Int64($0) } ??
                Int64(floor(Date().timeIntervalSince1970 * 1000))
            )
        ).inserted(db)
        
        // Only need to do the remaining work if the current user is an admin within the group
        guard
            try GroupMember
                .filter(GroupMember.Columns.profileId == userPubilicKey)
                .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                .isNotEmpty(db)
        else { return }
    }
    
    public static func handleGroupDelete(_ db: Database, message: GroupDeleteMessage) throws {
        let threadId: String = message.publicKey.toHexString()
        
        // Flag the group as deleted
        try ClosedGroup
            .filter(id: threadId)
            .updateAll(db, ClosedGroup.Columns.isDeleted.set(to: true))
        
        // Remove the existing group content
        _ = try GroupMember
            .filter(GroupMember.Columns.groupId == threadId)
            .deleteAll(db)
        
        _ = try Interaction
            .filter(Interaction.Columns.threadId == threadId)
            .deleteAll(db)
        
        // Unsubscribe from the group
        try ClosedGroup.removeKeysAndUnsubscribe(db, threadId: threadId)
        
        // Send a message into the group to indicate it was been deleted
        _ = try Interaction(
            serverHash: message.serverHash,
            threadId: threadId,
            authorId: getUserHexEncodedPublicKey(db),
            variant: .infoClosedGroupUpdated,
            body: "GROUP_DELETED_MESSAGE".localized(),
            timestampMs: (
                message.sentTimestamp.map { Int64($0) } ??
                Int64(floor(Date().timeIntervalSince1970 * 1000))
            )
        ).inserted(db)
        
        // Sync the configuration so other devices update correctly
        try MessageSender
            .syncConfiguration(db, forceSyncNow: true)
            .retainUntilComplete()
    }
}
