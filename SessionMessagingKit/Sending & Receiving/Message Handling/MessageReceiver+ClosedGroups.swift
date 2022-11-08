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
    }
    
    public static func handleGroupMemberLeft(_ db: Database, message: GroupMemberLeftMessage) throws {
    }
    
    public static func handleGroupDelete(_ db: Database, message: GroupDeleteMessage) throws {
    }
}
