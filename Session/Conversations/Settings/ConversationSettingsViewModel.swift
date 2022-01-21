// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit

class ConversationSettingsViewModel {
    enum Action: CaseIterable {
        case nothing
        
        case viewProfilePicture
        
        case startEditingDisplayName
        case changeDisplayName
        case cancelEditingDisplayName
        case saveUpdatedDisplayName
        
        case search
        case viewAddToGroup
        case addToGroupCompleted
        case viewEditGroup
        case viewAllMedia
        case togglePinConversation
        case viewDisappearingMessagesSettings
        case toggleMuteNotifications
        case viewNotificationsSettings
        case deleteMessages
        case leaveGroup
        case leaveGroupConfirmed
        case leaveGroupCompleted
        case toggleBlockUser
    }
    
    struct Item {
        enum Id: CaseIterable {
            case navEdit
            case navCancel
            case navDone
            case header
            case search
            case addToGroup
            case editGroup
            case allMedia
            case pinConversation
            case disappearingMessages
            case notifications
            case deleteMessages
            case leaveGroup
            case blockUser
        }
        
        enum Style {
            case navigation
            case header
            case search
            case standard
        }
            
        let id: Id
        let style: Style
        let action: Action
        let icon: UIImage?
        let title: String
        let barButtonItem: UIBarButtonItem.SystemItem?
        let subtitle: String?
        let color: UIColor
        let accessibilityIdentifier: String?
        let isEnabled: Bool

        // Convenience
        
        init(
            id: Id,
            style: Style = .standard,
            action: Action = .nothing,
            icon: UIImage? = nil,
            title: String = "",
            barButtonItem: UIBarButtonItem.SystemItem? = nil,
            subtitle: String? = nil,
            color: UIColor = Colors.text,
            accessibilityIdentifier: String? = nil,
            isEnabled: Bool = true
        ) {
            self.id = id
            self.style = style
            self.action = action
            self.icon = icon
            self.title = title
            self.barButtonItem = barButtonItem
            self.subtitle = subtitle
            self.color = color
            self.accessibilityIdentifier = accessibilityIdentifier
            self.isEnabled = isEnabled
        }
        
        func with(
            icon: UIImage? = nil,
            title: String? = nil,
            subtitle: String? = nil,
            isEnabled: Bool? = nil
        ) -> Item {
            return Item(
                id: id,
                style: style,
                action: action,
                icon: (icon ?? self.icon),
                title: (title ?? self.title),
                barButtonItem: barButtonItem,
                subtitle: (subtitle ?? self.subtitle),
                color: color,
                accessibilityIdentifier: accessibilityIdentifier,
                isEnabled: (isEnabled ?? self.isEnabled)
            )
        }
    }
    
    // MARK: - Variables
    
    let thread: DynamicValue<TSThread>
    private let uiDatabaseConnection: YapDatabaseConnection
    private let didTriggerSearch: () -> ()
    private var disappearingMessageConfiguration: OWSDisappearingMessagesConfiguration?
    
    // MARK: - Initialization
    
    init(thread: TSThread, uiDatabaseConnection: YapDatabaseConnection, didTriggerSearch: @escaping () -> ()) {
        self.thread = DynamicValue(thread)
        self.uiDatabaseConnection = uiDatabaseConnection
        self.didTriggerSearch = didTriggerSearch
        
        // Need to setup interaction binding and load in initial data
        self.setupBinding()
        self.refreshAllData()
    }
    
    // MARK: - Content and Interactions
    
    lazy var title: String = {
        if thread.value is TSContactThread { return "vc_settings_title".localized() }

        return "vc_group_settings_title".localized()
    }()
    var threadName: String? { viewState[.header]?.title }
    
    lazy var items: DynamicValue<[[Item]]> = DynamicValue(generateItemSections())
    lazy var leftNavItems: DynamicValue<[Item]> = DynamicValue(generateLeftNavItems())
    lazy var rightNavItems: DynamicValue<[Item]> = DynamicValue(generateRightNavItems())
    
    lazy var interaction: InteractionManager<Action, (TSThread, OWSDisappearingMessagesConfiguration?, Any?)> = InteractionManager { [weak self] interactionData in
        guard let strongSelf: ConversationSettingsViewModel = self else { return nil }
        
        return (strongSelf.thread.value, strongSelf.disappearingMessageConfiguration, interactionData)
    }
    
    // MARK: - Internal State Management
    
    private var isEditingDisplayName: Bool = false
    private var editedDisplayName: String = ""
    
    private lazy var viewState: [Item.Id: Item] = {
        let groupThread: TSGroupThread? = (thread.value as? TSGroupThread)
        
        // Note: Any 'dynamic' data can just be omitted here as the 'refreshData' function will be called
        // on init to populate the correct values
        return [
            .navEdit: Item(
                id: .navEdit,
                style: .navigation,
                action: .startEditingDisplayName,
                barButtonItem: .edit,
                accessibilityIdentifier: "Edit button"
            ),
            
            .navCancel: Item(
                id: .navCancel,
                style: .navigation,
                action: .cancelEditingDisplayName,
                barButtonItem: .cancel,
                accessibilityIdentifier: "Cancel button"
            ),
            
            .navDone: Item(
                id: .navDone,
                style: .navigation,
                action: .saveUpdatedDisplayName,
                barButtonItem: .done,
                accessibilityIdentifier: "Done button"
            ),
            
            .header: Item(
                id: .header,
                style: .header,
                subtitle: (thread.value is TSGroupThread ? nil : (thread.value as? TSContactThread)?.contactSessionID())
            ),
            
            .search: Item(
                id: .search,
                style: .search,
                action: .search,
                icon: UIImage(named: "conversation_settings_search")?.withRenderingMode(.alwaysTemplate),
                title: "CONVERSATION_SETTINGS_SEARCH".localized(),
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).search"
            ),
            
            .addToGroup: Item(
                id: .addToGroup,
                action: .viewAddToGroup,
                icon: UIImage(named: "ic_plus_24")?.withRenderingMode(.alwaysTemplate),
                title: "vc_conversation_settings_invite_button_title".localized(),
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).edit_group"
            ),
            
            .editGroup: Item(
                id: .editGroup,
                action: .viewEditGroup,
                icon: UIImage(named: "table_ic_group_edit")?.withRenderingMode(.alwaysTemplate),
                title: "EDIT_GROUP_ACTION".localized(),
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).edit_group"
            ),
                
            .allMedia: Item(
                id: .allMedia,
                action: .viewAllMedia,
                icon: UIImage(named: "actionsheet_camera_roll_black")?.withRenderingMode(.alwaysTemplate),
                title: MediaStrings.allMedia,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).all_media"
            ),
            
            .pinConversation: Item(
                id: .pinConversation,
                action: .togglePinConversation,
                icon: UIImage(named: "settings_pin")?.withRenderingMode(.alwaysTemplate),
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).pin_conversation"
            ),
            
            .disappearingMessages: Item(
                id: .disappearingMessages,
                action: .viewDisappearingMessagesSettings,
                icon: UIImage(named: "timer_55")?.withRenderingMode(.alwaysTemplate),
                title: "DISAPPEARING_MESSAGES".localized(),
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).disappearing_messages"
            ),
            
            .notifications: Item(
                id: .notifications,
                action: (thread.value.isGroupThread() ?
                    .viewNotificationsSettings :
                    .toggleMuteNotifications
                ),
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).mute"
            ),
            
            .deleteMessages: Item(
                id: .deleteMessages,
                action: .deleteMessages,
                icon: UIImage(named: "trash")?.withRenderingMode(.alwaysTemplate),
                title: "DELETE_MESSAGES".localized(),
                color: Colors.destructive,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).delete_messages"
            ),
            
            .blockUser: Item(
                id: .blockUser,
                action: .toggleBlockUser,
                icon: UIImage(named: "table_ic_block")?.withRenderingMode(.alwaysTemplate),
                color: Colors.destructive,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).block"
            ),
            
            .leaveGroup: Item(
                id: .leaveGroup,
                action: .leaveGroup,
                icon: UIImage(named: "table_ic_group_leave")?.withRenderingMode(.alwaysTemplate),
                title: "LEAVE_GROUP_ACTION".localized(),
                color: Colors.destructive,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).leave_group"
            )
        ]
    }()
    
    private func generateItemSections() -> [[Item]] {
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
                viewState[.search]
            ].compactMap { $0 },
            
            // Main section
            [
                (isOpenGroup ? viewState[.addToGroup] : nil),
                (isClosedGroupAndMemeber ? viewState[.editGroup] : nil),
                viewState[.allMedia],
                viewState[.pinConversation],
                (!isOpenGroup ? viewState[.disappearingMessages] : nil),
                (!thread.value.isNoteToSelf() ? viewState[.notifications] : nil)
            ]
            .compactMap { $0 },
            
            // Destructive Actions
            [
                // TODO: Setup 'deleteMessages'
                viewState[.deleteMessages],
                (!thread.value.isNoteToSelf() && !thread.value.isGroupThread() ? viewState[.blockUser] : nil),
                (isClosedGroupAndMemeber ? viewState[.leaveGroup] : nil)
            ]
            .compactMap { $0 }
        ]
    }
    
    private func generateLeftNavItems() -> [Item] {
        guard isEditingDisplayName else { return [] }
        
        return [ viewState[.navCancel] ].compactMap { $0 }
    }
    
    private func generateRightNavItems() -> [Item] {
        guard isEditingDisplayName else {
            return [ viewState[.navEdit] ].compactMap { $0 }
        }
        
        return [ viewState[.navDone] ].compactMap { $0 }
    }
    
    private func setupBinding() {
        interaction.on(.startEditingDisplayName, forceToMainThread: false) { [weak self] thread, _, _ in
            guard thread is TSContactThread else { return }
            
            self?.isEditingDisplayName = true
            self?.editedDisplayName = (self?.viewState[.header]?.title ?? "")
            self?.leftNavItems.value = (self?.generateLeftNavItems() ?? [])
            self?.rightNavItems.value = (self?.generateRightNavItems() ?? [])
        }
        
        interaction.on(.changeDisplayName, forceToMainThread: false) { [weak self] thread, _, updatedNameValue in
            guard thread is TSContactThread else { return }
            guard let updatedName: String = updatedNameValue as? String else { return }
            
            self?.editedDisplayName = updatedName
        }
        
        interaction.on(.cancelEditingDisplayName, forceToMainThread: false) { [weak self] thread, _, _ in
            guard thread is TSContactThread else { return }
            
            self?.isEditingDisplayName = false
            self?.leftNavItems.value = (self?.generateLeftNavItems() ?? [])
            self?.rightNavItems.value = (self?.generateRightNavItems() ?? [])
        }
        
        interaction.on(.saveUpdatedDisplayName, forceToMainThread: false) { [weak self] thread, _, _ in
            guard let contactThread: TSContactThread = thread as? TSContactThread else { return }
            guard let editedDisplayName: String = self?.editedDisplayName else { return }
            
            self?.isEditingDisplayName = false
            self?.leftNavItems.value = (self?.generateLeftNavItems() ?? [])
            self?.rightNavItems.value = (self?.generateRightNavItems() ?? [])
            
            let sessionId: String = contactThread.contactSessionID()
            let contact: Contact = (Storage.shared.getContact(with: sessionId) ?? Contact(sessionID: sessionId))
            contact.nickname = (editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?
                nil :
                editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            
            Storage.write { transaction in
                Storage.shared.setContact(contact, using: transaction)
                
                self?.tryRefreshData(for: .header)
            }
        }
        
        interaction.on(.search, forceToMainThread: false) { [weak self] _, _, _ in
            // TODO: Refactor this to use the same setup as GlobalSearch when done
            self?.didTriggerSearch()
        }
        
        interaction.on(.addToGroupCompleted, forceToMainThread: false) { thread, _, selectedUsers in
            guard let threadId: String = thread.uniqueId else { return }
            guard let openGroup: OpenGroupV2 = Storage.shared.getV2OpenGroup(for: threadId) else { return }
            guard let selectedUsers: Set<String> = selectedUsers as? Set<String> else { return }
            
            let url = "\(openGroup.server)/\(openGroup.room)?public_key=\(openGroup.publicKey)"
            
            selectedUsers.forEach { user in
                let message: VisibleMessage = VisibleMessage()
                message.sentTimestamp = NSDate.millisecondTimestamp()
                message.openGroupInvitation = VisibleMessage.OpenGroupInvitation(name: openGroup.name, url: url)
                
                let thread: TSContactThread = TSContactThread.getOrCreateThread(contactSessionID: user)
                let tsMessage: TSOutgoingMessage = TSOutgoingMessage.from(message, associatedWith: thread)
                
                Storage.write { transaction in
                    tsMessage.save(with: transaction)
                }
                Storage.write { transaction in
                    MessageSender.send(message, in: thread, using: transaction)
                }
            }
        }
        
        interaction.on(.togglePinConversation, forceToMainThread: false) { [weak self] thread, _, _ in
            thread.isPinned = !thread.isPinned
            thread.save()
            
            self?.tryRefreshData(for: .pinConversation)
        }
        
        interaction.on(.toggleMuteNotifications, forceToMainThread: false) { [weak self] thread, _, _ in
            guard !thread.isNoteToSelf() && !thread.isGroupThread() else { return }
            
            Storage.write { transaction in
                thread.updateWithMuted(
                    until: (thread.isMuted ? nil : Date.distantFuture),
                    transaction: transaction
                )
                
                self?.tryRefreshData(for: .notifications)
            }
        }
        
        interaction.on(.leaveGroupConfirmed, forceToMainThread: false) { [weak self] thread, _, _ in
            guard let groupThread: TSGroupThread = thread as? TSGroupThread else { return }
            guard groupThread.isClosedGroup else { return }
            
            let groupPublicKey: String = LKGroupUtilities.getDecodedGroupID(groupThread.groupModel.groupId)
            
            Storage.write { transaction in
                MessageSender.leave(groupPublicKey, using: transaction).retainUntilComplete()
                
                // Need to refresh the screen as some settings might be disabled by this
                self?.refreshAllData()
                self?.interaction.trigger(.leaveGroupCompleted)
            }
        }
    }
    
    // MARK: - Functions
    
    private func refreshData(for itemId: Item.Id) {
        let groupThread: TSGroupThread? = (thread.value as? TSGroupThread)
        
        switch itemId {
            case .header:
                let updatedTitle: String
                
                if let contactThread: TSContactThread = thread.value as? TSContactThread {
                    updatedTitle = (Storage.shared.getContact(with: contactThread.contactSessionID())?.displayName(for: .regular) ?? "Anonymous")
                }
                else {
                    let threadName: String = thread.value.name()

                    updatedTitle = (threadName.count == 0 && thread.value is TSGroupThread ?
                        MessageStrings.newGroupDefaultTitle :
                        threadName
                    )
                }
                
                self.viewState[.header] = self.viewState[.header]?.with(
                    title: updatedTitle
                )
                
            case .editGroup:
                self.viewState[.editGroup] = self.viewState[.editGroup]?.with(
                    isEnabled: (groupThread?.isCurrentUserMemberInGroup() != false)
                )
                
            case .pinConversation:
                self.viewState[.pinConversation] = self.viewState[.pinConversation]?.with(
                    title: (thread.value.isPinned ?
                        "CONVERSATION_SETTINGS_UNPIN".localized() :
                        "CONVERSATION_SETTINGS_PIN".localized()
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
                        "DISAPPEARING_MESSAGES_OFF".localized()
                    ),
                    isEnabled: (groupThread?.isCurrentUserMemberInGroup() != false)
                )
                
            case .notifications:
                guard !thread.value.isNoteToSelf() && !thread.value.isGroupThread() else {
                    self.viewState[.notifications] = self.viewState[.notifications]?.with(
                        icon: UIImage(named: "unmute_unfilled")?.withRenderingMode(.alwaysTemplate),
                        title: "CONVERSATION_SETTINGS_MESSAGE_NOTIFICATIONS".localized(),
                        subtitle: (groupThread?.isMuted == true || groupThread?.isCurrentUserMemberInGroup() == false ?
                            "vc_conversation_notifications_settings_mute_title".localized() :
                            (groupThread?.isOnlyNotifyingForMentions == true ?
                                "vc_conversation_notifications_settings_mentions_only_title_short".localized() :
                                "vc_conversation_notifications_settings_all_title".localized()
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
                        "CONVERSATION_SETTINGS_UNMUTE_ACTION_NEW".localized() :
                        "CONVERSATION_SETTINGS_MUTE_ACTION_NEW".localized()
                    )
                )
                
            case .blockUser:
                guard !thread.value.isNoteToSelf() && !thread.value.isGroupThread() else { return }
                
                self.viewState[.blockUser] = self.viewState[.blockUser]?.with(
                    title: (OWSBlockingManager.shared().isThreadBlocked(thread.value) ?
                        "CONVERSATION_SETTINGS_UNBLOCK_USER".localized() :
                        "CONVERSATION_SETTINGS_BLOCK_USER".localized()
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
        items.value = generateItemSections()
    }
    
    func tryRefreshData(for itemId: Item.Id) {
        // Refresh the desired data and update the items
        refreshData(for: itemId)
        items.value = generateItemSections()
    }
}
