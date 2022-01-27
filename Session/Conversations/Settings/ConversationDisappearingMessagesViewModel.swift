// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
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
    private let disappearingMessagesConfiguration: OWSDisappearingMessagesConfiguration
    private let dataChanged: () -> ()
    
    // MARK: - Initialization
    
    init(thread: TSThread, disappearingMessagesConfiguration: OWSDisappearingMessagesConfiguration, dataChanged: @escaping () -> ()) {
        self.thread = thread
        self.disappearingMessagesConfiguration = disappearingMessagesConfiguration
        self.dataChanged = dataChanged
    }
    
    // MARK: - Input
    
    let itemSelected: PassthroughSubject<Item.Id, Never> = PassthroughSubject()
    
    // MARK: - Content
    
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
    
    lazy var items: AnyPublisher<[Item], Never> = {
        // Need to '+ 1' the 'durationIndex' if the config is enabled as the "Off" option isn't included in
        // the 'validDurationsSeconds' set so to include it the 'durationIndex' needs to be 1-indexed
        let initialIndex: Int = Int(disappearingMessagesConfiguration.isEnabled ?
            (disappearingMessagesConfiguration.durationIndex + 1) :
            0
        )
        
        return itemSelected
            .handleEvents(receiveOutput: { [weak self] index in
                self?.disappearingMessagesConfiguration.isEnabled = (index != 0)
                self?.disappearingMessagesConfiguration.durationSeconds = (index == 0 ?
                    0 :
                    OWSDisappearingMessagesConfiguration.validDurationsSeconds()[index - 1].uint32Value
                )
            })
            .prepend(initialIndex)
            .map { selectedId -> [Item] in
                [
                    "DISAPPEARING_MESSAGES_OFF".localized()
                ]
                .appending(
                    contentsOf: OWSDisappearingMessagesConfiguration.validDurationsSeconds()
                        .map { seconds -> String in
                            NSString.formatDurationSeconds(UInt32(seconds.intValue), useShortFormat: false)
                        }
                )
                .enumerated()
                .map { index, title -> Item in
                    Item(id: index, title: title, isActive: (selectedId == index))
                }
            }
            .shareReplay(1)
            .eraseToAnyPublisher()
    }()
    
    // MARK: - Functions
    
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
