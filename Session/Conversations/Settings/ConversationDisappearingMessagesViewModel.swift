// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionMessagingKit
import SessionUtilitiesKit

class ConversationDisappearingMessagesViewModel {
    struct Item: Equatable {
        typealias Id = Int
        
        let id: Id
        let title: String
        let isActive: Bool
        
        // Convenience
        
        func with(
            isActive: Bool? = nil
        ) -> Item {
            return Item(
                id: id,
                title: title,
                isActive: (isActive ?? self.isActive)
            )
        }
    }
    
    // MARK: - Variables
    
    private let thread: TSThread
    private var disappearingMessagesConfiguration: OWSDisappearingMessagesConfiguration
    private let dataChanged: () -> ()
    
    // MARK: - Initialization
    
    init(thread: TSThread, disappearingMessagesConfiguration: OWSDisappearingMessagesConfiguration, dataChanged: @escaping () -> ()) {
        self.thread = thread
        self.disappearingMessagesConfiguration = disappearingMessagesConfiguration
        self.dataChanged = dataChanged
        
        // Need to setup interaction binding and load in initial data
        self.setupBinding()
        self.refreshAllData()
    }
    
    // MARK: - Content and Interactions
    
    let title: String = "DISAPPEARING_MESSAGES_SETTINGS_TITLE".localized()
    
    lazy var description: String = {
        let displayName: String
        
        if thread.isGroupThread() {
            displayName = "the group"
        }
        else if let contactThread: TSContactThread = thread as? TSContactThread {
            contactThread.contactSessionID()
            displayName = (Storage.shared.getContact(with: contactThread.contactSessionID())?.displayName(for: .regular) ?? "anonymous")
        }
        else {
            displayName = "anonymous"
        }
        
        return String(format: NSLocalizedString("When enabled, messages between you and %@ will disappear after they have been seen.", comment: ""), arguments: [displayName])
    }()
    
    lazy var items: DynamicValue<[Item]> = {
        // Need to '+ 1' the 'durationIndex' if the config is enabled as the "Off" option isn't included in
        // the 'validDurationsSeconds' set so to include it the 'durationIndex' needs to be 1-indexed
        let currentIndex: UInt = (disappearingMessagesConfiguration.isEnabled ?
            (disappearingMessagesConfiguration.durationIndex + 1) :
            0
        )
        
        // Setup the initial state of the items
        return DynamicValue(
            ["DISAPPEARING_MESSAGES_OFF".localized()]
                .appending(
                    contentsOf: OWSDisappearingMessagesConfiguration.validDurationsSeconds()
                        .map { seconds in NSString.formatDurationSeconds(UInt32(seconds.intValue), useShortFormat: false) }
                )
                .enumerated()
                .map { index, title -> Item in Item(id: index, title: title, isActive: (currentIndex == index)) }
        )
    }()
    
    lazy var interaction: InteractionManager<Int, TSThread> = InteractionManager { [weak self] _ in
        guard let strongSelf: ConversationDisappearingMessagesViewModel = self else { return nil }
        
        return (strongSelf.thread)
    }
    
    // MARK: - Internal State Management
    
    private lazy var viewState: [Item.Id: Item] = {
        // Need to '+ 1' the 'index' for the duration options as the "Off" option isn't included in
        // the 'validDurationsSeconds' set so to include it the 'index' needs to be 1-indexed
        return [
            0: Item(
                id: 0,
                title: "DISAPPEARING_MESSAGES_OFF".localized(),
                isActive: false
            )
        ]
            .setting(
                contentsOf: OWSDisappearingMessagesConfiguration.validDurationsSeconds()
                    .map { seconds in NSString.formatDurationSeconds(UInt32(seconds.intValue), useShortFormat: false) }
                    .enumerated()
                    .map { index, title -> (key: Item.Id, value: Item) in
                        (
                            key: (index + 1),
                            value: Item(
                                id: (index + 1),
                                title: title,
                                isActive: false
                            )
                        )
                    }
            )
    }()
    
    private func setupBinding() {
        interaction.onAny(forceToMainThread: false) { [weak self] id, _ in
            self?.disappearingMessagesConfiguration.isEnabled = (id != 0)
            self?.disappearingMessagesConfiguration.durationSeconds = (id == 0 ?
                0 :
                OWSDisappearingMessagesConfiguration.validDurationsSeconds()[id - 1].uint32Value
            )

            self?.refreshAllData()
        }
    }
    
    // MARK: - Functions
    
    private func refreshData(for itemId: Int) {
        // See the 'viewState' section for an explanation but the 'itemId' value is 1-indexed and the
        // 'durationIndex' value is 0-indexed
        let currentIndex: UInt = (disappearingMessagesConfiguration.isEnabled ?
            (disappearingMessagesConfiguration.durationIndex + 1) :
            0
        )
        
        self.viewState[itemId] = self.viewState[itemId]?.with(
            isActive: (currentIndex == itemId)
        )
    }
    
    private func refreshAllData() {
        // Loop through the array and refresh the data then update the items
        self.viewState.keys.forEach { refreshData(for: $0) }
        items.value = Array(self.viewState.values)
            .sorted { lhs, rhs in lhs.id < rhs.id }
    }
    
    func tryRefreshData(for itemId: Item.Id) {
        // Refresh the desired data and update the items
        refreshData(for: itemId)
        items.value = Array(self.viewState.values)
            .sorted { lhs, rhs in lhs.id < rhs.id }
    }
    
    func trySaveChanges() {
        let config: OWSDisappearingMessagesConfiguration = self.disappearingMessagesConfiguration
        let isDefaultState: Bool = (config.isNewRecord && !config.isEnabled)
        let localThread: TSThread = self.thread
        
        // Don't save defaults, else we'll unintentionally save the configuration and notify the contact.
        guard !isDefaultState else { return }

        if config.dictionaryValueDidChange {
            Storage.shared.write { [weak self] anyTransaction in
                guard let transaction: YapDatabaseReadWriteTransaction = anyTransaction as? YapDatabaseReadWriteTransaction else {
                    return
                }
                
                config.save(with: transaction)
                
                let infoMessage: OWSDisappearingConfigurationUpdateInfoMessage = OWSDisappearingConfigurationUpdateInfoMessage(
                    timestamp: NSDate.ows_millisecondTimeStamp(),
                    thread: localThread,
                    configuration: config,
                    createdByRemoteName: nil,
                    createdInExistingGroup: false
                )
                infoMessage.save(with: transaction)
                
                let expirationTimerUpdate = ExpirationTimerUpdate()
                expirationTimerUpdate.duration = (config.isEnabled ? config.durationSeconds : 0)
                MessageSender.send(expirationTimerUpdate, in: localThread, using: transaction)
                
                self?.dataChanged()
            }
        }
    }
}
