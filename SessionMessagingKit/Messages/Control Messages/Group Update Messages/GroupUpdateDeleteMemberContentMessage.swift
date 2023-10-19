// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class GroupUpdateDeleteMemberContentMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case memberPublicKeys
        case adminSignature
    }
    
    public var memberPublicKeys: [Data]
    public var adminSignature: Authentication.Signature
    
    override public var processWithBlockedSender: Bool { true }
    
    // MARK: - Initialization
    
    public init(
        memberPublicKeys: [Data],
        sentTimestamp: UInt64,
        authMethod: AuthenticationMethod,
        using dependencies: Dependencies
    ) throws {
        self.memberPublicKeys = memberPublicKeys
        self.adminSignature = try authMethod.generateSignature(
            with: GroupUpdateDeleteMemberContentMessage.generateVerificationBytes(
                memberPublicKeys: memberPublicKeys,
                timestampMs: sentTimestamp
            ),
            using: dependencies
        )
        
        super.init(
            sentTimestamp: sentTimestamp
        )
    }
    
    private init(
        memberPublicKeys: [Data],
        adminSignature: Authentication.Signature
    ) {
        self.memberPublicKeys = memberPublicKeys
        self.adminSignature = adminSignature
        
        super.init()
    }
    
    // MARK: - Signature Generation
    
    public static func generateVerificationBytes(
        memberPublicKeys: [Data],
        timestampMs: UInt64
    ) -> [UInt8] {
        /// Ed25519 signature of `("DELETE_CONTENT" || timestamp || sessionId[0] || ... || sessionId[N])`
        return "DELETE_CONTENT".bytes
            .appending(contentsOf: "\(timestampMs)".data(using: .ascii)?.bytes)
            .appending(contentsOf: Array(memberPublicKeys.joined()))
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        memberPublicKeys = try container.decode([Data].self, forKey: .memberPublicKeys)
        adminSignature = Authentication.Signature.standard(
            signature: try container.decode([UInt8].self, forKey: .adminSignature)
        )
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(memberPublicKeys, forKey: .memberPublicKeys)
        
        switch adminSignature {
            case .standard(let signature): try container.encode(signature, forKey: .adminSignature)
            case .subaccount: throw MessageSenderError.signingFailed
        }
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> GroupUpdateDeleteMemberContentMessage? {
        guard let groupDeleteMemberContentMessage = proto.dataMessage?.groupUpdateMessage?.deleteMemberContent else { return nil }
        
        return GroupUpdateDeleteMemberContentMessage(
            memberPublicKeys: groupDeleteMemberContentMessage.memberPublicKeys,
            adminSignature: Authentication.Signature.standard(
                signature: Array(groupDeleteMemberContentMessage.adminSignature)
            )
        )
    }

    public override func toProto(_ db: Database, threadId: String) -> SNProtoContent? {
        do {
            let deleteMemberContentMessageBuilder: SNProtoGroupUpdateDeleteMemberContentMessage.SNProtoGroupUpdateDeleteMemberContentMessageBuilder = SNProtoGroupUpdateDeleteMemberContentMessage.builder(
                adminSignature: try {
                    switch adminSignature {
                        case .standard(let signature): return Data(signature)
                        case .subaccount: throw MessageSenderError.signingFailed
                    }
                }()
            )
            deleteMemberContentMessageBuilder.setMemberPublicKeys(memberPublicKeys)
            
            let groupUpdateMessage = SNProtoGroupUpdateMessage.builder()
            groupUpdateMessage.setDeleteMemberContent(try deleteMemberContentMessageBuilder.build())
            
            let dataMessage = SNProtoDataMessage.builder()
            dataMessage.setGroupUpdateMessage(try groupUpdateMessage.build())
            
            let contentProto = SNProtoContent.builder()
            contentProto.setDataMessage(try dataMessage.build())
            return try contentProto.build()
        } catch {
            SNLog("Couldn't construct data extraction notification proto from: \(self).")
            return nil
        }
    }

    // MARK: - Description
    
    public var description: String {
        """
        GroupUpdateDeleteMemberContentMessage(
            memberPublicKeys: \(memberPublicKeys.map { $0.toHexString() }),
            adminSignature: \(adminSignature)
        )
        """
    }
}
