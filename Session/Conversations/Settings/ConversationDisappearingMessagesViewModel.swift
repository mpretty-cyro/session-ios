// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionMessagingKit
import SessionUtilitiesKit

class ConversationDisappearingMessagesViewModel {
    private let thread: TSThread
    private var disappearingMessagesConfiguration: OWSDisappearingMessagesConfiguration
    private let dataChanged: () -> ()
    
    var onItemsChanged: (([(index: Int, title: String, isActive: Bool)]) -> ())? {
        didSet {
            onItemsChanged?(dataStore)
        }
    }
    
    // MARK: - Initialization
    
    init(thread: TSThread, disappearingMessagesConfiguration: OWSDisappearingMessagesConfiguration, dataChanged: @escaping () -> ()) {
        self.thread = thread
        self.disappearingMessagesConfiguration = disappearingMessagesConfiguration
        self.dataChanged = dataChanged
    }
    
    // MARK: - Data
    
    let title: String = NSLocalizedString("DISAPPEARING_MESSAGES", comment: "label in conversation settings")
    
    private lazy var dataStore: [(index: Int, title: String, isActive: Bool)] = {
        // Need to '+ 1' the 'durationIndex' if the config is enabled as the "Off" option isn't included in
        // the 'validDurationsSeconds' set so to include it the 'durationIndex' needs to be 1-indexed
        let currentIndex: UInt = (disappearingMessagesConfiguration.isEnabled ?
            (disappearingMessagesConfiguration.durationIndex + 1) :
            0
        )
        
        // Setup the initial state of the items
        return [NSLocalizedString("DISAPPEARING_MESSAGES_OFF", comment: "label in conversation settings")]
            .appending(
                contentsOf: OWSDisappearingMessagesConfiguration.validDurationsSeconds()
                    .map { seconds in NSString.formatDurationSeconds(UInt32(seconds.intValue), useShortFormat: false) }
            )
            .enumerated()
            .map { index, title -> (Int, String, Bool) in (index, title, (currentIndex == index)) }
    }()
    
    // MARK: - Functions
    
    func itemTapped(_ tappedIndex: Int) {
        dataStore = dataStore.map { index, title, isActive in
            (index, title, (index == tappedIndex))
        }
        
        disappearingMessagesConfiguration.isEnabled = (tappedIndex != 0)
        disappearingMessagesConfiguration.durationSeconds = (tappedIndex == 0 ?
            0 :
            OWSDisappearingMessagesConfiguration.validDurationsSeconds()[tappedIndex - 1].uint32Value
        )
        
        onItemsChanged?(dataStore)
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
