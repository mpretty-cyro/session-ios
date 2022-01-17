// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionMessagingKit

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
        
        // Convenience
        
        func with(subtitle: String?) -> Item {
            return Item(
                id: id,
                style: style,
                icon: icon,
                title: title,
                subtitle: subtitle,
                accessibilityIdentifier: accessibilityIdentifier
            )
        }
    }
    
//    enum ConversationSettingsItemType: CaseIterable {
//        case header
//        case search
//        case editGroup
//        case allMedia
//        case pinConversation
//        case disappearingMessages
//        case notifications
//        case deleteMessages
//        case leaveGroup
//        case blockUser
//
//        var isVisible: Bool {
//            return true
//        }
//
//        var section: Int {
//            switch self {
//                case .header: return 0
//                case .search: return 1
//                case .deleteMessages, .leaveGroup, .blockUser: return 3
//
//                default: return 2
//            }
//        }
//
//        var style: ConversationSettingsItemStyle {
//            switch self {
//                case .header: return .header
//                default: return .action
//            }
//        }
//
//        var icon: UIImage? {
//            return nil
//        }
//
//        func title(with thread: TSThread) -> String {
//            switch self {
//                case .header:
//                    if let contactThread: TSContactThread = thread as? TSContactThread {
//                        return (Storage.shared.getContact(with: contactThread.contactSessionID())?.displayName(for: .regular) ?? "Anonymous")
//                    }
//
//                    let threadName: String = thread.name()
//
//                    return (threadName.count == 0 && thread is TSGroupThread ?
//                        MessageStrings.newGroupDefaultTitle :
//                        threadName
//                    )
//
//                default: return ""
//            }
//        }
//
//        var subtitle: String? {
//            return ""
//        }
//    }
    
    // MARK: - Properties
    
    private let thread: TSThread
    private let uiDatabaseConnection: YapDatabaseConnection
    private var disappearingMessageConfiguration: OWSDisappearingMessagesConfiguration?
    
    var onItemsChanged: ((TSThread, [[Item]]) -> ())? {
        didSet {
            onItemsChanged?(thread, generateItemsArray())
        }
    }
    
    private var transitionActions: [Item.Id: (TSThread, OWSDisappearingMessagesConfiguration?) -> ()] = [:]
    
    // MARK: - Initialization
    
    init(thread: TSThread, uiDatabaseConnection: YapDatabaseConnection) {
        self.thread = thread
        self.uiDatabaseConnection = uiDatabaseConnection
        
        // Need to load in initial data
        self.tryRefreshData(for: .disappearingMessages)
    }
    
    // MARK: - Data
    
    lazy var title: String = {
        if thread is TSContactThread {
            return NSLocalizedString("Settings", comment: "")
        }
        
        return NSLocalizedString("Group Settings", comment: "")
    }()
    
    private lazy var dataStore: [Item.Id: Item] = {
        let groupThread: TSGroupThread? = (thread as? TSGroupThread)
        
        return [
            .header: Item(
                id: .header,
                style: .header,
                icon: nil,
                title: {
                    if let contactThread: TSContactThread = thread as? TSContactThread {
                        return (Storage.shared.getContact(with: contactThread.contactSessionID())?.displayName(for: .regular) ?? "Anonymous")
                    }

                    let threadName: String = thread.name()

                    return (threadName.count == 0 && thread is TSGroupThread ?
                        MessageStrings.newGroupDefaultTitle :
                        threadName
                    )
                }(),
                subtitle: (thread is TSGroupThread ? nil : (thread as? TSContactThread)?.contactSessionID()),
                accessibilityIdentifier: nil
            ),
            
            .search: Item(
                id: .search,
                style: .search,
                icon: UIImage(named: "conversation_settings_search")?.withRenderingMode(.alwaysTemplate),
                title: NSLocalizedString("CONVERSATION_SETTINGS_SEARCH", comment: "label in conversation settings which returns the user to the conversation with 'search mode' activated"),
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).search"
            ),
            
            .editGroup: Item(
                id: .editGroup,
                style: .action,
                icon: UIImage(named: "table_ic_group_edit")?.withRenderingMode(.alwaysTemplate),
                title: NSLocalizedString("EDIT_GROUP_ACTION", comment: "label in conversation settings"),
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).edit_group"
                // TODO: Check this?
                //            cell.userInteractionEnabled = !weakSelf.hasLeftGroup;
            ),
                
            .allMedia: Item(
                id: .allMedia,
                style: .action,
                icon: UIImage(named: "actionsheet_camera_roll_black")?.withRenderingMode(.alwaysTemplate),
                title: MediaStrings.allMedia,
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).all_media"
            ),
            
            .pinConversation: Item(
                id: .pinConversation,
                style: .action,
                icon: UIImage(named: "settings_pin")?.withRenderingMode(.alwaysTemplate),
                title: NSLocalizedString("CONVERSATION_SETTINGS_PIN", comment: "label in conversation settings"),
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).pin_conversation"
            ),
            
            .disappearingMessages: Item(
                id: .disappearingMessages,
                style: .action,
                icon: UIImage(named: "timer_55")?.withRenderingMode(.alwaysTemplate),
                title: NSLocalizedString("DISAPPEARING_MESSAGES", comment: "label in conversation settings"),
                subtitle: (disappearingMessageConfiguration?.isEnabled == true ?
                    disappearingMessageConfiguration?.shortDurationString :
                    NSLocalizedString("DISAPPEARING_MESSAGES_OFF", comment: "label in conversation settings")
                ),
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).disappearing_messages"
            ),
            
            .notifications: Item(
                id: .notifications,
                style: .action,
                icon: UIImage(named: "mute_unfilled")?.withRenderingMode(.alwaysTemplate),
                title: NSLocalizedString("CONVERSATION_SETTINGS_MUTE_LABEL", comment: "label for 'mute thread' cell in conversation settings"),
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).mute"
            ),
            
            .deleteMessages: Item(
                id: .deleteMessages,
                style: .actionDestructive,
                icon: UIImage(named: "trash")?.withRenderingMode(.alwaysTemplate),
                title: NSLocalizedString("DELETE_MESSAGES", comment: "label in conversation settings"),
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).delete_messages"
            ),
            
            .blockUser: Item(
                id: .blockUser,
                style: .actionDestructive,
                icon: UIImage(named: "table_ic_block")?.withRenderingMode(.alwaysTemplate),
                title: NSLocalizedString("CONVERSATION_SETTINGS_BLOCK_THIS_USER", comment: "label in conversation settings"),
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).block"
            ),
            
            .leaveGroup: Item(
                id: .editGroup,
                style: .actionDestructive,
                icon: UIImage(named: "table_ic_group_leave")?.withRenderingMode(.alwaysTemplate),
                title: NSLocalizedString("LEAVE_GROUP_ACTION", comment: "label in conversation settings"),
                subtitle: nil,
                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).leave_group"
                // TODO: Check this?
                //            cell.userInteractionEnabled = !weakSelf.hasLeftGroup;
            )
        ]
    }()
    
    private func generateItemsArray() -> [[Item]] {
        let groupThread: TSGroupThread? = (thread as? TSGroupThread)
        let isClosedGroupAndMemeber: Bool = (groupThread != nil && groupThread?.isClosedGroup == true && groupThread?.isUserMember(inGroup: SNGeneralUtilities.getUserPublicKey()) == true)
        let isOpenGroup: Bool = (groupThread != nil && groupThread?.isOpenGroup == true)
        
        return [
            // Header section
            [
                dataStore[.header]
            ].compactMap { $0 },
            
            // Search section
            [
                dataStore[.search]
            ].compactMap { $0 },
            
            // Main section
            [
                (isClosedGroupAndMemeber ? dataStore[.editGroup] : nil),
                dataStore[.allMedia],
                dataStore[.pinConversation],
                (!isOpenGroup ? dataStore[.disappearingMessages] : nil),
                dataStore[.notifications]
            ]
            .compactMap { $0 },
            
            // Destructive Actions
            [
//                (thread.isNoteToSelf() || thread as? TSContactThread == nil ?
//                    nil
//                 :
                dataStore[.deleteMessages],
//                ),
                (thread.isNoteToSelf() || thread as? TSContactThread == nil ? nil : dataStore[.blockUser]),
                // Leave Group (groups)
                (isClosedGroupAndMemeber ? dataStore[.leaveGroup] : nil)
            ]
            .compactMap { $0 }
        ]
    }
    
    // MARK: - Functions
    
    func tryRefreshData(for itemId: Item.Id) {
        switch itemId {
            case .disappearingMessages:
                guard let uniqueId: String = thread.uniqueId else { return }
                
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
                self.dataStore[.disappearingMessages] = self.dataStore[.disappearingMessages]?.with(
                    subtitle: (targetConfig.isEnabled ?
                        targetConfig.shortDurationString :
                        NSLocalizedString("DISAPPEARING_MESSAGES_OFF", comment: "label in conversation settings")
                    )
                )
        
            // Data cannot be updated so don't make any changes
            default: return
        }
    
        // Announce the update
        onItemsChanged?(thread, generateItemsArray())
    }
    
    func profilePictureTapped() {
        
    }
    
    func displayNameTapped() {
        
    }
    
    func itemTapped(_ itemId: Item.Id) {
        transitionActions[itemId]?(thread, disappearingMessageConfiguration)
    }
    
    // MARK: - Transitions
    
    /// Each item can only have a single action associated to it at a time
    func on(_ itemId: Item.Id, doAction action: @escaping (TSThread, OWSDisappearingMessagesConfiguration?) -> ()) {
        transitionActions[itemId] = action
    }
}
