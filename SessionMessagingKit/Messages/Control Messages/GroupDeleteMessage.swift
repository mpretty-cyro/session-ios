// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupDeleteMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case publicKey
        case lastEncryptionKey
    }
    
    public var publicKey: Data
    public var lastEncryptionKey: Data
    
    public override var isSelfSendValid: Bool { true }

    // MARK: - Initialization
    
    internal init(publicKey: Data, lastEncryptionKey: Data) {
        self.publicKey = publicKey
        self.lastEncryptionKey = lastEncryptionKey
        
        super.init()
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        publicKey = try container.decode(Data.self, forKey: .publicKey)
        lastEncryptionKey = try container.decode(Data.self, forKey: .lastEncryptionKey)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(publicKey, forKey: .publicKey)
        try container.encode(lastEncryptionKey, forKey: .lastEncryptionKey)
    }
    
    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupDeleteMessage? {
        guard let promoteProto = proto.dataMessage?.groupMessage?.deleteMessage else { return nil }
        
        return GroupDeleteMessage(
            publicKey: promoteProto.publicKey,
            lastEncryptionKey: promoteProto.lastEncryptionKey
        )
    }

    public override func toProto(_ db: Database) -> SNProtoContent? {
        let deleteProto = SNProtoGroupDeleteMessage.builder(
            publicKey: publicKey,
            lastEncryptionKey: lastEncryptionKey
        )
        let groupMessageProto = SNProtoGroupMessage.builder()
        let dataMessageProto = SNProtoDataMessage.builder()
        let contentProto = SNProtoContent.builder()
        
        do {
            groupMessageProto.setDeleteMessage(try deleteProto.build())
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
        GroupDeleteMessage(
            publicKey: \(publicKey),
            lastEncryptionKey: [REDACTED]
        )
        """
    }
}
