// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionMessagingKit
import SessionUtilitiesKit

class ConversationNotificationSettingsViewModel {
    struct Item {
        enum Id: CaseIterable {
            case all
            case mentionsOnly
            case mute
        }
            
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
    
    private let thread: TSGroupThread
    private let dataChanged: () -> ()
    
    // MARK: - Initialization
    
    init(thread: TSGroupThread, dataChanged: @escaping () -> ()) {
        self.thread = thread
        self.dataChanged = dataChanged
        
        // Need to setup interaction binding and load in initial data
        self.setupBinding()
        self.refreshAllData()
    }
    
    // MARK: - Content and Interactions
    
    let title: String = NSLocalizedString("CONVERSATION_SETTINGS_MESSAGE_NOTIFICATIONS", comment: "")
    
    lazy var items: DynamicValue<[Item]> = DynamicValue(Item.Id.allCases.compactMap { viewState[$0] })
    
    lazy var interaction: InteractionManager<Item.Id, (TSGroupThread, Any?)> = InteractionManager { [weak self] interactionData in
        guard let strongSelf: ConversationNotificationSettingsViewModel = self else { return nil }
        
        return (strongSelf.thread, interactionData)
    }
    
    // MARK: - Internal State Management
    
    private lazy var viewState: [Item.Id: Item] = [
        .all: Item(
            id: .all,
            title: "vc_conversation_notifications_settings_all_title".localized(),
            isActive: false
        ),
        
        .mentionsOnly: Item(
            id: .mentionsOnly,
            title: "vc_conversation_notifications_settings_mentions_only_title".localized(),
            isActive: false
        ),
        
        .mute: Item(
            id: .mute,
            title: "vc_conversation_notifications_settings_mute_title".localized(),
            isActive: false
        )
    ]
    
    private func setupBinding() {
        interaction.on(.all, forceToMainThread: false) { [weak self] thread, _ in
            Storage.write { transaction in
                thread.setIsOnlyNotifyingForMentions(false, with: transaction)
                thread.updateWithMuted(until: nil, transaction: transaction)
                
                self?.refreshAllData()
                self?.dataChanged()
            }
        }
        
        interaction.on(.mentionsOnly, forceToMainThread: false) { [weak self] thread, _ in
            Storage.write { transaction in
                thread.setIsOnlyNotifyingForMentions(true, with: transaction)
                thread.updateWithMuted(until: nil, transaction: transaction)
                
                self?.refreshAllData()
                self?.dataChanged()
            }
        }
        
        interaction.on(.mute, forceToMainThread: false) { [weak self] thread, _ in
            Storage.write { transaction in
                thread.setIsOnlyNotifyingForMentions(false, with: transaction)
                thread.updateWithMuted(until: Date.distantFuture, transaction: transaction)
                
                self?.refreshAllData()
                self?.dataChanged()
            }
        }
    }
    
    // MARK: - Functions
    
    private func refreshData(for itemId: Item.Id) {
        switch itemId {
            case .all:
                self.viewState[.all] = self.viewState[.all]?.with(
                    isActive: (!thread.isMuted && !thread.isOnlyNotifyingForMentions)
                )
                
            case .mentionsOnly:
                self.viewState[.mentionsOnly] = self.viewState[.mentionsOnly]?.with(
                    isActive: thread.isOnlyNotifyingForMentions
                )
                
            case .mute:
                self.viewState[.mute] = self.viewState[.mute]?.with(
                    isActive: thread.isMuted
                )
        }
    }
    
    private func refreshAllData() {
        // Loop through the array and refresh the data then update the items
        Item.Id.allCases.forEach { refreshData(for: $0) }
        items.value = Item.Id.allCases.compactMap { viewState[$0] }
    }
    
    func tryRefreshData(for itemId: Item.Id) {
        // Refresh the desired data and update the items
        refreshData(for: itemId)
        items.value = Item.Id.allCases.compactMap { viewState[$0] }
    }
}
