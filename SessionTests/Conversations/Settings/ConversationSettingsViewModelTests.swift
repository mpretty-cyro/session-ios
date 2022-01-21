// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import XCTest
import Nimble

@testable import Session

class ConversationSettingsViewModelTests: XCTestCase {
    var viewModel: ConversationSettingsViewModel!
    
    // MARK: - Configuration

    override func setUpWithError() throws {
        // TODO: Need to mock TSThread and YapDatabaseConnection
//        viewModel = ConversationSettingsViewModel(thread: <#T##TSThread#>, uiDatabaseConnection: <#T##YapDatabaseConnection#>, didTriggerSearch: <#T##() -> ()#>)
    }
    
    override func tearDownWithError() throws {
        viewModel = nil
    }
    
    // MARK: - Basic Tests
}
