// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension HTTP.QueryParam {
    static let publicKey: HTTP.QueryParam = "public_key"
    static let fromServerId: HTTP.QueryParam = "from_server_id"
    
    static let required: HTTP.QueryParam = "required"
    
    /// For messages - number between 1 and 256 (default is 100)
    static let limit: HTTP.QueryParam = "limit"
    
    /// For file server session version check
    static let platform: HTTP.QueryParam = "platform"
    
    /// String indicating the types of updates that the client supports
    static let updateTypes: HTTP.QueryParam = "t"
    static let reactors: HTTP.QueryParam = "reactors"
}
