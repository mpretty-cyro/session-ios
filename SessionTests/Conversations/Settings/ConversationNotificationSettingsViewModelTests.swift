// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import XCTest
import Nimble

@testable import Session

class ConversationNotificationSettingsViewModelTests: XCTestCase {
    var dataChangedCallbackTriggered: Bool = false
    var thread: TSGroupThread!
    var defaultItems: [ConversationNotificationSettingsViewModel.Item]!
    var viewModel: ConversationNotificationSettingsViewModel!
    
    // MARK: - Configuration

    override func setUpWithError() throws {
        dataChangedCallbackTriggered = false
        
        thread = TSGroupThread(uniqueId: "TestId")
        defaultItems = [
            ConversationNotificationSettingsViewModel.Item(
                id: .all,
                title: "vc_conversation_notifications_settings_all_title".localized(),
                isActive: true
            ),
            ConversationNotificationSettingsViewModel.Item(
                id: .mentionsOnly,
                title: "vc_conversation_notifications_settings_mentions_only_title".localized(),
                isActive: false
            ),
            ConversationNotificationSettingsViewModel.Item(
                id: .mute,
                title: "vc_conversation_notifications_settings_mute_title".localized(),
                isActive: false
            )
        ]
        
        viewModel = ConversationNotificationSettingsViewModel(thread: thread) { [weak self] in
            self?.dataChangedCallbackTriggered = true
        }
    }
    
    override func tearDownWithError() throws {
        dataChangedCallbackTriggered = false
        thread = nil
        defaultItems = nil
        viewModel = nil
    }
    
    
    
    // MARK: - ConversationNotificationSettingsViewModel.Item
    
    func testItDefaultsToTheExistingValuesWhenUpdatedWithNullValues() throws {
        var item: ConversationNotificationSettingsViewModel.Item = ConversationNotificationSettingsViewModel.Item(
            id: .mentionsOnly,
            title: "Test",
            isActive: true
        )
        
        expect(item.isActive).to(beTrue())
        
        item = item.with(isActive: nil)
        expect(item.isActive).to(beTrue())
        
        item = item.with(isActive: false)
        expect(item.isActive).to(beFalse())
    }
    
    // MARK: - Basic Tests
    
    func testItHasTheCorrectTitle() throws {
        expect(self.viewModel.title).to(equal("CONVERSATION_SETTINGS_MESSAGE_NOTIFICATIONS".localized()))
    }
    
    func testItHasTheCorrectNumberOfItems() throws {
        expect(self.viewModel.items.value.count).to(equal(3))
    }
    
    func testItHasTheCorrectDefaultState() throws {
        expect(self.viewModel.items.value).to(equal(defaultItems))
    }
    
    func testItStartsWithTheCorrectItemActiveIfNotDefault() throws {
        var hasWrittenToStorage: Bool = false
        
        Storage.write { [weak self] transaction in
            guard let strongSelf = self else { return }
            
            strongSelf.thread = TSGroupThread(uniqueId: "TestId1")
            strongSelf.thread.updateWithMuted(until: Date.distantFuture, transaction: transaction)
            strongSelf.viewModel = ConversationNotificationSettingsViewModel(thread: strongSelf.thread) { [weak self] in
                self?.dataChangedCallbackTriggered = true
            }
            
            hasWrittenToStorage = true
        }
        
        var nonDefaultItems: [ConversationNotificationSettingsViewModel.Item] = defaultItems
        nonDefaultItems[0] = nonDefaultItems[0].with(isActive: false)
        nonDefaultItems[2] = nonDefaultItems[2].with(isActive: true)
        
        // Note: We need this to ensure the test doesn't run before the subsequent 'expect' doesn't
        // run before the viewModel gets recreated in the 'Storage.write'
        expect(hasWrittenToStorage)
            .toEventually(
                beTrue(),
                timeout: .milliseconds(100)
            )
        expect(self.viewModel.items.value).to(equal(nonDefaultItems))
    }
    
    // MARK: - Interactions
    
    func testItProvidesTheThreadAndGivenDataWhenAnInteractionOccurs() throws {
        var interactionThread: TSThread? = nil
        var interactionData: String? = nil
        
        self.viewModel.interaction.on(.all) { thread, data in
            interactionThread = thread
            interactionData = (data as? String)
        }
        
        self.viewModel.interaction.tap(.all, data: "Test")
        
        expect(interactionThread).to(equal(self.thread))
        expect(interactionData).to(equal("Test"))
    }
    
    func testItRefreshesTheDataCorrectly() throws {
        expect(self.viewModel.items.value.first?.id).to(equal(.all))
        expect(self.viewModel.items.value.first?.isActive).to(beTrue())
        expect(self.viewModel.items.value.last?.id).to(equal(.mute))
        expect(self.viewModel.items.value.last?.isActive).to(beFalse())
        
        // TODO: Mock out 'Storage'
        Storage.write { [weak self] transaction in
            self?.thread.updateWithMuted(until: Date.distantFuture, transaction: transaction)

            self?.viewModel.tryRefreshData(for: .all)
            self?.viewModel.tryRefreshData(for: .mute)
        }
        
        expect(self.viewModel.items.value.first?.id)
            .toEventually(
                equal(.all),
                timeout: .milliseconds(100)
            )
        expect(self.viewModel.items.value.first?.isActive)
            .toEventually(
                beFalse(),
                timeout: .milliseconds(100)
            )
        expect(self.viewModel.items.value.last?.id)
            .toEventually(
                equal(.mute),
                timeout: .milliseconds(100)
            )
        expect(self.viewModel.items.value.last?.isActive)
            .toEventually(
                beTrue(),
                timeout: .milliseconds(100)
            )
    }
    
    func testItUpdatesToAll() throws {
        // Need to set it to something else first
        viewModel.interaction.tap(.mentionsOnly)
        
        expect(self.viewModel.items.value.count).to(beGreaterThan(0))
        expect(self.viewModel.items.value[0].id)
            .toEventually(
                equal(.all),
                timeout: .milliseconds(100)
            )
        expect(self.viewModel.items.value[0].isActive)
            .toEventually(
                beFalse(),
                timeout: .milliseconds(100)
            )
        
        viewModel.interaction.tap(.all)
        
        expect(self.viewModel.items.value[0].id)
            .toEventually(
                equal(.all),
                timeout: .milliseconds(100)
            )
        expect(self.viewModel.items.value[0].isActive)
            .toEventually(
                beTrue(),
                timeout: .milliseconds(100)
            )
    }
    
    func testItUpdatesToMentionsOnly() throws {
        expect(self.viewModel.items.value.count).to(beGreaterThan(1))
        expect(self.viewModel.items.value[1].id).to(equal(.mentionsOnly))
        expect(self.viewModel.items.value[1].isActive).to(beFalse())
        
        viewModel.interaction.tap(.mentionsOnly)
        
        expect(self.viewModel.items.value[1].id)
            .toEventually(
                equal(.mentionsOnly),
                timeout: .milliseconds(100)
            )
        expect(self.viewModel.items.value[1].isActive)
            .toEventually(
                beTrue(),
                timeout: .milliseconds(100)
            )
    }
    
    func testItUpdatesToMute() throws {
        expect(self.viewModel.items.value.count).to(beGreaterThan(2))
        expect(self.viewModel.items.value[2].id).to(equal(.mute))
        expect(self.viewModel.items.value[2].isActive).to(beFalse())
        
        viewModel.interaction.tap(.mute)
        
        expect(self.viewModel.items.value[2].id)
            .toEventually(
                equal(.mute),
                timeout: .milliseconds(100)
            )
        expect(self.viewModel.items.value[2].isActive)
            .toEventually(
                beTrue(),
                timeout: .milliseconds(100)
            )
    }
}
