// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum HTTPMethod: String, Codable {
    case get = "GET"
    case put = "PUT"
    case post = "POST"
    case delete = "DELETE"
}
