// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension SnodeAPI {
    enum Namespace: Int, Codable {
        case `default` = 0
        case config = 5
        
        case legacyClosedGroup = -10
        
        // MARK: Variables
        
        var requiresReadAuthentication: Bool {
            switch self {
                case .legacyClosedGroup: return false
                default: return true
            }
        }
        
        var requiresWriteAuthentication: Bool {
            // Not in use until we can batch delete and store config messages
            return false
        }
        
        var verificationString: String {
            switch self {
                case .`default`: return ""
                default: return "\(self.rawValue)"
            }
        }
    }
}
