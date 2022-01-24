// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import XCTest
import Nimble

@testable import Session

class ConversationSettingsViewModelTests: XCTestCase {
    var didTriggerSearchCallbackTriggered: Bool = false
    var publicKey: String!
    var thread: TSThread!
    var uiDatabaseConnection: YapDatabaseConnection!
    var viewModel: ConversationSettingsViewModel!
    
    // MARK: - Configuration

    override func setUpWithError() throws {
        didTriggerSearchCallbackTriggered = false
        
        // TODO: Need to mock TSThread, YapDatabaseConnection and the publicKey retrieval logic
        publicKey = SNGeneralUtilities.getUserPublicKey()
        thread = TSContactThread(contactSessionID: "TestContactId")
        uiDatabaseConnection = OWSPrimaryStorage.shared().uiDatabaseConnection
        viewModel = ConversationSettingsViewModel(thread: thread, uiDatabaseConnection: uiDatabaseConnection, didTriggerSearch: { [weak self] in
            self?.didTriggerSearchCallbackTriggered = true
        })
    }
    
    override func tearDownWithError() throws {
        didTriggerSearchCallbackTriggered = false
        publicKey = nil
        thread = nil
        uiDatabaseConnection = nil
        viewModel = nil
    }
    
    // MARK: - Basic Tests
    
    func testItHasTheCorrectTitleForAnIndividualThread() {
        expect(self.viewModel.title).to(equal("vc_settings_title".localized()))
    }
    
    func testItHasTheCorrectTitleForAGroupThread() {
        thread = TSGroupThread(uniqueId: "TestGroupId1")
        viewModel = ConversationSettingsViewModel(thread: thread, uiDatabaseConnection: uiDatabaseConnection, didTriggerSearch: { [weak self] in
            self?.didTriggerSearchCallbackTriggered = true
        })
        
        expect(self.viewModel.title).to(equal("vc_group_settings_title".localized()))
    }
    
    // MARK: - All Conversation Type Shared Tests
    
    func testItTriggersTheSearchCallbackWhenInteractingWithSearch() {
        viewModel.interaction.tap(.search)
        
        expect(self.didTriggerSearchCallbackTriggered).to(beTrue())
    }
    
    func testItPinsAConversation() {
        viewModel.interaction.tap(.togglePinConversation)
        
        expect(self.thread.isPinned)
            .toEventually(
                beTrue(),
                timeout: .milliseconds(100)
            )
    }
    
    func testItUnPinsAConversation() {
        viewModel.interaction.tap(.togglePinConversation)
        
        expect(self.thread.isPinned)
            .toEventually(
                beTrue(),
                timeout: .milliseconds(100)
            )
        
        viewModel.interaction.tap(.togglePinConversation)
        
        expect(self.thread.isPinned)
            .toEventually(
                beFalse(),
                timeout: .milliseconds(100)
            )
    }
    
    // MARK: - Individual & Note to Self Conversation Shared Tests
    
    func testItHasTheCorrectDefaultNavButtonsForAContactConversation() {
        expect(self.viewModel.leftNavItems.value).to(equal([]))
        expect(self.viewModel.rightNavItems.value)
            .to(equal([
                ConversationSettingsViewModel.Item(
                    id: .navEdit,
                    style: .navigation,
                    action: .startEditingDisplayName,
                    icon: nil,
                    title: "",
                    barButtonItem: .edit,
                    subtitle: nil,
                    isEnabled: true,
                    isNegativeAction: false,
                    accessibilityIdentifier: "Edit button"
                )
            ]))
    }
    
    func testItUpdatesTheNavButtonsWhenEnteringEditMode() {
        viewModel.interaction.tap(.startEditingDisplayName)
        
        expect(self.viewModel.leftNavItems.value)
            .to(equal([
                ConversationSettingsViewModel.Item(
                    id: .navCancel,
                    style: .navigation,
                    action: .cancelEditingDisplayName,
                    icon: nil,
                    title: "",
                    barButtonItem: .cancel,
                    subtitle: nil,
                    isEnabled: true,
                    isNegativeAction: false,
                    accessibilityIdentifier: "Cancel button"
                )
            ]))
        expect(self.viewModel.rightNavItems.value)
            .to(equal([
                ConversationSettingsViewModel.Item(
                    id: .navDone,
                    style: .navigation,
                    action: .saveUpdatedDisplayName,
                    icon: nil,
                    title: "",
                    barButtonItem: .done,
                    subtitle: nil,
                    isEnabled: true,
                    isNegativeAction: false,
                    accessibilityIdentifier: "Done button"
                )
            ]))
    }
    
    func testItGoesBackToTheDefaultNavButtonsWhenYouCancelEditingTheDisplayName() {
        viewModel.interaction.tap(.startEditingDisplayName)
        
        expect(self.viewModel.leftNavItems.value.first?.id).to(equal(.navCancel))
        
        viewModel.interaction.tap(.cancelEditingDisplayName)
        
        expect(self.viewModel.leftNavItems.value).to(equal([]))
        expect(self.viewModel.rightNavItems.value)
            .to(equal([
                ConversationSettingsViewModel.Item(
                    id: .navEdit,
                    style: .navigation,
                    action: .startEditingDisplayName,
                    icon: nil,
                    title: "",
                    barButtonItem: .edit,
                    subtitle: nil,
                    isEnabled: true,
                    isNegativeAction: false,
                    accessibilityIdentifier: "Edit button"
                )
            ]))
    }
    
    func testItGoesBackToTheDefaultNavButtonsWhenYouSaveTheUpdatedDisplayName() {
        viewModel.interaction.tap(.startEditingDisplayName)
        
        expect(self.viewModel.leftNavItems.value.first?.id).to(equal(.navCancel))
        
        viewModel.interaction.tap(.saveUpdatedDisplayName)
        
        expect(self.viewModel.leftNavItems.value).to(equal([]))
        expect(self.viewModel.rightNavItems.value)
            .to(equal([
                ConversationSettingsViewModel.Item(
                    id: .navEdit,
                    style: .navigation,
                    action: .startEditingDisplayName,
                    icon: nil,
                    title: "",
                    barButtonItem: .edit,
                    subtitle: nil,
                    isEnabled: true,
                    isNegativeAction: false,
                    accessibilityIdentifier: "Edit button"
                )
            ]))
    }
    
    func testItUpdatesTheContactNicknameWhenSavingTheUpdatedDisplayName() {
        viewModel.interaction.tap(.startEditingDisplayName)
        viewModel.interaction.change(.changeDisplayName, data: "Test123")
        viewModel.interaction.tap(.saveUpdatedDisplayName)
        
        expect(Storage.shared.getContact(with: "TestContactId")?.nickname)
            .toEventually(
                equal("Test123"),
                timeout: .milliseconds(100)
            )
    }
    
    func testItMutesAConversation() {
        viewModel.interaction.tap(.toggleMuteNotifications)
        
        expect(self.thread.isMuted)
            .toEventually(
                beTrue(),
                timeout: .milliseconds(100)
            )
    }
    
    func testItUnMutesAConversation() {
        viewModel.interaction.tap(.toggleMuteNotifications)
        
        expect(self.thread.isMuted)
            .toEventually(
                beTrue(),
                timeout: .milliseconds(100)
            )
        
        viewModel.interaction.tap(.toggleMuteNotifications)
        
        expect(self.thread.isMuted)
            .toEventually(
                beFalse(),
                timeout: .milliseconds(100)
            )
    }
    
    // MARK: - Group Conversation Tests
    
    func testItHasNoCustomLeftNavButtons() {
        thread = TSGroupThread(uniqueId: "TestGroupId1")
        viewModel = ConversationSettingsViewModel(thread: thread, uiDatabaseConnection: uiDatabaseConnection, didTriggerSearch: { [weak self] in
            self?.didTriggerSearchCallbackTriggered = true
        })
        
        expect(self.viewModel.leftNavItems.value).to(equal([]))
    }
    
    func testItHasNoCustomRightNavButtons() {
        thread = TSGroupThread(uniqueId: "TestGroupId1")
        viewModel = ConversationSettingsViewModel(thread: thread, uiDatabaseConnection: uiDatabaseConnection, didTriggerSearch: { [weak self] in
            self?.didTriggerSearchCallbackTriggered = true
        })
        
        expect(self.viewModel.rightNavItems.value).to(equal([]))
    }
    
    // TODO: Various item states depending on thread type
    // TODO: Group title options (need mocking?)
    // TODO: Notification item title options (need mocking?)
    // TODO: Delete All Messages (need mocking)
    // TODO: Add to Group (need mocking)
    // TODO: Leave Group (need mocking)
}
