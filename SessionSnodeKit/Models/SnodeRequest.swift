// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public struct SnodeRequest<T: Encodable>: Encodable {
    private enum CodingKeys: String, CodingKey {
        case method
        case params
    }
    
    internal let endpoint: SnodeAPI.Endpoint
    internal let params: T
    
    // MARK: - Initialization
    
    public init(
        endpoint: SnodeAPI.Endpoint,
        body: T
    ) {
        self.endpoint = endpoint
        self.params = body
    }
    
    // MARK: - Codable
    
    public func encode(to encoder: Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(endpoint.rawValue, forKey: .method)
        try container.encode(params, forKey: .params)
    }
    
    // MARK: - Functions
    // TODO: Is this needed?
    
    public func generateBody() throws -> Data {
        return try JSONEncoder().encode(self)
    }
}
