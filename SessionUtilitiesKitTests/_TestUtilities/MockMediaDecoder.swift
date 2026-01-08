// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import ImageIO

@testable import SessionUtilitiesKit

class MockMediaDecoder: Mock<MediaDecoderType>, MediaDecoderType {
    var defaultImageOptions: CFDictionary { mock() }
    
    func defaultThumbnailOptions(maxDimension: CGFloat) -> CFDictionary {
        return mock(args: [maxDimension])
    }
    
    func source(for url: URL) -> CGImageSource? { return mock(args: [url]) }
    func source(for data: Data) -> CGImageSource? { return mock(args: [data]) }
}

extension Mock where T == MediaDecoderType {
    func defaultInitialSetup() async throws {
        let options: CFDictionary = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary
        
        try await self.when { $0.defaultImageOptions }.thenReturn(options)
        try await self.when { $0.defaultThumbnailOptions(maxDimension: .any) }.thenReturn(options)
        
        try await self
            .when { $0.source(for: URL.any) }
            .thenReturn(CGImageSourceCreateWithData(TestConstants.validImageData as CFData, options))
        try await self
            .when { $0.source(for: Data.any) }
            .thenReturn(CGImageSourceCreateWithData(TestConstants.validImageData as CFData, options))
    }
}
