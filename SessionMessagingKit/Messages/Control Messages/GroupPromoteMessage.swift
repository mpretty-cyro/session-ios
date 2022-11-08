// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupPromoteMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case publicKey
        case encryptedPrivateKey
    }
    
    public var publicKey: Data
    public var encryptedPrivateKey: Data
    
    public override var isSelfSendValid: Bool { true }

    // MARK: - Initialization
    
    internal init(publicKey: Data, encryptedPrivateKey: Data) {
        self.publicKey = publicKey
        self.encryptedPrivateKey = encryptedPrivateKey
        
        super.init()
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        publicKey = try container.decode(Data.self, forKey: .publicKey)
        encryptedPrivateKey = try container.decode(Data.self, forKey: .encryptedPrivateKey)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(publicKey, forKey: .publicKey)
        try container.encode(encryptedPrivateKey, forKey: .encryptedPrivateKey)
    }
    
    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupPromoteMessage? {
        guard let promoteProto = proto.dataMessage?.groupMessage?.promoteMessage else { return nil }
        
        return GroupPromoteMessage(
            publicKey: promoteProto.publicKey,
            encryptedPrivateKey: promoteProto.encryptedPrivateKey
        )
    }

    public override func toProto(_ db: Database) -> SNProtoContent? {
        let promoteProto = SNProtoGroupPromoteMessage.builder(
            publicKey: publicKey,
            encryptedPrivateKey: encryptedPrivateKey
        )
        let groupMessageProto = SNProtoGroupMessage.builder()
        let dataMessageProto = SNProtoDataMessage.builder()
        let contentProto = SNProtoContent.builder()
        
        do {
            groupMessageProto.setPromoteMessage(try promoteProto.build())
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
        GroupPromoteMessage(
            publicKey: \(publicKey),
            encryptedPrivateKey: [REDACTED]
        )
        """
    }
}
