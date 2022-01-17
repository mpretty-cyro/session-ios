// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionMessagingKit

class ConversationSettingsViewModel {
    struct ConversationSettingsItem {
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
    
    let thread: TSThread
    private let uiDatabaseConnection: YapDatabaseConnection
    private var disappearingMessageConfiguration: OWSDisappearingMessagesConfiguration?
    
    private var transitionActions: [ConversationSettingsItem.Id: (TSThread, OWSDisappearingMessagesConfiguration?) -> ()] = [:]
    
    // MARK: - Initialization
    
    init(thread: TSThread, uiDatabaseConnection: YapDatabaseConnection) {
        self.thread = thread
        self.uiDatabaseConnection = uiDatabaseConnection
        
        if let uniqueId: String = thread.uniqueId {
            if let config: OWSDisappearingMessagesConfiguration = OWSDisappearingMessagesConfiguration.fetch(uniqueId: uniqueId) {
                self.disappearingMessageConfiguration = config
            }
            else {
                self.disappearingMessageConfiguration = OWSDisappearingMessagesConfiguration(defaultWithThreadId: uniqueId)
            }
        }
    }
    
    // MARK: - Data
    
    lazy var title: String = {
        if thread is TSContactThread {
            return NSLocalizedString("Settings", comment: "")
        }
        
        return NSLocalizedString("Group Settings", comment: "")
    }()
    
    lazy var items: [[ConversationSettingsItem]] = {
        let groupThread: TSGroupThread? = (thread as? TSGroupThread)
        
//        if (self.disappearingMessagesConfiguration.isEnabled) {
//            NSString *keepForFormat = @"Disappear after %@";
//            self.disappearingMessagesDurationLabel.text =
//                [NSString stringWithFormat:keepForFormat, self.disappearingMessagesConfiguration.durationString];
//        } else {
//            self.disappearingMessagesDurationLabel.text
//                = NSLocalizedString(@"KEEP_MESSAGES_FOREVER", @"Slider label when disappearing messages is off");
//        }
        //durationSeconds
        return [
            // Header section
            [
                ConversationSettingsItem(
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
                )
            ],
            
            // Search section
            [
                ConversationSettingsItem(
                    id: .search,
                    style: .search,
                    icon: UIImage(named: "conversation_settings_search")?.withRenderingMode(.alwaysTemplate),
                    title: NSLocalizedString("CONVERSATION_SETTINGS_SEARCH", comment: "label in conversation settings which returns the user to the conversation with 'search mode' activated"),
                    subtitle: nil,
                    accessibilityIdentifier: "\(ConversationSettingsViewModel.self).search"
                )
            ],
            
            // Main section
            [
                (groupThread == nil || groupThread?.isClosedGroup != true || groupThread?.isUserMember(inGroup: SNGeneralUtilities.getUserPublicKey()) != true ?
                    nil
                 :
                    ConversationSettingsItem(
                        id: .editGroup,
                        style: .action,
                        icon: UIImage(named: "table_ic_group_edit")?.withRenderingMode(.alwaysTemplate),
                        title: NSLocalizedString("EDIT_GROUP_ACTION", comment: "label in conversation settings"),
                        subtitle: nil,
                        accessibilityIdentifier: "\(ConversationSettingsViewModel.self).edit_group"
                        // TODO: Check this?
                        //            cell.userInteractionEnabled = !weakSelf.hasLeftGroup;
                    )
                ),
                ConversationSettingsItem(
                    id: .allMedia,
                    style: .action,
                    icon: UIImage(named: "actionsheet_camera_roll_black")?.withRenderingMode(.alwaysTemplate),
                    title: MediaStrings.allMedia,
                    subtitle: nil,
                    accessibilityIdentifier: "\(ConversationSettingsViewModel.self).all_media"
                ),
                ConversationSettingsItem(
                    id: .pinConversation,
                    style: .action,
                    icon: UIImage(named: "settings_pin")?.withRenderingMode(.alwaysTemplate),
                    title: NSLocalizedString("CONVERSATION_SETTINGS_PIN", comment: "label in conversation settings"),
                    subtitle: nil,
                    accessibilityIdentifier: "\(ConversationSettingsViewModel.self).pin_conversation"
                ),
                (groupThread != nil && groupThread?.isOpenGroup == true ?
                    nil
                 :
                    ConversationSettingsItem(
                        id: .disappearingMessages,
                        style: .action,
                        icon: UIImage(named: "timer_55")?.withRenderingMode(.alwaysTemplate),
                        title: NSLocalizedString("DISAPPEARING_MESSAGES", comment: "label in conversation settings"),
                        subtitle: (disappearingMessageConfiguration?.isEnabled == true ?
                            disappearingMessageConfiguration?.durationString :
                            NSLocalizedString("DISAPPEARING_MESSAGES_OFF", comment: "label in conversation settings")
                        ),
                        accessibilityIdentifier: "\(ConversationSettingsViewModel.self).disappearing_messages"
                    )
                ),
                ConversationSettingsItem(
                    id: .notifications,
                    style: .action,
                    icon: UIImage(named: "mute_unfilled")?.withRenderingMode(.alwaysTemplate),
                    title: NSLocalizedString("CONVERSATION_SETTINGS_MUTE_LABEL", comment: "label for 'mute thread' cell in conversation settings"),
                    subtitle: nil,
                    accessibilityIdentifier: "\(ConversationSettingsViewModel.self).mute"
                )
            ]
            .compactMap { $0 },
            
            // Destructive Actions
            [
//                (thread.isNoteToSelf() || thread as? TSContactThread == nil ?
//                    nil
//                 :
                    ConversationSettingsItem(
                        id: .deleteMessages,
                        style: .actionDestructive,
                        icon: UIImage(named: "trash")?.withRenderingMode(.alwaysTemplate),
                        title: NSLocalizedString("DELETE_MESSAGES", comment: "label in conversation settings"),
                        subtitle: nil,
                        accessibilityIdentifier: "\(ConversationSettingsViewModel.self).delete_messages"
                    ),
//                ),
                (thread.isNoteToSelf() || thread as? TSContactThread == nil ?
                    nil
                 :
                    ConversationSettingsItem(
                        id: .blockUser,
                        style: .actionDestructive,
                        icon: UIImage(named: "table_ic_block")?.withRenderingMode(.alwaysTemplate),
                        title: NSLocalizedString("CONVERSATION_SETTINGS_BLOCK_THIS_USER", comment: "label in conversation settings"),
                        subtitle: nil,
                        accessibilityIdentifier: "\(ConversationSettingsViewModel.self).block"
                    )
                ),
                // Leave Group (groups)
                (groupThread == nil || groupThread?.isClosedGroup != true || groupThread?.isUserMember(inGroup: SNGeneralUtilities.getUserPublicKey()) != true ?
                    nil
                 :
                    ConversationSettingsItem(
                        id: .editGroup,
                        style: .actionDestructive,
                        icon: UIImage(named: "table_ic_group_leave")?.withRenderingMode(.alwaysTemplate),
                        title: NSLocalizedString("LEAVE_GROUP_ACTION", comment: "label in conversation settings"),
                        subtitle: nil,
                        accessibilityIdentifier: "\(ConversationSettingsViewModel.self).leave_group"
                        // TODO: Check this?
                        //            cell.userInteractionEnabled = !weakSelf.hasLeftGroup;
                    )
                )
            ]
            .compactMap { $0 }
        ]
    }()
    
    // MARK: - Interactions
    
    func profilePictureTapped() {
        
    }
    
    func displayNameTapped() {
        
    }
    
    func itemTapped(_ itemId: ConversationSettingsItem.Id) {
        transitionActions[itemId]?(thread, disappearingMessageConfiguration)
    }
    
    // MARK: - Transitions
    
    /// Each item can only have a single action associated to it at a time
    func on(_ itemId: ConversationSettingsItem.Id, doAction action: @escaping (TSThread, OWSDisappearingMessagesConfiguration?) -> ()) {
        transitionActions[itemId] = action
    }
}
