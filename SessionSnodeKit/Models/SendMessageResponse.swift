// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public class SendMessagesResponse: SnodeResponse {
    private enum CodingKeys: String, CodingKey {
        case difficulty
        case hash
        case swarm
    }
    
    public class SwarmItem: Codable {
        private enum CodingKeys: String, CodingKey {
            case already
            case hash
            case signature
        }
        
        public let already: Bool?
        public let hash: String
        public let signature: String
    }
    
    public let difficulty: Int64
    public let hash: String
    public let swarm: [String: SwarmItem]
    
    // MARK: - Initialization
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        difficulty = try container.decode(Int64.self, forKey: .difficulty)
        hash = try container.decode(String.self, forKey: .hash)
        swarm = try container.decode([String: SwarmItem].self, forKey: .swarm)
        
        try super.init(from: decoder)
    }
}
