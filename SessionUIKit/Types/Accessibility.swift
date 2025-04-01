// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct Accessibility: Sendable, Hashable, Equatable {
    public let identifier: String?
    public let label: String?
    
    public init(
        identifier: String? = nil,
        label: String? = nil
    ) {
        self.identifier = identifier
        self.label = label
    }
}
