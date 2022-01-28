// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit

class ConversationSettingsViewModel {
    struct NavItem: Equatable {
        enum State {
            case standard
            case editing
        }
        
        let systemItem: UIBarButtonItem.SystemItem
        let accessibilityIdentifier: String
    }
    
    struct Item: Equatable {
        enum Id: CaseIterable {
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
            case header
            case search
            case standard
        }
            
        let id: Id
        let style: Style
        let icon: UIImage?
        let title: String
        let subtitle: String?
        let isEnabled: Bool
        let isEditing: Bool
        let isNegativeAction: Bool
        let accessibilityIdentifier: String?

        // Convenience
        
        init(
            id: Id,
            style: Style = .standard,
            icon: UIImage? = nil,
            title: String = "",
            subtitle: String? = nil,
            isEnabled: Bool = true,
            isEditing: Bool = false,
            isNegativeAction: Bool = false,
            accessibilityIdentifier: String? = nil
        ) {
            self.id = id
            self.style = style
            self.icon = icon
            self.title = title
            self.subtitle = subtitle
            self.isEnabled = isEnabled
            self.isEditing = isEditing
            self.isNegativeAction = isNegativeAction
            self.accessibilityIdentifier = accessibilityIdentifier
        }
    }
    
    struct ActionableItem<T> {
        let data: T
        let action: PassthroughSubject<Void, Never>?
        
        init(data: T, action: PassthroughSubject<Void, Never>? = nil) {
            self.data = data
            self.action = action
        }
    }
    
    enum NotificationState {
        case all
        case mentionsOnly
        case mute
    }
    
    // MARK: - Variables
    
    private let thread: TSThread
    private let uiDatabaseConnection: YapDatabaseConnection
    private let didTriggerSearch: () -> ()
    private let disappearingMessageConfiguration: OWSDisappearingMessagesConfiguration?
    
    // MARK: - Initialization
    
    init(thread: TSThread, uiDatabaseConnection: YapDatabaseConnection, didTriggerSearch: @escaping () -> ()) {
        self.thread = thread
        self.uiDatabaseConnection = uiDatabaseConnection
        self.didTriggerSearch = didTriggerSearch
        
        if let uniqueId: String = thread.uniqueId {
            if let config: OWSDisappearingMessagesConfiguration = OWSDisappearingMessagesConfiguration.fetch(uniqueId: uniqueId) {
                self.disappearingMessageConfiguration = config
            }
            else {
                self.disappearingMessageConfiguration = OWSDisappearingMessagesConfiguration(defaultWithThreadId: uniqueId)
            }
        }
        else {
            self.disappearingMessageConfiguration = nil
        }
    }
    
    // MARK: - Input
    
    @Published var displayName: String = ""
    
    let forceRefreshData: PassthroughSubject<Void, Never> = PassthroughSubject()
    
    let profilePictureTapped: PassthroughSubject<Void, Never> = PassthroughSubject()
    let editDisplayNameTapped: PassthroughSubject<Void, Never> = PassthroughSubject()
    let cancelEditDisplayNameTapped: PassthroughSubject<Void, Never> = PassthroughSubject()
    let saveDisplayNameTapped: PassthroughSubject<Void, Never> = PassthroughSubject()
    
    let searchTapped: PassthroughSubject<Void, Never> = PassthroughSubject()
    let addToGroupTapped: PassthroughSubject<Void, Never> = PassthroughSubject()
    let editGroupTapped: PassthroughSubject<Void, Never> = PassthroughSubject()
    let viewAllMediaTapped: PassthroughSubject<Void, Never> = PassthroughSubject()
    let pinConversationTapped: PassthroughSubject<Void, Never> = PassthroughSubject()
    let disappearingMessagesTapped: PassthroughSubject<Void, Never> = PassthroughSubject()
    let notificationsTapped: PassthroughSubject<Void, Never> = PassthroughSubject()
    
    let deleteMessagesTapped: PassthroughSubject<Void, Never> = PassthroughSubject()
    private let deleteMessagesStarted: PassthroughSubject<Void, Never> = PassthroughSubject()
    private let deleteMessagesCompleted: PassthroughSubject<Void, Never> = PassthroughSubject()
    let leaveGroupTapped: PassthroughSubject<Void, Never> = PassthroughSubject()
    private let leaveGroupStarted: PassthroughSubject<Void, Never> = PassthroughSubject()
    private let leaveGroupCompleted: PassthroughSubject<Void, Never> = PassthroughSubject()
    let blockTapped: PassthroughSubject<Void, Never> = PassthroughSubject()
    
    // MARK: - Content
    
    lazy var title: String = {
        if thread is TSContactThread { return "vc_settings_title".localized() }
        
        return "vc_group_settings_title".localized()
    }()
    
    lazy var profileContent: AnyPublisher<TSThread, Never> = {
        forceRefreshData
            .prepend(())
            .compactMap { [weak self] in self?.thread }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }()
    
    private var threadName: String {
        if let contactThread: TSContactThread = thread as? TSContactThread {
            return (
                Storage.shared.getContact(with: contactThread.contactSessionID())?
                    .displayName(for: .regular) ??
                "Anonymous"
            )
        }

        let threadName: String = thread.name()

        return (threadName.isEmpty && thread is TSGroupThread ?
            MessageStrings.newGroupDefaultTitle :
            threadName
        )
    }
    
    private lazy var navState: AnyPublisher<NavItem.State, Never> = {
        Publishers
            .MergeMany(
                editDisplayNameTapped
                    .map { _ in .editing }
                    .eraseToAnyPublisher(),
                cancelEditDisplayNameTapped
                    .map { _ in .standard }
                    .eraseToAnyPublisher(),
                saveDisplayNameTapped
                    .compactMap { [weak self] _ -> TSContactThread? in self?.thread as? TSContactThread }
                    .handleEvents(receiveOutput: { [weak self] contactThread in
                        guard let editedDisplayName: String = self?.displayName else { return }
                        
                        let sessionId: String = contactThread.contactSessionID()
                        let contact: Contact = (Storage.shared.getContact(with: sessionId) ?? Contact(sessionID: sessionId))
                        contact.nickname = (editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?
                            nil :
                            editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        
                        Storage.write { transaction in
                            Storage.shared.setContact(contact, using: transaction)
                        }
                    })
                    .map { _ in .standard }
                    .eraseToAnyPublisher()
            )
            .prepend(.standard)     // Initial value
            .eraseToAnyPublisher()
    }()
    
    lazy var leftNavItems: AnyPublisher<[ActionableItem<NavItem>], Never> = {
        return navState
            .map { [weak self] navState -> [ActionableItem<NavItem>] in
                // Only show the 'Edit' button if it's a contact thread
                guard self?.thread is TSContactThread else { return [] }
                guard navState == .editing else { return [] }
                
                return [
                    ActionableItem(
                        data: NavItem(
                            systemItem: .cancel,
                            accessibilityIdentifier: "Cancel button"
                        ),
                        action: self?.cancelEditDisplayNameTapped
                    )
                ]
            }
            .eraseToAnyPublisher()
    }()
    
    lazy var rightNavItems: AnyPublisher<[ActionableItem<NavItem>], Never> = {
        navState
            .map { [weak self] navState -> [ActionableItem<NavItem>] in
                // Only show the 'Edit' button if it's a contact thread
                guard self?.thread is TSContactThread else { return [] }
                
                switch navState {
                    case .editing:
                        return [
                            ActionableItem(
                                data: NavItem(
                                    systemItem: .done,
                                    accessibilityIdentifier: "Done button"
                                ),
                                action: self?.saveDisplayNameTapped
                            )
                        ]
                    
                    case .standard:
                        return [
                            ActionableItem(
                                data: NavItem(
                                    systemItem: .edit,
                                    accessibilityIdentifier: "Edit button"
                                ),
                                action: self?.editDisplayNameTapped
                            )
                        ]
                }
            }
            .eraseToAnyPublisher()
    }()
    
    private lazy var isPinned: AnyPublisher<Bool, Never> = {
        pinConversationTapped
            .handleEvents(receiveOutput: { [weak self] _ in
                guard let thread: TSThread = self?.thread else { return }
                
                thread.isPinned = !thread.isPinned
                thread.save()
            })
            .prepend(())    // Trigger an event to have an initial state
            .compactMap { [weak self] _ -> Bool? in self?.thread.isPinned }
            .eraseToAnyPublisher()
    }()
    
    private lazy var isGroupAndCurrentMember: AnyPublisher<Bool, Never> = {
        profileContent
            .map { thread -> Bool in
                guard let groupThread: TSGroupThread = thread as? TSGroupThread else { return false }

                return groupThread.isCurrentUserMemberInGroup()
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }()
    
    private lazy var notificationState: AnyPublisher<NotificationState, Never> = {
        Publishers
            .CombineLatest(
                notificationsTapped
                    .filter { [weak self] _ in self?.thread is TSContactThread }
                    .handleEvents(receiveOutput: { [weak self] _ in
                        guard let thread: TSThread = self?.thread else { return }
                        guard !thread.isNoteToSelf() && !thread.isGroupThread() else { return }
                        
                        Storage.write { transaction in
                            thread.updateWithMuted(
                                until: (thread.isMuted ? nil : Date.distantFuture),
                                transaction: transaction
                            )
                        }
                    })
                    .prepend(()),
                isGroupAndCurrentMember
            )
            .map { [weak self] _, isGroupAndCurrentMember -> NotificationState in
                guard let thread: TSThread = self?.thread else { return .mute }
                
                if let groupThread: TSGroupThread = thread as? TSGroupThread {
                    if thread.isMuted || !isGroupAndCurrentMember {
                        return .mute
                    }
                    else if groupThread.isOnlyNotifyingForMentions {
                        return .mentionsOnly
                    }
                    
                    return .all
                }
                
                return (thread.isMuted || thread.isNoteToSelf() ?
                    .mute :
                    .all
                )
            }
            .eraseToAnyPublisher()
    }()
    
    lazy var items: AnyPublisher<[[ActionableItem<Item>]], Never> = {
        Publishers
            .CombineLatest4(
                Publishers
                    .Merge(
                        // Thread state changes
                        forceRefreshData,
                        isPinned.mapToVoid()
                    ),
                navState,
                notificationState,
                Publishers
                    .CombineLatest(
                        // Store the initial state so we can ditinguish between sections which should
                        // be hidden vs shown in a disabled state
                        isGroupAndCurrentMember.first(),
                        // Note: This will be triggered on 'forceRefreshData' so we don't need to include
                        // that to trigger updates on view appearance
                        isGroupAndCurrentMember
                    )
                    .map { initialState, currentState -> (initialState: Bool, currentState: Bool) in
                        (initialState, currentState)
                    }
            )
            .map { [weak self] _, navState, notificationState, isGroupAndCurrentMember -> [[ActionableItem<Item>]] in
                guard let thread: TSThread = self?.thread else { return [] }
                
                let groupThread: TSGroupThread? = (thread as? TSGroupThread)
                let isOpenGroup: Bool = (groupThread != nil && groupThread?.isOpenGroup == true)
                let isClosedGroup: Bool = (groupThread != nil && groupThread?.isClosedGroup == true)
                let threadName: String = (self?.threadName ?? "Anonymous")
                
                // Generate the sections
                return [
                    // Header section
                    [
                        ActionableItem(
                            data: Item(
                                id: .header,
                                style: .header,
                                title: threadName,
                                subtitle: (self?.thread is TSGroupThread ?
                                    nil :
                                    (self?.thread as? TSContactThread)?.contactSessionID()
                                ),
                                isEditing: (navState == .editing)
                            )
                        )
                    ],
                    
                    // Search section
                    [
                        ActionableItem(
                            data: Item(
                                id: .search,
                                style: .search,
                                icon: UIImage(named: "conversation_settings_search")?
                                    .withRenderingMode(.alwaysTemplate),
                                title: "CONVERSATION_SETTINGS_SEARCH".localized(),
                                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).search"
                            ),
                            action: self?.searchTapped
                        )
                    ],
                    
                    // Main section
                    [
                        (!isOpenGroup ? nil :
                            ActionableItem(
                                data: Item(
                                    id: .addToGroup,
                                    icon: UIImage(named: "ic_plus_24")?
                                        .withRenderingMode(.alwaysTemplate),
                                    title: "vc_conversation_settings_invite_button_title".localized(),
                                    accessibilityIdentifier: "\(ConversationSettingsViewModel.self).edit_group"
                                ),
                                action: self?.addToGroupTapped
                            )
                        ),
                        
                        (!isClosedGroup || !isGroupAndCurrentMember.initialState ? nil :
                            ActionableItem(
                                data: Item(
                                    id: .editGroup,
                                    icon: UIImage(named: "table_ic_group_edit")?
                                        .withRenderingMode(.alwaysTemplate),
                                    title: "EDIT_GROUP_ACTION".localized(),
                                    isEnabled: isGroupAndCurrentMember.currentState,
                                    accessibilityIdentifier: "\(ConversationSettingsViewModel.self).edit_group"
                                ),
                                action: self?.editGroupTapped
                            )
                        ),
                        
                        ActionableItem(
                            data: Item(
                                id: .allMedia,
                                icon: UIImage(named: "actionsheet_camera_roll_black")?
                                    .withRenderingMode(.alwaysTemplate),
                                title: MediaStrings.allMedia,
                                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).all_media"
                            ),
                            action: self?.viewAllMediaTapped
                        ),
                        
                        ActionableItem(
                            data: Item(
                                id: .pinConversation,
                                icon: UIImage(named: "settings_pin")?
                                    .withRenderingMode(.alwaysTemplate),
                                title: (thread.isPinned ?
                                    "CONVERSATION_SETTINGS_UNPIN".localized() :
                                    "CONVERSATION_SETTINGS_PIN".localized()
                                ),
                                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).pin_conversation"
                            ),
                            action: self?.pinConversationTapped
                        ),
                        
                        (isOpenGroup ? nil :
                            ActionableItem(
                                data: Item(
                                    id: .disappearingMessages,
                                    icon: UIImage(named: "timer_55")?
                                        .withRenderingMode(.alwaysTemplate),
                                    title: "DISAPPEARING_MESSAGES".localized(),
                                    subtitle: {
                                        guard let config: OWSDisappearingMessagesConfiguration = self?.disappearingMessageConfiguration else {
                                            return "DISAPPEARING_MESSAGES_OFF".localized()
                                        }
                                        
                                        return (config.isEnabled ?
                                            config.shortDurationString :
                                            "DISAPPEARING_MESSAGES_OFF".localized()
                                        )
                                    }(),
                                    isEnabled: (!thread.isGroupThread() || isGroupAndCurrentMember.currentState),
                                    accessibilityIdentifier: "\(ConversationSettingsViewModel.self).disappearing_messages"
                                ),
                                action: self?.disappearingMessagesTapped
                            )
                        ),
                        
                        (thread.isNoteToSelf() ? nil :
                            ActionableItem(
                                data: Item(
                                    id: .notifications,
                                    icon: (thread.isMuted || thread.isGroupThread() ?
                                        UIImage(named: "unmute_unfilled")?.withRenderingMode(.alwaysTemplate) :
                                        UIImage(named: "mute_unfilled")?.withRenderingMode(.alwaysTemplate)
                                    ),
                                    title: (thread.isGroupThread() ?
                                        "CONVERSATION_SETTINGS_MESSAGE_NOTIFICATIONS".localized() :
                                        (thread.isMuted ?
                                            "CONVERSATION_SETTINGS_UNMUTE_ACTION_NEW".localized() :
                                            "CONVERSATION_SETTINGS_MUTE_ACTION_NEW".localized()
                                        )
                                    ),
                                    subtitle: (!thread.isGroupThread() ?
                                        nil :
                                        (thread.isMuted || !isGroupAndCurrentMember.currentState ?
                                            "vc_conversation_notifications_settings_mute_title".localized() :
                                            (groupThread?.isOnlyNotifyingForMentions == true ?
                                                "vc_conversation_notifications_settings_mentions_only_title_short".localized() :
                                                "vc_conversation_notifications_settings_all_title".localized()
                                            )
                                        )
                                    ),
                                    isEnabled: (!thread.isGroupThread() || isGroupAndCurrentMember.currentState),
                                    accessibilityIdentifier: "\(ConversationSettingsViewModel.self).mute"
                                ),
                                action: self?.notificationsTapped
                            )
                        )
                    ]
                    .compactMap { $0 },
                    
                    // Destructive Actions
                    [
                        ActionableItem(
                            data: Item(
                                id: .deleteMessages,
                                icon: UIImage(named: "trash")?
                                    .withRenderingMode(.alwaysTemplate),
                                title: "DELETE_MESSAGES".localized(),
                                isNegativeAction: true,
                                accessibilityIdentifier: "\(ConversationSettingsViewModel.self).delete_messages"
                            ),
                            action: self?.deleteMessagesTapped
                        ),
                        
                        (thread.isNoteToSelf() || thread.isGroupThread() ? nil :
                            ActionableItem(
                                data: Item(
                                    id: .blockUser,
                                    icon: UIImage(named: "table_ic_block")?
                                        .withRenderingMode(.alwaysTemplate),
                                    title: (OWSBlockingManager.shared().isThreadBlocked(thread) ?
                                        "CONVERSATION_SETTINGS_UNBLOCK_USER".localized() :
                                        "CONVERSATION_SETTINGS_BLOCK_USER".localized()
                                    ),
                                    isNegativeAction: true,
                                    accessibilityIdentifier: "\(ConversationSettingsViewModel.self).block"
                                ),
                                action: self?.blockTapped
                            )
                        ),
                        
                        (!isClosedGroup || !isGroupAndCurrentMember.initialState ? nil :
                            ActionableItem(
                                data: Item(
                                    id: .leaveGroup,
                                    icon: UIImage(named: "table_ic_group_leave")?
                                        .withRenderingMode(.alwaysTemplate),
                                    title: "LEAVE_GROUP_ACTION".localized(),
                                    isEnabled: isGroupAndCurrentMember.currentState,
                                    isNegativeAction: true,
                                    accessibilityIdentifier: "\(ConversationSettingsViewModel.self).leave_group"
                                ),
                                action: self?.leaveGroupTapped
                            )
                        )
                    ]
                    .compactMap { $0 }
                ]
            }
            .shareReplay(1)
            .eraseToAnyPublisher()
    }()
    
    lazy var loadingStateVisible: AnyPublisher<Bool, Never> = {
        Publishers
            .Merge4(
                deleteMessagesStarted.map { _ in true },
                leaveGroupStarted.map { _ in true },
                deleteMessagesCompleted.map { _ in false },
                leaveGroupCompleted.map { _ in false }
            )
            .prepend(false)     // Start with the loading hidden
            .removeDuplicates() // Only emit changes to the state
            .dropFirst()        // Ignore the first emission because the loading is hidden
            .eraseToAnyPublisher()
    }()
    
    // MARK: - Functions
    
    func addUsersToOpenGoup(selectedUsers: Set<String>) {
        guard let threadId: String = thread.uniqueId else { return }
        guard let openGroup: OpenGroupV2 = Storage.shared.getV2OpenGroup(for: threadId) else { return }
        
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
    
    func deleteMessages() {
        deleteMessagesStarted.send()
        
        Storage.write { [weak self] transaction in
            self?.thread.removeAllThreadInteractions(with: transaction)
            self?.deleteMessagesCompleted.send()
        }
    }
    
    func leaveGroup() {
        guard let groupThread: TSGroupThread = thread as? TSGroupThread else { return }
        guard groupThread.isClosedGroup else { return }
        
        let groupPublicKey: String = LKGroupUtilities.getDecodedGroupID(groupThread.groupModel.groupId)
        
        leaveGroupStarted.send()
        
        Storage.write { [weak self] transaction in
            MessageSender
                .leave(groupPublicKey, using: transaction)
                .done { _ in
                    self?.forceRefreshData.send()
                    self?.leaveGroupCompleted.send()
                }
                .retainUntilComplete()
        }
    }
    
    // MARK: - Transitions
    
    lazy var viewProfilePicture: AnyPublisher<(UIImage, String), Never> = {
        profilePictureTapped
            .compactMap { [weak self] _ -> UIImage? in
                guard let contactThread: TSContactThread = self?.thread as? TSContactThread else {
                    return nil
                }
                
                return OWSProfileManager.shared().profileAvatar(
                    forRecipientId: contactThread.contactSessionID()
                )
            }
            .compactMap { [weak self] profileImage -> (UIImage, String)? in
                guard let threadName: String = self?.threadName else { return nil }
                
                return (profileImage, threadName)
            }
            .eraseToAnyPublisher()
    }()
    
    lazy var viewSearch: AnyPublisher<Void, Never> = {
        searchTapped
            .handleEvents(receiveOutput: { [weak self] _ in
                // TODO: Refactor this to use the same setup as GlobalSearch when done
                self?.didTriggerSearch()
            })
            .eraseToAnyPublisher()
    }()
    
    lazy var viewAddToGroup: AnyPublisher<TSThread, Never> = {
        addToGroupTapped
            .compactMap { [weak self] _ -> TSThread? in self?.thread }
            .eraseToAnyPublisher()
    }()
    
    lazy var viewEditGroup: AnyPublisher<String, Never> = {
        editGroupTapped
            .compactMap { [weak self] _ -> String? in self?.thread.uniqueId }
            .eraseToAnyPublisher()
    }()
    
    lazy var viewAllMedia: AnyPublisher<TSThread, Never> = {
        viewAllMediaTapped
            .compactMap { [weak self] _ -> TSThread? in self?.thread }
            .eraseToAnyPublisher()
    }()
    
    lazy var viewDisappearingMessages: AnyPublisher<(TSThread, OWSDisappearingMessagesConfiguration), Never> = {
        disappearingMessagesTapped
            .compactMap { [weak self] _ -> (TSThread, OWSDisappearingMessagesConfiguration)? in
                guard let thread: TSThread = self?.thread else { return nil }
                guard let config: OWSDisappearingMessagesConfiguration = self?.disappearingMessageConfiguration else {
                    return nil
                }
                
                return (thread, config)
            }
            .eraseToAnyPublisher()
    }()
    
    lazy var viewNotificationSettings: AnyPublisher<TSGroupThread, Never> = {
        notificationsTapped
            .filter { [weak self] _ -> Bool in self?.thread.isGroupThread() == true }
            .compactMap { [weak self] _ -> TSGroupThread? in self?.thread as? TSGroupThread }
            .eraseToAnyPublisher()
    }()
    
    lazy var viewDeleteMessagesAlert: AnyPublisher<Void, Never> = {
        deleteMessagesTapped
            .eraseToAnyPublisher()
    }()
    
    lazy var viewLeaveGroupAlert: AnyPublisher<TSGroupThread, Never> = {
        leaveGroupTapped
            .compactMap { [weak self] _ -> TSGroupThread? in self?.thread as? TSGroupThread }
            .eraseToAnyPublisher()
    }()
    
    lazy var viewBlockUserAlert: AnyPublisher<TSThread, Never> = {
        blockTapped
            .compactMap { [weak self] _ -> TSThread? in self?.thread }
            .eraseToAnyPublisher()
    }()
}
