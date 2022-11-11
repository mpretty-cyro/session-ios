// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension SnodeAPI {
    enum Endpoint: String {
        case getSwarm = "get_snodes_for_pubkey"
        case getMessages = "retrieve"
        case sendMessage = "store"
        case deleteMessage = "delete"
        case oxenDaemonRPCCall = "oxend_request"
        case getInfo = "info"
        case clearAllData = "delete_all"
        case expire = "expire"
        case batch = "batch"
        case sequence = "sequence"
        
        // oxenDaemonRPCCall proxied calls
        
        case daemonOnsResolve = "ons_resolve"
        case daemonGetServiceNodes = "get_service_nodes"
    }
}
