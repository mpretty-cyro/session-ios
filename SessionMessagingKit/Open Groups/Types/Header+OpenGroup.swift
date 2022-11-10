// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension HTTP.Header {
    static let sogsPubKey: HTTP.Header = "X-SOGS-Pubkey"
    static let sogsNonce: HTTP.Header = "X-SOGS-Nonce"
    static let sogsTimestamp: HTTP.Header = "X-SOGS-Timestamp"
    static let sogsSignature: HTTP.Header = "X-SOGS-Signature"
}
