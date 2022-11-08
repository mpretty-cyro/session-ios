// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupMemberLeftMessage: ControlMessage {
    public override var isSelfSendValid: Bool { true }
    
    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupMemberLeftMessage? {
        guard proto.dataMessage?.groupMessage?.memberLeftMessage != nil else { return nil }
        
        return GroupMemberLeftMessage()
    }

    public override func toProto(_ db: Database) -> SNProtoContent? {
        let memberLeftProto = SNProtoGroupMemberLeftMessage.builder()
        let groupMessageProto = SNProtoGroupMessage.builder()
        let dataMessageProto = SNProtoDataMessage.builder()
        let contentProto = SNProtoContent.builder()
        
        do {
            groupMessageProto.setMemberLeftMessage(try memberLeftProto.build())
            dataMessageProto.setGroupMessage(try groupMessageProto.build())
            contentProto.setDataMessage(try dataMessageProto.build())
            return try contentProto.build()
        } catch {
            SNLog("Couldn't construct groupMemberLeft proto from: \(self).")
            return nil
        }
    }

    // MARK: - Description
    
    public var description: String {
        """
        GroupMemberLeft()
        """
    }
}
