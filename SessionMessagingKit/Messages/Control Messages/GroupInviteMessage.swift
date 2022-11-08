// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupInviteMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case publicKey
        case name
        case memberPrivateKey
    }
    
    public var publicKey: Data
    public var name: String
    public var memberPrivateKey: Data
    
    public override var isSelfSendValid: Bool { true }

    // MARK: - Initialization
    
    internal init(publicKey: Data, name: String, memberPrivateKey: Data) {
        self.publicKey = publicKey
        self.name = name
        self.memberPrivateKey = memberPrivateKey
        
        super.init()
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        publicKey = try container.decode(Data.self, forKey: .publicKey)
        name = try container.decode(String.self, forKey: .name)
        memberPrivateKey = try container.decode(Data.self, forKey: .memberPrivateKey)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(publicKey, forKey: .publicKey)
        try container.encode(name, forKey: .name)
        try container.encode(memberPrivateKey, forKey: .memberPrivateKey)
    }
    
    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupInviteMessage? {
        guard let inviteProto = proto.dataMessage?.groupMessage?.inviteMessage else { return nil }
        
        return GroupInviteMessage(
            publicKey: inviteProto.publicKey,
            name: inviteProto.name,
            memberPrivateKey: inviteProto.memberPrivateKey
        )
    }

    public override func toProto(_ db: Database) -> SNProtoContent? {
        let inviteProto = SNProtoGroupInviteMessage.builder(
            publicKey: publicKey,
            name: name,
            memberPrivateKey: memberPrivateKey
        )
        let groupMessageProto = SNProtoGroupMessage.builder()
        let dataMessageProto = SNProtoDataMessage.builder()
        let contentProto = SNProtoContent.builder()
        
        do {
            groupMessageProto.setInviteMessage(try inviteProto.build())
            dataMessageProto.setGroupMessage(try groupMessageProto.build())
            contentProto.setDataMessage(try dataMessageProto.build())
            return try contentProto.build()
        } catch {
            SNLog("Couldn't construct inviteMessage proto from: \(self).")
            return nil
        }
    }

    // MARK: - Description
    
    public var description: String {
        """
        GroupInviteMessage(
            publicKey: \(publicKey),
            name: \(name),
            memberPrivateKey: [REDACTED]
        )
        """
    }
}
