// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension SnodeAPI {
    enum Namespace: Int, Codable {
        case `default` = 0
        case config = 5
        
        case legacyClosedGroup = -10
        
        // MARK: Variables
        
        var requiresAuthentication: Bool {
            switch self {
                case .legacyClosedGroup: return false
                default: return true
            }
        }
        
        var verificationString: String {
            switch self {
                case .`default`: return ""
                default: return "\(self.rawValue)"
            }
        }
    }
}
