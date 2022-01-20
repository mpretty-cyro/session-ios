// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionMessagingKit
import SignalUtilitiesKit

class ConversationSettingsViewModel {
    struct Item {
        enum Id: CaseIterable {
            case header
            case search
            case editGroup
            case allMedia
            case pinConversation
            case disappearingMessages
            case notifications
            case deleteMessages
            case leaveGroup
            case leaveGroupConfirmed
            case leaveGroupCompleted
            case blockUser
        }
        
        enum Style {
            case header
            case search
            case action
            case actionDestructive
        }
            
        let id: Id
        let style: Style
        let icon: UIImage?
        let title: String
        let subtitle: String?
        let accessibilityIdentifier: String?
        let isEnabled: Bool
        
        // Convenience
        
        func with(
            icon: UIImage? = nil,
            title: String? = nil,
            subtitle: String? = nil,
            isEnabled: Bool? = nil
        ) -> Item {
            return Item(
                id: id,
                style: style,
                icon: (icon ?? self.icon),
                title: (title ?? self.title),
                subtitle: (subtitle ?? self.subtitle),
                accessibilityIdentifier: accessibilityIdentifier,
                isEnabled: (isEnabled ?? self.isEnabled)
            )
        }
    }
    
    // MARK: - Variables
    
    let thread: DynamicValue<TSThread>
    private let uiDatabaseConnection: YapDatabaseConnection
    private var disappearingMessageConfiguration: OWSDisappearingMessagesConfiguration?
    
    // MARK: - Initialization
    
    init(thread: TSThread, uiDatabaseConnection: YapDatabaseConnection) {
        self.thread = DynamicValue(thread)
        self.uiDatabaseConnection = uiDatabaseConnection
        
        // Need to setup interaction binding and load in initial data
        self.setupBinding()
        self.refreshAllData()
    }
    
    // MARK: - Content and Interactions
    
    lazy var title: String = {
        if thread.value is TSContactThread {
            return NSLocalizedString("Settings", comment: "")
        }
        
        return NSLocalizedString("Group Settings", comment: "")
    }()
    
    lazy var items: DynamicValue<[[Item]]> = DynamicValue(generateItemsArray())
    
    lazy var interactions: Interactions<Item.Id, (TSThread, OWSDisappearingMessagesConfiguration?)> = Interactions { [weak self] in
        guard let strongSelf: ConversationSettingsViewModel = self else { return nil }
        
        return (strongSelf.thread.value, strongSelf.disappearingMessageConfiguration)
    }
    
    // MARK: - Internal State Management
    
    private lazy var viewState: [Item.Id: Item] = {
        let groupThread: TSGroupThread? = (thread.value as? TSGroupThread)
        
        return [
            .header: Item(
                id: .header,
                style: .header,
                icon: nil,
                title: {
                    if let contactThread: TSContactThread = thread.value as? TSContactThread {
                        return (Storage.shared.getContact(with: contactThread.contactSessionID())?.displayName(for: .regular) ?? "Anonymous")
                    }

                    let threadName: String = thread.value.name()

                    return (threadName.count == 0 && thread.value is TSGroupThread ?
                        MessageStrings.newGroupDefaultTitle :
                        threadName
                    )
                }(),
                subtitle: (thread.value is TSGroupThread ? nil : (thread.value as? TSContactThread)?.contactSessionID()),
                accessibilityIdentifier: nil,
                isEnabled: true
            ),
            
            .search: Item(
                id: .search,
                style: .search,
                icon: UIImage(named: "conversation_settings_search")?.withRenderingMode(.alwaysTemplate),
                title: NSLocalizedString("CONVERSATION_SETTINGS_SEARCH", comment: "label in conversation settings which returns the user to the conversation with 'search mode' activated"),
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).search",
                isEnabled: true
            ),
            
            .editGroup: Item(
                id: .editGroup,
                style: .action,
                icon: UIImage(named: "table_ic_group_edit")?.withRenderingMode(.alwaysTemplate),
                title: NSLocalizedString("EDIT_GROUP_ACTION", comment: "label in conversation settings"),
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).edit_group",
                isEnabled: true
            ),
                
            .allMedia: Item(
                id: .allMedia,
                style: .action,
                icon: UIImage(named: "actionsheet_camera_roll_black")?.withRenderingMode(.alwaysTemplate),
                title: MediaStrings.allMedia,
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).all_media",
                isEnabled: true
            ),
            
            .pinConversation: Item(
                id: .pinConversation,
                style: .action,
                icon: UIImage(named: "settings_pin")?.withRenderingMode(.alwaysTemplate),
                title: "",  // Set in 'refreshData'
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).pin_conversation",
                isEnabled: true
            ),
            
            .disappearingMessages: Item(
                id: .disappearingMessages,
                style: .action,
                icon: UIImage(named: "timer_55")?.withRenderingMode(.alwaysTemplate),
                title: NSLocalizedString("DISAPPEARING_MESSAGES", comment: "label in conversation settings"),
                subtitle: nil,  // Set in 'refreshData'
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).disappearing_messages",
                isEnabled: true
            ),
            
            .notifications: Item(
                id: .notifications,
                style: .action,
                icon: nil,  // Set in 'refreshData'
                title: "",  // Set in 'refreshData'
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).mute",
                isEnabled: true
            ),
            
            .deleteMessages: Item(
                id: .deleteMessages,
                style: .actionDestructive,
                icon: UIImage(named: "trash")?.withRenderingMode(.alwaysTemplate),
                title: NSLocalizedString("DELETE_MESSAGES", comment: "label in conversation settings"),
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).delete_messages",
                isEnabled: true
            ),
            
            .blockUser: Item(
                id: .blockUser,
                style: .actionDestructive,
                icon: UIImage(named: "table_ic_block")?.withRenderingMode(.alwaysTemplate),
                title: "",    // Set in 'refreshData'
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).block",
                isEnabled: true
            ),
            
            .leaveGroup: Item(
                id: .leaveGroup,
                style: .actionDestructive,
                icon: UIImage(named: "table_ic_group_leave")?.withRenderingMode(.alwaysTemplate),
                title: NSLocalizedString("LEAVE_GROUP_ACTION", comment: "label in conversation settings"),
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).leave_group",
                isEnabled: true
            )
        ]
    }()
    
    private func generateItemsArray() -> [[Item]] {
        let groupThread: TSGroupThread? = (thread.value as? TSGroupThread)
        let isClosedGroupAndMemeber: Bool = (groupThread != nil && groupThread?.isClosedGroup == true && groupThread?.isUserMember(inGroup: SNGeneralUtilities.getUserPublicKey()) == true)
        let isOpenGroup: Bool = (groupThread != nil && groupThread?.isOpenGroup == true)
        
        return [
            // Header section
            [
                viewState[.header]
            ].compactMap { $0 },
            
            // Search section
            [
                // TODO: Setup 'search'
                viewState[.search]
            ].compactMap { $0 },
            
            // Main section
            [
                (isClosedGroupAndMemeber ? viewState[.editGroup] : nil),
                viewState[.allMedia],
                viewState[.pinConversation],
                (!isOpenGroup ? viewState[.disappearingMessages] : nil),
                (!thread.value.isNoteToSelf() ? viewState[.notifications] : nil)
            ]
            .compactMap { $0 },
            
            // Destructive Actions
            [
//                (thread.isNoteToSelf() || thread as? TSContactThread == nil ?
//                    nil
//                 :
                // TODO: Setup 'deleteMessages'
                viewState[.deleteMessages],
//                ),
                (!thread.value.isNoteToSelf() && !thread.value.isGroupThread() ? viewState[.blockUser] : nil),
                (isClosedGroupAndMemeber ? viewState[.leaveGroup] : nil)
            ]
            .compactMap { $0 }
        ]
    }
    
    private func setupBinding() {
        interactions.on(.pinConversation, forceToMainThread: false) { [weak self] thread, _ in
            thread.isPinned = !thread.isPinned
            thread.save()
            
            self?.tryRefreshData(for: .pinConversation)
        }
        
        // Handle the Mute/Unmute for DM notifications
        interactions.on(.notifications, forceToMainThread: false) { [weak self] thread, _ in
            guard !thread.isNoteToSelf() && !thread.isGroupThread() else { return }
            
            Storage.write { transaction in
                thread.updateWithMuted(
                    until: (thread.isMuted ? nil : Date.distantFuture),
                    transaction: transaction
                )
                
                self?.tryRefreshData(for: .notifications)
            }
        }
        
        // Handle leaving the group
        interactions.on(.leaveGroupConfirmed, forceToMainThread: false) { [weak self] thread, _ in
            guard let groupThread: TSGroupThread = thread as? TSGroupThread else { return }
            
            if groupThread.isClosedGroup {
                let groupPublicKey: String = LKGroupUtilities.getDecodedGroupID(groupThread.groupModel.groupId)
                
                Storage.write { transaction in
                    MessageSender.leave(groupPublicKey, using: transaction).retainUntilComplete()
                    
                    // Need to refresh the screen as some settings might be disabled by this
                    self?.refreshAllData()
                    self?.interactions.trigger(.leaveGroupCompleted)
                }
            }
        }
    }
    
    // MARK: - Functions
    
    private func refreshData(for itemId: Item.Id) {
        let groupThread: TSGroupThread? = (thread.value as? TSGroupThread)
        
        switch itemId {
            case .editGroup:
                self.viewState[.editGroup] = self.viewState[.editGroup]?.with(
                    isEnabled: (groupThread?.isCurrentUserMemberInGroup() != false)
                )
                
            case .pinConversation:
                self.viewState[.pinConversation] = self.viewState[.pinConversation]?.with(
                    title: (thread.value.isPinned ?
                        NSLocalizedString("CONVERSATION_SETTINGS_UNPIN", comment: "") :
                        NSLocalizedString("CONVERSATION_SETTINGS_PIN", comment: "")
                    )
                )
                
            case .disappearingMessages:
                guard let uniqueId: String = thread.value.uniqueId else { return }
                
                // Ensure the 'disappearingMessageConfiguration' value is set to something
                let targetConfig: OWSDisappearingMessagesConfiguration
                
                if let config: OWSDisappearingMessagesConfiguration = self.disappearingMessageConfiguration {
                    targetConfig = config
                }
                else if let config: OWSDisappearingMessagesConfiguration = OWSDisappearingMessagesConfiguration.fetch(uniqueId: uniqueId) {
                    targetConfig = config
                }
                else {
                    targetConfig = OWSDisappearingMessagesConfiguration(defaultWithThreadId: uniqueId)
                }
                
                // Update the data store
                self.disappearingMessageConfiguration = targetConfig
                self.viewState[.disappearingMessages] = self.viewState[.disappearingMessages]?.with(
                    subtitle: (targetConfig.isEnabled ?
                        targetConfig.shortDurationString :
                        NSLocalizedString("DISAPPEARING_MESSAGES_OFF", comment: "label in conversation settings")
                    ),
                    isEnabled: (groupThread?.isCurrentUserMemberInGroup() != false)
                )
                
            case .notifications:
                guard !thread.value.isNoteToSelf() && !thread.value.isGroupThread() else {
                    self.viewState[.notifications] = self.viewState[.notifications]?.with(
                        icon: UIImage(named: "unmute_unfilled")?.withRenderingMode(.alwaysTemplate),
                        title: NSLocalizedString("CONVERSATION_SETTINGS_MESSAGE_NOTIFICATIONS", comment: ""),
                        subtitle: (groupThread?.isMuted == true || groupThread?.isCurrentUserMemberInGroup() == false ?
                            NSLocalizedString("vc_conversation_notifications_settings_mute_title", comment: "") :
                            (groupThread?.isOnlyNotifyingForMentions == true ?
                                NSLocalizedString("vc_conversation_notifications_settings_mentions_only_title_short", comment: "") :
                                NSLocalizedString("vc_conversation_notifications_settings_all_title", comment: "")
                            )
                        ),
                        isEnabled: (groupThread?.isCurrentUserMemberInGroup() != false)
                    )
                    return
                }

                self.viewState[.notifications] = self.viewState[.notifications]?.with(
                    icon: (thread.value.isMuted ?
                        UIImage(named: "unmute_unfilled")?.withRenderingMode(.alwaysTemplate) :
                        UIImage(named: "mute_unfilled")?.withRenderingMode(.alwaysTemplate)
                    ),
                    title: (thread.value.isMuted ?
                        NSLocalizedString("CONVERSATION_SETTINGS_UNMUTE_ACTION_NEW", comment: "") :
                        NSLocalizedString("CONVERSATION_SETTINGS_MUTE_ACTION_NEW", comment: "")
                    )
                )
                
            case .blockUser:
                guard !thread.value.isNoteToSelf() && !thread.value.isGroupThread() else { return }
                
                self.viewState[.blockUser] = self.viewState[.blockUser]?.with(
                    title: (OWSBlockingManager.shared().isThreadBlocked(thread.value) ?
                        NSLocalizedString("CONVERSATION_SETTINGS_UNBLOCK_USER", comment: "") :
                        NSLocalizedString("CONVERSATION_SETTINGS_BLOCK_USER", comment: "")
                    )
                )
                
            case .leaveGroup:
                self.viewState[.leaveGroup] = self.viewState[.leaveGroup]?.with(
                    isEnabled: (groupThread?.isCurrentUserMemberInGroup() != false)
                )
                
            // Data cannot be updated so don't make any changes
            default: return
        }
    }
    
    private func refreshAllData() {
        // Loop through the array and refresh the data then update the items
        Item.Id.allCases.forEach { refreshData(for: $0) }
        items.value = generateItemsArray()
    }
    
    func tryRefreshData(for itemId: Item.Id) {
        // Refresh the desired data and update the items
        refreshData(for: itemId)
        items.value = generateItemsArray()
    }
    
    func profilePictureTapped() {
        
    }
    
    func displayNameTapped() {
        
    }
}
