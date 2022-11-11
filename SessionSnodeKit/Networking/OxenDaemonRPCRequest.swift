// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct OxenDaemonRPCRequest<T: Encodable>: Encodable {
    private let endpoint: String
    private let params: T
    
    public init(
        endpoint: SnodeAPI.Endpoint,
        body: T
    ) {
        self.endpoint = endpoint.rawValue
        self.params = body
    }
    
    public func generateBody() throws -> Data {
        return try JSONEncoder().encode(self)
    }
}
