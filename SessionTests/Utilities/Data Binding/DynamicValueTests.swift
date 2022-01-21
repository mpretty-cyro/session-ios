// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import XCTest
import Nimble

@testable import Session

class DynamicValueTests: XCTestCase {
    var dynamicValue: DynamicValue<Int>!
    
    // MARK: - Configuration

    override func setUpWithError() throws {
        dynamicValue = DynamicValue(1)
    }
    
    override func tearDownWithError() throws {
        dynamicValue = nil
    }
    
    // MARK: - Basic Tests

    func testItSetsTheValue() throws {
        expect(self.dynamicValue.value).to(equal(1))
    }
    
    func testItUpdatesTheValue() throws {
        expect(self.dynamicValue.value).to(equal(1))
        dynamicValue.value = 10
        expect(self.dynamicValue.value).to(equal(10))
    }
    
    // MARK: - Callback Tests
    
    func testItTriggersTheCallbackWhenSomethingStartsObserving() throws {
        var didTriggerCallback: Bool = false
        
        dynamicValue.onChange { _ in
            didTriggerCallback = true
        }
        
        expect(didTriggerCallback).to(beTrue())
    }
    
    func testItTriggersTheCallbackWhenChanged() throws {
        var callbackTriggerCount: Int = 0
        
        dynamicValue.onChange { _ in
            callbackTriggerCount += 1
        }
        
        dynamicValue.value = 10
        
        expect(self.dynamicValue.value).to(equal(10))
        expect(callbackTriggerCount).to(equal(2))
    }
    
    func testItDoesNotTriggerTheCallbackAfterTheListenerWasStopped() throws {
        var callbackTriggerCount: Int = 0
        var lastCallbackValue: Int = -1
        
        let listener: Listener = dynamicValue.onChange { value in
            callbackTriggerCount += 1
            lastCallbackValue = value
        }
        
        dynamicValue.value = 5
        
        listener.stop()
        
        dynamicValue.value = 10
        
        expect(self.dynamicValue.value).to(equal(10))
        expect(lastCallbackValue).to(equal(5))
        expect(self.dynamicValue.value).toNot(equal(lastCallbackValue))
        expect(callbackTriggerCount).to(equal(2))   // 2 because it gets an initial callback
    }
    
    // MARK: -- Skip First
    
    func testItDoesNotTriggerTheCallbackWhenSkippingFirstAndNoChangesOccur() throws {
        var callbackTriggerCount: Int = 0
        
        dynamicValue.onChange(skipFirst: true) { _ in
            callbackTriggerCount += 1
        }
        
        expect(callbackTriggerCount).to(equal(0))
    }
    
    // MARK: -- First Only
    
    func testItDoesNotTriggerTheCallbackOnChangeWhenFirstOnlyIsSet() throws {
        var callbackTriggerCount: Int = 0
        
        dynamicValue.onChange(firstOnly: true) { _ in
            callbackTriggerCount += 1
        }
        
        dynamicValue.value = 10
        
        expect(self.dynamicValue.value).to(equal(10))
        expect(callbackTriggerCount).to(equal(1))
    }
    
    // MARK: -- Force to Main Thread
    
    func testItRunsOnTheMainThreadIfSpecified() throws {
        var callbackTriggerCount: Int = 0
        var threads: [Thread] = []
        
        DispatchQueue.global(qos: .background).async {
            self.dynamicValue.onChange(forceToMainThread: true) { _ in
                callbackTriggerCount += 1
                threads.append(Thread.current)
            }
        }
        
        dynamicValue.value = 10
        
        // It'll only trigger once since the observer is added on a background thread
        expect(callbackTriggerCount)
            .toEventually(
                equal(1),
                timeout: .milliseconds(100)
            )
        expect(self.dynamicValue.value)
            .toEventually(
                equal(10),
                timeout: .milliseconds(100)
            )
        expect(threads)
            .toEventually(
                equal([
                    Thread.main
                ]),
                timeout: .milliseconds(100)
            )
    }
    
    func testItDoesNotDispatchAsyncWhenForcingToMainThreadIfCalledFromMainThread() throws {
        // Note: This test is valid because if we did call `DispatchQueue.main.async` the code would
        // run in the next run loop and the 'shouldEqual' would fail since it runs synchronously
        var callbackTriggerCount: Int = 0
        var threads: [Thread] = []
        
        dynamicValue.onChange(forceToMainThread: true) { _ in
            callbackTriggerCount += 1
            threads.append(Thread.current)
        }
        
        dynamicValue.value = 10
        
        expect(self.dynamicValue.value).to(equal(10))
        expect(threads)
            .to(equal([
                Thread.main,
                Thread.main
            ]))
    }
}
