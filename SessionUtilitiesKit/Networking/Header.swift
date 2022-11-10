// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension HTTP {
    typealias Header = String
}

public extension HTTP.Header {
    static let authorization: HTTP.Header = "Authorization"
    static let contentType: HTTP.Header = "Content-Type"
    static let contentDisposition: HTTP.Header = "Content-Disposition"
}

// MARK: - Convenience

public extension Dictionary where Key == HTTP.Header, Value == String {
    func toHTTPHeaders() -> [String: String] {
        return self.reduce(into: [:]) { result, next in result[next.key] = next.value }
    }
}
