// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import XCTest
import Combine
import Nimble

@testable import Session

class ConversationNotificationSettingsViewModelTests: XCTestCase {
    typealias Item = ConversationNotificationSettingsViewModel.Item
    
    var disposables: Set<AnyCancellable>!
    var dataChangedCallbackTriggered: Bool = false
    var thread: TSGroupThread!
    var defaultItems: [ConversationNotificationSettingsViewModel.Item]!
    var viewModel: ConversationNotificationSettingsViewModel!

    // MARK: - Configuration

    override func setUpWithError() throws {
        disposables = Set()
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
        disposables = nil
        dataChangedCallbackTriggered = false
        thread = nil
        defaultItems = nil
        viewModel = nil
    }

    // MARK: - Basic Tests

    func testItHasTheCorrectTitle() throws {
        expect(self.viewModel.title).to(equal("CONVERSATION_SETTINGS_MESSAGE_NOTIFICATIONS".localized()))
    }

    func testItHasTheCorrectNumberOfItems() throws {
        expect(self.viewModel.items.newest)
            .toEventually(
                haveCount(3),
                timeout: .milliseconds(100)
            )
    }

    func testItHasTheCorrectDefaultState() throws {
        expect(self.viewModel.items.newest)
            .toEventually(
                equal(defaultItems),
                timeout: .milliseconds(100)
            )
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

        var nonDefaultItems: [Item] = defaultItems
        nonDefaultItems[0] = Item(id: nonDefaultItems[0].id, title: nonDefaultItems[0].title, isActive: false)
        nonDefaultItems[2] = Item(id: nonDefaultItems[2].id, title: nonDefaultItems[2].title, isActive: true)

        // Note: We need this to ensure the desired 'expect' doesn't run before the 'hasWrittenToStorage'
        // flag is set as the viewModel gets recreated in the 'Storage.write'
        expect(hasWrittenToStorage)
            .toEventually(
                beTrue(),
                timeout: .milliseconds(100)
            )
        expect(self.viewModel.items.newest)
            .toEventually(
                equal(nonDefaultItems),
                timeout: .milliseconds(100)
            )
    }

    // MARK: - Interactions

    func testItSelectsTheItemCorrectly() throws {
        expect(self.viewModel.items.newest)
            .toEventually(
                satisfyAllOf(
                    haveCountGreaterThan(2),
                    valueFor(\.id, at: 0, to: equal(.all)),
                    valueFor(\.isActive, at: 0, to: beTrue()),
                    valueFor(\.id, at: 2, to: equal(.mute)),
                    valueFor(\.isActive, at: 2, to: beFalse())
                ),
                timeout: .milliseconds(100)
            )

        // Trigger the change
        viewModel.itemSelected.send(.mute)
        
        expect(self.viewModel.items.newest)
            .toEventually(
                satisfyAllOf(
                    haveCountGreaterThan(2),
                    valueFor(\.id, at: 0, to: equal(.all)),
                    valueFor(\.isActive, at: 0, to: beFalse()),
                    valueFor(\.id, at: 2, to: equal(.mute)),
                    valueFor(\.isActive, at: 2, to: beTrue())
                ),
                timeout: .milliseconds(100)
            )
    }

    func testItUpdatesToAll() throws {
        // Need to set it to something else first
        viewModel.items.sink(receiveValue: { _ in }).store(in: &disposables)
        viewModel.itemSelected.send(.mentionsOnly)

        expect(self.viewModel.items.newest)
            .toEventually(
                satisfyAllOf(
                    haveCountGreaterThan(0),
                    valueFor(\.id, at: 0, to: equal(.all)),
                    valueFor(\.isActive, at: 0, to: beFalse())
                ),
                timeout: .milliseconds(100)
            )

        // Trigger the change
        viewModel.itemSelected.send(.all)
        
        expect(self.viewModel.items.newest)
            .toEventually(
                satisfyAllOf(
                    haveCountGreaterThan(0),
                    valueFor(\.id, at: 0, to: equal(.all)),
                    valueFor(\.isActive, at: 0, to: beTrue())
                ),
                timeout: .milliseconds(100)
            )
    }

    func testItUpdatesToMentionsOnly() throws {
        expect(self.viewModel.items.newest)
            .toEventually(
                satisfyAllOf(
                    haveCountGreaterThan(1),
                    valueFor(\.id, at: 1, to: equal(.mentionsOnly)),
                    valueFor(\.isActive, at: 1, to: beFalse())
                ),
                timeout: .milliseconds(100)
            )

        // Trigger the change
        viewModel.itemSelected.send(.mentionsOnly)
        
        expect(self.viewModel.items.newest)
            .toEventually(
                satisfyAllOf(
                    haveCountGreaterThan(1),
                    valueFor(\.id, at: 1, to: equal(.mentionsOnly)),
                    valueFor(\.isActive, at: 1, to: beTrue())
                ),
                timeout: .milliseconds(100)
            )
    }

    func testItUpdatesToMute() throws {
        expect(self.viewModel.items.newest)
            .toEventually(
                satisfyAllOf(
                    haveCountGreaterThan(2),
                    valueFor(\.id, at: 2, to: equal(.mute)),
                    valueFor(\.isActive, at: 2, to: beFalse())
                ),
                timeout: .milliseconds(100)
            )

        // Trigger the change
        viewModel.itemSelected.send(.mute)
        
        expect(self.viewModel.items.newest)
            .toEventually(
                satisfyAllOf(
                    haveCountGreaterThan(2),
                    valueFor(\.id, at: 2, to: equal(.mute)),
                    valueFor(\.isActive, at: 2, to: beTrue())
                ),
                timeout: .milliseconds(100)
            )
    }
}
