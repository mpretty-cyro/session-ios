// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

class ThreadSettingsViewModel: SessionTableViewModel<ThreadSettingsViewModel.NavButton, ThreadSettingsViewModel.Section, ThreadSettingsViewModel.Setting> {
    // MARK: - Config
    
    enum NavState {
        case standard
        case editing
    }
    
    enum NavButton: Equatable {
        case edit
        case cancel
        case done
    }
    
    public enum Section: SessionTableSection {
        case conversationInfo
        case content
        case admin
        case destructive
        
        var title: String? {
            switch self {
                case .admin: return "ADMIN_SETTINGS".localized()
                default: return nil
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .admin: return .titleRoundedContent
                case .destructive: return .padding
                default: return .none
            }
        }
    }
    
    public enum Setting: Differentiable {
        case threadInfo
        
        case avatar
        case nickname
        case sessionId
        case groupDescription
        
        case copyThreadId
        case searchConversation
        case addToOpenGroup
        case groupMembers
        case allMedia
        case pinConversation
        case notifications
        
        case editGroup
        case addAdmins
        case disappearingMessages
        
        case clearMessages
        case leaveGroup
        case blockUser
        case delete
    }
    
    // MARK: - Variables
    
    private let dependencies: Dependencies
    private let threadId: String
    private let threadVariant: SessionThread.Variant
    private let didTriggerSearch: () -> ()
    private var oldDisplayName: String?
    private var editedDisplayName: String?
    
    // MARK: - Initialization
    
    init(
        dependencies: Dependencies = Dependencies(),
        threadId: String,
        threadVariant: SessionThread.Variant,
        didTriggerSearch: @escaping () -> ()
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.threadVariant = threadVariant
        self.didTriggerSearch = didTriggerSearch
        self.oldDisplayName = (threadVariant != .contact ?
            nil :
            dependencies.storage.read { db in
                try Profile
                    .filter(id: threadId)
                    .select(.nickname)
                    .asRequest(of: String.self)
                    .fetchOne(db)
            }
       )
    }
    
    // MARK: - Navigation
    
    lazy var navState: AnyPublisher<NavState, Never> = {
        Publishers
            .CombineLatest(
                isEditing
                    .map { isEditing in isEditing },
                textChanged
                    .handleEvents(
                        receiveOutput: { [weak self] value, _ in
                            self?.editedDisplayName = value
                        }
                    )
                    .filter { _ in false }
                    .prepend((nil, .nickname))
            )
            .map { isEditing, _ -> NavState in (isEditing ? .editing : .standard) }
            .removeDuplicates()
            .prepend(.standard)     // Initial value
            .eraseToAnyPublisher()
    }()

    override var leftNavItems: AnyPublisher<[NavItem]?, Never> {
       navState
           .map { [weak self] navState -> [NavItem] in
               // Only show the 'Edit' button if it's a contact thread
               guard self?.threadVariant == .contact else { return [] }
               guard navState == .editing else { return [] }

               return [
                   NavItem(
                       id: .cancel,
                       systemItem: .cancel,
                       accessibilityIdentifier: "Cancel button"
                   ) { [weak self] in
                       self?.setIsEditing(false)
                   }
               ]
           }
           .eraseToAnyPublisher()
    }

    override var rightNavItems: AnyPublisher<[NavItem]?, Never> {
       navState
           .map { [weak self, dependencies] navState -> [NavItem] in
               // Only show the 'Edit' button if it's a contact thread
               guard self?.threadVariant == .contact else { return [] }

               switch navState {
                   case .editing:
                       return [
                           NavItem(
                               id: .done,
                               systemItem: .done,
                               accessibilityIdentifier: "Done button"
                           ) { [weak self] in
                               self?.setIsEditing(false)
                               
                               guard
                                   self?.threadVariant == .contact,
                                   let threadId: String = self?.threadId,
                                   let editedDisplayName: String = self?.editedDisplayName
                               else { return }
                               
                               let updatedNickname: String = editedDisplayName
                                   .trimmingCharacters(in: .whitespacesAndNewlines)
                               self?.oldDisplayName = (updatedNickname.isEmpty ? nil : editedDisplayName)

                               dependencies.storage.writeAsync { db in
                                   try Profile
                                       .filter(id: threadId)
                                       .updateAll(
                                           db,
                                           Profile.Columns.nickname
                                               .set(to: (updatedNickname.isEmpty ? nil : editedDisplayName))
                                       )
                               }
                           }
                       ]

                   case .standard:
                       return [
                           NavItem(
                               id: .edit,
                               systemItem: .edit,
                               accessibilityIdentifier: "Edit button"
                           ) { [weak self] in
                               self?.textChanged(self?.oldDisplayName, for: .nickname)
                               self?.setIsEditing(true)
                           }
                       ]
               }
           }
           .eraseToAnyPublisher()
    }
    
    // MARK: - Content
    
    override var title: String {
        switch threadVariant {
            case .contact: return "vc_settings_title".localized()
            case .closedGroup, .openGroup: return "vc_group_settings_title".localized()
        }
    }
    
    public override var observableTableData: ObservableData { _observableTableData }
    
    /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
    /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
    ///
    /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
    /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
    /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
    /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
    private lazy var _observableTableData: ObservableData = ValueObservation
        .trackingConstantRegion { [weak self, dependencies, threadId = self.threadId, threadVariant = self.threadVariant] db -> [SectionModel] in
            let userPublicKey: String = getUserHexEncodedPublicKey(db, dependencies: dependencies)
            let maybeThreadViewModel: SessionThreadViewModel? = try SessionThreadViewModel
                .conversationSettingsQuery(threadId: threadId, userPublicKey: userPublicKey)
                .fetchOne(db)
            
            guard let threadViewModel: SessionThreadViewModel = maybeThreadViewModel else { return [] }
            
            // Additional Queries
            let fallbackSound: Preferences.Sound = db[.defaultNotificationSound]
                .defaulting(to: Preferences.Sound.defaultNotificationSound)
            let notificationSound: Preferences.Sound = try SessionThread
                .filter(id: threadId)
                .select(.notificationSound)
                .asRequest(of: Preferences.Sound.self)
                .fetchOne(db)
                .defaulting(to: fallbackSound)
            let disappearingMessagesConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
                .fetchOne(db, id: threadId)
                .defaulting(to: DisappearingMessagesConfiguration.defaultWith(threadId))
            let numGroupAdmins: Int = try GroupMember
                .filter(GroupMember.Columns.profileId == threadId)
                .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                .fetchCount(db)
            let currentUserIsClosedGroupMember: Bool = (
                threadVariant == .closedGroup &&
                threadViewModel.currentUserIsClosedGroupMember == true
            )
            let currentUserIsClosedGroupAdmin: Bool = (
                threadVariant == .closedGroup &&
                threadViewModel.currentUserIsClosedGroupAdmin == true
            )
            let hasClosedGroupDescription: Bool = (
                threadVariant == .closedGroup &&
                !(threadViewModel.closedGroup?.groupDescription ?? "").isEmpty
            )
            let canLeaveGroup: Bool = (
                !currentUserIsClosedGroupMember ||
                (currentUserIsClosedGroupAdmin && numGroupAdmins <= 1)
            )
            let editIcon: UIImage? = UIImage(named: "icon_edit")
            
            return [
                SectionModel(
                    model: .conversationInfo,
                    elements: [
                        SessionCell.Info(
                            id: .avatar,
                            accessory: .profile(
                                id: threadViewModel.id,
                                size: .extraLarge,
                                threadVariant: threadVariant,
                                customImageData: threadViewModel.openGroupProfilePictureData,
                                profile: threadViewModel.profile,
                                additionalProfile: threadViewModel.additionalProfile,
                                cornerIcon: nil
                            ),
                            styling: SessionCell.StyleInfo(
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                                backgroundStyle: .noBackground
                            ),
                            onTap: { self?.viewProfilePicture(threadViewModel: threadViewModel) }
                        ),
                        SessionCell.Info(
                            id: .nickname,
                            leftAccessory: (threadVariant != .contact ? nil :
                                .icon(
                                    editIcon?.withRenderingMode(.alwaysTemplate),
                                    size: .fit,
                                    customTint: .textSecondary
                                )
                            ),
                            title: SessionCell.TextInfo(
                                threadViewModel.displayName,
                                font: .titleLarge,
                                alignment: .center,
                                editingPlaceholder: "CONTACT_NICKNAME_PLACEHOLDER".localized(),
                                interaction: (threadVariant == .contact ? .editable : .none)
                            ),
                            styling: SessionCell.StyleInfo(
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(
                                    top: Values.smallSpacing,
                                    trailing: (threadVariant != .contact ?
                                        nil :
                                        -(((editIcon?.size.width ?? 0) + (Values.smallSpacing * 2)) / 2)
                                    ),
                                    bottom: (threadVariant != .contact && !hasClosedGroupDescription ?
                                        nil :
                                        Values.smallSpacing
                                    ),
                                    interItem: 0
                                ),
                                backgroundStyle: .noBackground
                            ),
                            onTap: {
                                self?.textChanged(self?.oldDisplayName, for: .nickname)
                                self?.setIsEditing(true)
                            }
                        ),
                        
                        (threadVariant != .contact ? nil :
                            SessionCell.Info(
                                id: .sessionId,
                                subtitle: SessionCell.TextInfo(
                                    threadViewModel.id,
                                    font: .monoSmall,
                                    alignment: .center,
                                    interaction: .copy
                                ),
                                styling: SessionCell.StyleInfo(
                                    customPadding: SessionCell.Padding(
                                        top: Values.smallSpacing,
                                        bottom: Values.largeSpacing
                                    ),
                                    backgroundStyle: .noBackground
                                )
                            )
                        ),
                        
                        (!hasClosedGroupDescription ? nil :
                            SessionCell.Info(
                                id: Setting.groupDescription,
                                title: SessionCell.TextInfo(
                                    (threadViewModel.closedGroup?.groupDescription ?? ""),
                                    font: .subtitle,
                                    alignment: .center
                                ),
                                styling: SessionCell.StyleInfo(
                                    tintColor: .textSecondary,
                                    customPadding: SessionCell.Padding(
                                        top: Values.smallSpacing,
                                        bottom: Values.largeSpacing
                                    ),
                                    backgroundStyle: .noBackground
                                )
                            )
                        )
                    ]
                    .compactMap { $0 }
                ),
                SectionModel(
                    model: .content,
                    elements: [
                        (threadVariant == .closedGroup ? nil :
                            SessionCell.Info(
                                id: .copyThreadId,
                                leftAccessory: .icon(
                                    UIImage(named: "ic_copy")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: (threadVariant == .openGroup ?
                                    "COPY_GROUP_URL".localized() :
                                    "vc_conversation_settings_copy_session_id_button_title".localized()
                                ),
                                accessibilityIdentifier: "\(ThreadSettingsViewModel.self).copy_thread_id",
                                onTap: {
                                    UIPasteboard.general.string = threadId
                                    self?.showToast(
                                        text: "copied".localized(),
                                        backgroundColor: .backgroundSecondary
                                    )
                                }
                            )
                        ),

                        SessionCell.Info(
                            id: .searchConversation,
                            leftAccessory: .icon(
                                UIImage(named: "conversation_settings_search")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "CONVERSATION_SETTINGS_SEARCH".localized(),
                            accessibilityIdentifier: "\(ThreadSettingsViewModel.self).search",
                            onTap: {
                                self?.didTriggerSearch()
                            }
                        ),

                        (threadVariant != .openGroup ? nil :
                            SessionCell.Info(
                                id: .addToOpenGroup,
                                leftAccessory: .icon(
                                    UIImage(named: "ic_plus_24")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "vc_conversation_settings_invite_button_title".localized(),
                                accessibilityIdentifier: "\(ThreadSettingsViewModel.self).add_to_open_group",
                                onTap: {
                                    self?.transitionToScreen(
                                        UserSelectionVC(
                                            with: "vc_conversation_settings_invite_button_title".localized(),
                                            excluding: Set()
                                        ) { [weak self] selectedUsers in
                                            self?.addUsersToOpenGoup(selectedUsers: selectedUsers)
                                        }
                                    )
                                }
                            )
                        ),

                        (!currentUserIsClosedGroupMember || currentUserIsClosedGroupAdmin ? nil :
                            SessionCell.Info(
                                id: .groupMembers,
                                leftAccessory: .icon(
                                    UIImage(named: "icon_group")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "GROUP_MEMBERS".localized(),
                                accessibilityIdentifier: "\(ThreadSettingsViewModel.self).group_members",
                                onTap: {
                                    self?.transitionToScreen(
                                        SessionTableViewController(
                                            viewModel: GroupMembersViewModel(
                                                dependencies: dependencies,
                                                threadId: threadId,
                                                variant: .list
                                            )
                                        )
                                    )
                                }
                            )
                        ),

                        SessionCell.Info(
                            id: .allMedia,
                            leftAccessory: .icon(
                                UIImage(named: "actionsheet_camera_roll_black")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: MediaStrings.allMedia,
                            accessibilityIdentifier: "\(ThreadSettingsViewModel.self).all_media",
                            onTap: {
                                self?.transitionToScreen(
                                    MediaGalleryViewModel.createAllMediaViewController(
                                        threadId: threadId,
                                        threadVariant: threadVariant,
                                        focusedAttachmentId: nil
                                    )
                                )
                            }
                        ),

                        SessionCell.Info(
                            id: .pinConversation,
                            leftAccessory: .icon(
                                UIImage(systemName: (threadViewModel.threadIsPinned ? "pin.slash" : "pin"))?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: (threadViewModel.threadIsPinned ?
                                "UNPIN_CONVERSATION".localized() :
                                "PIN_CONVERSATION".localized()
                            ),
                            accessibilityIdentifier: (threadViewModel.threadIsPinned ?
                                "\(ThreadSettingsViewModel.self).pin_conversation" :
                                "\(ThreadSettingsViewModel.self).unpin_conversation"
                            ),
                            onTap: {
                                dependencies.storage.writeAsync { db in
                                    try SessionThread
                                        .filter(id: threadId)
                                        .updateAll(
                                            db,
                                            SessionThread.Columns.isPinned
                                                .set(to: !threadViewModel.threadIsPinned)
                                        )
                                }
                            }
                        ),

                        (threadViewModel.threadIsNoteToSelf ? nil :
                            SessionCell.Info(
                                id: .notifications,
                                leftAccessory: .icon(
                                    UIImage(systemName: "speaker")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "NOTIFICATIONS_TITLE".localized(),
                                subtitle: String(
                                    format: "NOTIFICATIONS_SUBTITLE".localized(),
                                    threadViewModel.notificationOption.title
                                ),
                                isEnabled: (
                                    threadViewModel.threadVariant != .closedGroup ||
                                    currentUserIsClosedGroupMember
                                ),
                                accessibilityIdentifier: "\(ThreadSettingsViewModel.self).notifications",
                                onTap: {
                                    self?.transitionToScreen(
                                        SessionTableViewController(
                                            viewModel: ThreadNotificationSettingsViewModel(
                                                threadId: threadId,
                                                notificationOption: threadViewModel.notificationOption
                                            )
                                        )
                                    )
                                }
                            )
                        ),

                        (threadVariant != .contact || threadViewModel.threadIsBlocked == true ? nil :
                            SessionCell.Info(
                                id: .disappearingMessages,
                                leftAccessory: .icon(
                                    UIImage(named: "icon_disappearing_messages")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "DISAPPEARING_MESSAGES".localized(),
                                subtitle: (disappearingMessagesConfig.isEnabled ?
                                    String(
                                        format: "DISAPPEARING_MESSAGES_SUBTITLE_DISAPPEAR_AFTER".localized(),
                                        arguments: [disappearingMessagesConfig.durationString]
                                    ) :
                                    "DISAPPEARING_MESSAGES_SUBTITLE_OFF".localized()
                                ),
                                accessibilityIdentifier: "\(ThreadSettingsViewModel.self).disappearing_messages",
                                onTap: {
                                    self?.transitionToScreen(
                                        SessionTableViewController(
                                            viewModel: ThreadDisappearingMessagesSettingsViewModel(
                                                threadId: threadId,
                                                config: disappearingMessagesConfig
                                            )
                                        )
                                    )
                                }
                            )
                        )
                    ].compactMap { $0 }
                ),

                (threadVariant != .closedGroup || !currentUserIsClosedGroupAdmin ? nil :
                    SectionModel(
                        model: .admin,
                        elements: [
                            SessionCell.Info(
                                id: .editGroup,
                                leftAccessory: .icon(
                                    UIImage(named: "icon_group")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "EDIT_GROUP_ACTION".localized(),
                                accessibilityIdentifier: "\(ThreadSettingsViewModel.self).edit_group",
                                onTap: {
                                    self?.transitionToScreen(
                                        SessionTableViewController(
                                            viewModel: EditGroupViewModel(threadId: threadId)
                                        )
                                    )
                                }
                            ),

                            SessionCell.Info(
                                id: .addAdmins,
                                leftAccessory: .icon(
                                    UIImage(named: "icon_add_admins")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "ADD_ADMINS".localized(),
                                accessibilityIdentifier: "\(ThreadSettingsViewModel.self).add_admins",
                                onTap: {
                                    self?.transitionToScreen(
                                        SessionTableViewController(
                                            viewModel: GroupMembersViewModel(
                                                dependencies: dependencies,
                                                threadId: threadId,
                                                variant: .promote
                                            )
                                        )
                                    )
                                }
                            ),

                            SessionCell.Info(
                                id: .disappearingMessages,
                                leftAccessory: .icon(
                                    UIImage(named: "icon_disappearing_messages")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "DISAPPEARING_MESSAGES".localized(),
                                subtitle: (disappearingMessagesConfig.isEnabled ?
                                    String(
                                        format: "DISAPPEARING_MESSAGES_SUBTITLE_DISAPPEAR_AFTER".localized(),
                                        arguments: [disappearingMessagesConfig.durationString]
                                    ) :
                                    "DISAPPEARING_MESSAGES_SUBTITLE_OFF".localized()
                                ),
                                accessibilityIdentifier: "\(ThreadSettingsViewModel.self).disappearing_messages",
                                onTap: {
                                    self?.transitionToScreen(
                                        SessionTableViewController(
                                            viewModel: ThreadDisappearingMessagesSettingsViewModel(
                                                threadId: threadId,
                                                config: disappearingMessagesConfig
                                            )
                                        )
                                    )
                                }
                            )
                        ]
                    )
                ),
                        
                SectionModel(
                    model: .destructive,
                    elements: [
                        SessionCell.Info(
                            id: .clearMessages,
                            leftAccessory: .icon(
                                UIImage(named: "icon_clear_messages")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "CLEAR_MESSAGES".localized(),
                            styling: SessionCell.StyleInfo(tintColor: .danger),
                            accessibilityIdentifier: "\(ThreadSettingsViewModel.self).leave_group",
                            confirmationInfo: ConfirmationModal.Info(
                                title: "CLEAR_ALL_MESSAGES_TITLE".localized(),
                                explanation: (currentUserIsClosedGroupAdmin ?
                                    "CLEAR_ALL_MESSAGES_MESSAGE".localized() :
                                    "CLEAR_ALL_MESSAGES_MESSAGE_LOCAL".localized()
                                ),
                                confirmTitle: {
                                    guard currentUserIsClosedGroupAdmin else {
                                        return "CLEAR".localized()
                                    }
                                    
                                    return "DELETE_GROUP_ADMIN_DELETE_OPTION_ME".localized()
                                }(),
                                confirmStyle: (currentUserIsClosedGroupAdmin ? .alert_text : .danger),
                                cancelTitle: {
                                    guard currentUserIsClosedGroupAdmin else {
                                        return "TXT_CANCEL_TITLE".localized()
                                    }
                                    
                                    return "DELETE_GROUP_ADMIN_DELETE_OPTION_EVERYONE".localized()
                                }(),
                                cancelStyle: (currentUserIsClosedGroupAdmin ? .danger : .alert_text),
                                showCloseButton: currentUserIsClosedGroupAdmin,
                                onConfirm: { _ in
                                    self?.clearConversationMessages(threadId: threadId)
                                },
                                onCancel: { _ in
                                    guard currentUserIsClosedGroupAdmin else { return }
                                    
                                    self?.clearConversationMessagesForEveryone(
                                        threadId: threadId
                                    )
                                }
                            )
                        ),
                        
                        (canLeaveGroup ? nil :
                            SessionCell.Info(
                                id: .leaveGroup,
                                leftAccessory: .icon(
                                    UIImage(named: "icon_leave_group")?
                                        .withRenderingMode(.alwaysTemplate)
                                ),
                                title: "LEAVE_GROUP_ACTION".localized(),
                                styling: SessionCell.StyleInfo(tintColor: .danger),
                                accessibilityIdentifier: "\(ThreadSettingsViewModel.self).leave_group",
                                confirmationInfo: ConfirmationModal.Info(
                                    title: "CONFIRM_LEAVE_GROUP_TITLE".localized(),
                                    explanation: (currentUserIsClosedGroupAdmin ?
                                        "admin_group_leave_warning".localized() :
                                        "CONFIRM_LEAVE_GROUP_DESCRIPTION".localized()
                                    ),
                                    confirmTitle: "LEAVE_BUTTON_TITLE".localized(),
                                    confirmStyle: .danger,
                                    cancelStyle: .alert_text
                                ),
                                onTap: {
                                    dependencies.storage.writeAsync { db in
                                        try MessageSender.leave(db, groupPublicKey: threadId)
                                    }
                                }
                            )
                        ),
                        
                        (threadViewModel.threadIsNoteToSelf || threadVariant != .contact ? nil :
                            SessionCell.Info(
                                id: .blockUser,
                                leftAccessory: .toggle(
                                    .boolValue(threadViewModel.threadIsBlocked == true)
                                ),
                                title: "CONVERSATION_SETTINGS_BLOCK_THIS_USER".localized(),
                                styling: SessionCell.StyleInfo(tintColor: .danger),
                                accessibilityIdentifier: "\(ThreadSettingsViewModel.self).block",
                                confirmationInfo: ConfirmationModal.Info(
                                    title: {
                                        guard threadViewModel.threadIsBlocked == true else {
                                            return String(
                                                format: "BLOCK_LIST_BLOCK_USER_TITLE_FORMAT".localized(),
                                                threadViewModel.displayName
                                            )
                                        }
                                        
                                        return String(
                                            format: "BLOCK_LIST_UNBLOCK_TITLE_FORMAT".localized(),
                                            threadViewModel.displayName
                                        )
                                    }(),
                                    explanation: (threadViewModel.threadIsBlocked == true ?
                                        nil :
                                        "BLOCK_USER_BEHAVIOR_EXPLANATION".localized()
                                    ),
                                    confirmTitle: (threadViewModel.threadIsBlocked == true ?
                                        "BLOCK_LIST_UNBLOCK_BUTTON".localized() :
                                        "BLOCK_LIST_BLOCK_BUTTON".localized()
                                    ),
                                    confirmStyle: .danger,
                                    cancelStyle: .alert_text
                                ),
                                onTap: {
                                    let isBlocked: Bool = (threadViewModel.threadIsBlocked == true)
                                    
                                    self?.updateBlockedState(
                                        from: isBlocked,
                                        isBlocked: !isBlocked,
                                        threadId: threadId,
                                        displayName: threadViewModel.displayName
                                    )
                                }
                            )
                        ),
                        
                        SessionCell.Info(
                            id: .delete,
                            leftAccessory: .icon(
                                UIImage(named: "icon_bin")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: {
                                switch threadVariant {
                                    case .contact: return "TXT_DELETE_TITLE".localized()
                                    case .closedGroup: return "DELETE_GROUP".localized()
                                    case .openGroup: return "DELETE_COMMUNITY".localized()
                                }
                            }(),
                            styling: SessionCell.StyleInfo(tintColor: .danger),
                            accessibilityIdentifier: "\(ThreadSettingsViewModel.self).delete",
                            confirmationInfo: ConfirmationModal.Info(
                                title: {
                                    switch threadVariant {
                                        case .contact: return "TXT_DELETE_TITLE".localized()
                                        case .closedGroup: return "DELETE_GROUP".localized()
                                        case .openGroup: return "DELETE_COMMUNITY".localized()
                                    }
                                }(),
                                explanation: "DELETE_CONFIRMATION_MESSAGE".localized(),
                                confirmTitle: {
                                    guard currentUserIsClosedGroupAdmin else {
                                        return "TXT_DELETE_TITLE".localized()
                                    }
                                    
                                    return "DELETE_GROUP_ADMIN_DELETE_OPTION_ME".localized()
                                }(),
                                confirmStyle: (currentUserIsClosedGroupAdmin ? .alert_text : .danger),
                                cancelTitle: {
                                    guard currentUserIsClosedGroupAdmin else {
                                        return "TXT_CANCEL_TITLE".localized()
                                    }
                                    
                                    return "DELETE_GROUP_ADMIN_DELETE_OPTION_EVERYONE".localized()
                                }(),
                                cancelStyle: (currentUserIsClosedGroupAdmin ? .danger : .alert_text),
                                showCloseButton: currentUserIsClosedGroupAdmin,
                                onConfirm: { _ in
                                    self?.deleteConversation(threadId: threadId)
                                    self?.dismissScreen(type: .popToRoot)
                                },
                                onCancel: { _ in
                                    guard currentUserIsClosedGroupAdmin else { return }
                                    
                                    self?.deleteConversationForEveryone(threadId: threadId)
                                    self?.dismissScreen(type: .popToRoot)
                                }
                            )
                        )
                    ].compactMap { $0 }
                )
            ].compactMap { $0 }
        }
        .removeDuplicates()
        .publisher(in: dependencies.storage, scheduling: dependencies.scheduler)
        .mapToSessionTableViewData(for: self)
    
    // MARK: - Functions

    private func viewProfilePicture(threadViewModel: SessionThreadViewModel) {
        guard
            threadViewModel.threadVariant == .contact,
            let profile: Profile = threadViewModel.profile,
            let profileData: Data = ProfileManager.profileAvatar(profile: profile)
        else { return }
        
        let format: ImageFormat = profileData.guessedImageFormat
        let navController: UINavigationController = StyledNavigationController(
            rootViewController: ProfilePictureVC(
                image: (format == .gif || format == .webp ?
                    nil :
                    UIImage(data: profileData)
                ),
                animatedImage: (format != .gif && format != .webp ?
                    nil :
                    YYImage(data: profileData)
                ),
                title: threadViewModel.displayName
            )
        )
        navController.modalPresentationStyle = .fullScreen
        
        self.transitionToScreen(navController, transitionType: .present)
    }
    
    private func addUsersToOpenGoup(selectedUsers: Set<String>) {
        let threadId: String = self.threadId
        
        dependencies.storage.writeAsync { db in
            guard let openGroup: OpenGroup = try OpenGroup.fetchOne(db, id: threadId) else { return }
            
            let urlString: String = "\(openGroup.server)/\(openGroup.roomToken)?public_key=\(openGroup.publicKey)"
            
            try selectedUsers.forEach { userId in
                let thread: SessionThread = try SessionThread.fetchOrCreate(db, id: userId, variant: .contact)
                
                try LinkPreview(
                    url: urlString,
                    variant: .openGroupInvitation,
                    title: openGroup.name
                )
                .save(db)
                
                let interaction: Interaction = try Interaction(
                    threadId: thread.id,
                    authorId: userId,
                    variant: .standardOutgoing,
                    timestampMs: Int64(floor(Date().timeIntervalSince1970 * 1000)),
                    expiresInSeconds: try? DisappearingMessagesConfiguration
                        .select(.durationSeconds)
                        .filter(id: userId)
                        .filter(DisappearingMessagesConfiguration.Columns.isEnabled == true)
                        .asRequest(of: TimeInterval.self)
                        .fetchOne(db),
                    linkPreviewUrl: urlString
                )
                .inserted(db)
                
                try MessageSender.send(
                    db,
                    interaction: interaction,
                    in: thread
                )
            }
        }
    }
    
    private func updateBlockedState(
        from oldBlockedState: Bool,
        isBlocked: Bool,
        threadId: String,
        displayName: String
    ) {
        guard oldBlockedState != isBlocked else { return }
        
        dependencies.storage.writeAsync(
            updates: { db in
                try Contact
                    .fetchOrCreate(db, id: threadId)
                    .with(isBlocked: .updateTo(isBlocked))
                    .save(db)
            },
            completion: { [weak self] db, _ in
                try MessageSender.syncConfiguration(db, forceSyncNow: true).retainUntilComplete()
                
                DispatchQueue.main.async {
                    let modal: ConfirmationModal = ConfirmationModal(
                        info: ConfirmationModal.Info(
                            title: (oldBlockedState == false ?
                                "BLOCK_LIST_VIEW_BLOCKED_ALERT_TITLE".localized() :
                                String(
                                    format: "BLOCK_LIST_VIEW_UNBLOCKED_ALERT_TITLE_FORMAT".localized(),
                                    displayName
                                )
                            ),
                            explanation: (oldBlockedState == false ?
                                String(
                                    format: "BLOCK_LIST_VIEW_BLOCKED_ALERT_MESSAGE_FORMAT".localized(),
                                    displayName
                                ) :
                                nil
                            ),
                            cancelTitle: "BUTTON_OK".localized(),
                            cancelStyle: .alert_text
                        )
                    )
                    
                    self?.transitionToScreen(modal, transitionType: .present)
                }
            }
        )
    }
                    
    private func clearConversationMessagesForEveryone(threadId: String) {
        self.clearConversationMessages(threadId: threadId)
    }
                    
    private func clearConversationMessages(threadId: String) {
        dependencies.storage.writeAsync { db in
            try Interaction
                .filter(Interaction.Columns.threadId == threadId)
                .deleteAll(db)
        }
    }
                    
    private func deleteConversationForEveryone(threadId: String) {
        self.deleteConversation(threadId: threadId)
    }
                    
    private func deleteConversation(threadId: String) {
        dependencies.storage.writeAsync { db in
            try SessionThread
                .filter(id: threadId)
                .deleteAll(db)
        }
    }
}
