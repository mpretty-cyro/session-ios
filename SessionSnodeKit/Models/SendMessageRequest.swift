// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension SnodeAPI {
    public struct SendMessageRequest: Encodable {
        enum CodingKeys: String, CodingKey {
            case namespace
            case timestamp = "sig_timestamp"
            case pubKeyEd25519 = "pubkey_ed25519"
            case signature
        }
        
        let message: SnodeMessage
        let namespace: SnodeAPI.Namespace
        let timestamp: UInt64?
        let pubKeyEd25519: String?
        let signature: String?
        
        // MARK: - Init
        
        public init(
            message: SnodeMessage,
            namespace: SnodeAPI.Namespace,
            timestamp: UInt64? = nil,
            pubKeyEd25519: String? = nil,
            signature: String? = nil
        ) {
            self.message = message
            self.namespace = namespace
            self.timestamp = timestamp
            self.pubKeyEd25519 = pubKeyEd25519
            self.signature = signature
        }
        
        // MARK: - Coding
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try message.encode(to: encoder)
            try container.encode(namespace, forKey: .namespace)
            try container.encodeIfPresent(timestamp, forKey: .timestamp)
            try container.encodeIfPresent(pubKeyEd25519, forKey: .pubKeyEd25519)
            try container.encodeIfPresent(signature, forKey: .signature)
        }
    }
}
