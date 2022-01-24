// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import XCTest
import Nimble

@testable import Session

class ListenerTests: XCTestCase {
    var listener: Listener!
    
    // MARK: - Basic Tests

    func testItCallsTheCallbackWhenStopIsCalled() throws {
        var didTriggerCallback: Bool = false
        
        listener = Listener {
            didTriggerCallback = true
        }
        
        listener.stop()
        
        expect(didTriggerCallback).to(beTrue())
    }
}
