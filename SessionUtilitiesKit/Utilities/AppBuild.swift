// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum AppBuild {
    case debug
    case testFlight
    case appStore
    
    public static let current: AppBuild = {
        #if DEBUG
        return .debug
        #else
        return (Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ?
            .testFlight :
            .appStore
        )
        #endif
    }()
}
