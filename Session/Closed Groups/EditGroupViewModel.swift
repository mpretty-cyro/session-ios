// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

class EditGroupViewModel: SessionTableViewModel<EditGroupViewModel.NavButton, EditGroupViewModel.Section, EditGroupViewModel.Setting> {
    // MARK: - Config
    
    enum NavState {
        case standard
        case editing
    }
    
    enum NavButton: Equatable {
        case cancel
        case done
    }
    
    public enum Section: SessionTableSection {
        case conversationInfo
        case invite
        case members
        
        var title: String? {
            switch self {
                case .members: return "GROUP_MEMBERS".localized()
                default: return nil
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .members: return .titleRoundedContent
                default: return .none
            }
        }
    }
    
    public enum Setting: Equatable, Hashable, Differentiable {
        case avatar
        case groupName
        case groupDescription
        
        case inviteContacts
        case member(Profile)
    }
    
    // MARK: - Variables
    
    private let dependencies: Dependencies
    private let threadId: String
    private var oldGroupName: String?
    private var editedGroupName: String?
    private var oldGroupDescription: String?
    private var editedGroupDescription: String?
    
    // MARK: - Initialization
    
    init(
        dependencies: Dependencies = Dependencies(),
        threadId: String
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        
        struct GroupInfo: FetchableRecord, Decodable {
            let name: String
            let groupDescription: String?
        }
        let groupInfo: GroupInfo? = dependencies.storage.read { db in
            try ClosedGroup
                .filter(id: threadId)
                .select(.name, .groupDescription)
                .asRequest(of: GroupInfo.self)
                .fetchOne(db)
        }
        
        self.oldGroupName = groupInfo?.name
        self.oldGroupDescription = groupInfo?.groupDescription
    }
    
    // MARK: - Navigation
    
    lazy var navState: AnyPublisher<NavState, Never> = {
        Publishers
            .CombineLatest(
                isEditing,
                textChanged
                    .handleEvents(
                        receiveOutput: { [weak self] value, item in
                            switch item {
                                case .groupName: self?.editedGroupName = value
                                case .groupDescription: self?.editedGroupDescription = value
                                default: break
                            }
                        }
                    )
                    .filter { _ in false }
                    .prepend((nil, .groupName))
            )
            .map { isEditing, _ -> NavState in (isEditing ? .editing : .standard) }
            .removeDuplicates()
            .prepend(.standard)     // Initial value
            .eraseToAnyPublisher()
    }()

    override var leftNavItems: AnyPublisher<[NavItem]?, Never> {
       navState
           .map { [weak self] navState -> [NavItem] in
               guard navState == .editing else { return [] }

               return [
                   NavItem(
                       id: .cancel,
                       systemItem: .cancel,
                       accessibilityIdentifier: "Cancel button"
                   ) { [weak self] in
                       self?.setIsEditing(false)
                       self?.editedGroupName = self?.oldGroupName
                       self?.editedGroupDescription = self?.oldGroupDescription
                   }
               ]
           }
           .eraseToAnyPublisher()
    }

    override var rightNavItems: AnyPublisher<[NavItem]?, Never> {
       navState
           .map { [weak self, dependencies] navState -> [NavItem] in
               switch navState {
                   case .standard: return []
                   
                   case .editing:
                       return [
                           NavItem(
                               id: .done,
                               systemItem: .done,
                               accessibilityIdentifier: "Done button"
                           ) { [weak self] in
                               self?.setIsEditing(false)
                               
                               // Sanitise the values
                               let updatedGroupName: String = (self?.editedGroupName ?? self?.oldGroupName)
                                   .defaulting(to: "")
                                   .trimmingCharacters(in: .whitespacesAndNewlines)
                               let updatedGroupDescription: String = (self?.editedGroupDescription ?? self?.oldGroupDescription)
                                   .defaulting(to: "")
                                   .trimmingCharacters(in: .whitespacesAndNewlines)
                               
                               guard
                                   let threadId: String = self?.threadId,
                                   let oldGroupName: String = self?.oldGroupName,
                                   (
                                       oldGroupName != updatedGroupName ||
                                       self?.oldGroupDescription != self?.editedGroupDescription
                                   )
                               else { return }
                               
                               // A group must always have a group name
                               guard !updatedGroupName.isEmpty else {
                                   self?.transitionToScreen(
                                       ConfirmationModal(
                                           info: ConfirmationModal.Info(
                                               title: "vc_create_closed_group_group_name_missing_error".localized(),
                                               cancelTitle: "BUTTON_OK".localized(),
                                               cancelStyle: .alert_text
                                           )
                                       ),
                                       transitionType: .present
                                   )
                                   return
                               }
                               guard updatedGroupName.count <= ClosedGroup.maxNameLength else {
                                   self?.transitionToScreen(
                                       ConfirmationModal(
                                           info: ConfirmationModal.Info(
                                               title: "vc_create_closed_group_group_name_too_long_error".localized(),
                                               cancelTitle: "BUTTON_OK".localized(),
                                               cancelStyle: .alert_text
                                           )
                                       ),
                                       transitionType: .present
                                   )
                                   return
                               }
                               
                               self?.oldGroupName = updatedGroupName
                               self?.oldGroupDescription = updatedGroupDescription
                               
                               dependencies.storage.writeAsync { db in
                                   try ClosedGroup
                                       .filter(id: threadId)
                                       .updateAll(
                                           db,
                                           ClosedGroup.Columns.name.set(to: updatedGroupName),
                                           ClosedGroup.Columns.groupDescription
                                               .set(to: (updatedGroupDescription.isEmpty ? nil : updatedGroupDescription))
                                       )
                               }
                           }
                       ]
               }
           }
           .eraseToAnyPublisher()
    }
    
    // MARK: - Content
    
    override var title: String { return "EDIT_GROUP_ACTION".localized() }
    
    private let selectedContactIdsSubject: CurrentValueSubject<Set<String>, Never> = CurrentValueSubject([])
    public override var observableTableData: ObservableData { _observableTableData }
    
    /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
    /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
    ///
    /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
    /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
    /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
    /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
    private lazy var _observableTableData: ObservableData = ValueObservation
        .trackingConstantRegion { [weak self, dependencies, threadId = self.threadId] db -> [SectionModel] in
            let userPublicKey: String = getUserHexEncodedPublicKey(db, dependencies: dependencies)
            let maybeThreadViewModel: SessionThreadViewModel? = try SessionThreadViewModel
                .conversationSettingsQuery(threadId: threadId, userPublicKey: userPublicKey)
                .fetchOne(db)
            
            guard let threadViewModel: SessionThreadViewModel = maybeThreadViewModel else { return [] }
            
            let currentUserIsClosedGroupMember: Bool = (
                threadViewModel.currentUserIsClosedGroupMember == true
            )
            let currentUserIsClosedGroupAdmin: Bool = (
                threadViewModel.currentUserIsClosedGroupAdmin == true
            )
            let userProfile: Profile = Profile.fetchOrCreate(db, id: userPublicKey)
            let contactsInGroup: Set<String> = (try? GroupMember
                .filter(GroupMember.Columns.groupId == threadId)
                .select(.profileId)
                .asRequest(of: String.self)
                .fetchSet(db))
                .defaulting(to: [])
            let closedGroupUserProfiles: [Profile] = (try? Profile
                .filter(ids: contactsInGroup.removing(userPublicKey))
                .fetchAll(db))
                .defaulting(to: [])
                .sorted(by: { lhs, rhs -> Bool in lhs.displayName() < rhs.displayName() })
            
            // Ensure the current user profile is always at the top and add any users we
            // don't have profile info for at the bottom
            let allMembers: [Profile] = [userProfile]
                .appending(contentsOf: closedGroupUserProfiles)
                .appending(
                    contentsOf: contactsInGroup
                        .removing(userPublicKey)
                        .subtracting(closedGroupUserProfiles.map { $0.id }.asSet())
                        .map { Profile(id: $0, name: "") }
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
                                size: .veryLarge,
                                profile: threadViewModel.profile,
                                additionalProfile: threadViewModel.additionalProfile,
                                threadVariant: .closedGroup,
                                openGroupProfilePictureData: nil,
                                useFallbackPicture: false,
                                showMultiAvatarForClosedGroup: true
                            ),
                            styling: SessionCell.StyleInfo(
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                                backgroundStyle: .noBackground
                            ),
                            onTap: {
                                // TODO: avatarTapped
                            }
                        ),
                        SessionCell.Info(
                            id: .groupName,
                            leftAccessory: .icon(
                                editIcon?.withRenderingMode(.alwaysTemplate),
                                size: .fit,
                                customTint: .textSecondary
                            ),
                            title: SessionCell.TextInfo(
                                threadViewModel.displayName,
                                font: .titleLarge,
                                alignment: .center,
                                editingPlaceholder: "vc_create_closed_group_text_field_hint".localized(),
                                interaction: .editable
                            ),
                            styling: SessionCell.StyleInfo(
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(
                                    top: Values.smallSpacing,
                                    trailing: -(((editIcon?.size.width ?? 0) + (Values.smallSpacing * 2)) / 2),
                                    bottom: Values.smallSpacing,
                                    interItem: 0
                                ),
                                backgroundStyle: .noBackground
                            ),
                            onTap: { [weak self] in self?.setIsEditing(true) }
                        ),
                        SessionCell.Info(
                            id: .groupDescription,
                            title: SessionCell.TextInfo(
                                (threadViewModel.closedGroupDescription ?? ""),
                                font: .subtitle,
                                alignment: .center,
                                editingPlaceholder: "GROUP_DESCRIPTION_PLACEHOLDER".localized(),
                                interaction: .editable
                            ),
                            styling: SessionCell.StyleInfo(
                                tintColor: .textSecondary,
                                customPadding: SessionCell.Padding(top: Values.smallSpacing),
                                backgroundStyle: .noBackground
                            ),
                            onTap: { [weak self] in self?.setIsEditing(true) }
                        )
                    ]
                ),
                SectionModel(
                    model: .invite,
                    elements: [
                        SessionCell.Info(
                            id: .inviteContacts,
                            leftAccessory: .icon(
                                UIImage(named: "icon_invite")?
                                    .withRenderingMode(.alwaysTemplate)
                            ),
                            title: "GROUP_INVITE_ACTION".localized(),
                            accessibilityIdentifier: "\(EditGroupViewModel.self).invite_contacts",
                            onTap: {
                                self?.transitionToScreen(
                                    SessionTableViewController(
                                        viewModel: GroupMembersViewModel(
                                            dependencies: dependencies,
                                            threadId: threadId,
                                            variant: .invite
                                        )
                                    )
                                )
                            }
                        )
                    ]
                ),
                        
                SectionModel(
                    model: .members,
                    elements: allMembers.map { profile in
                        SessionCell.Info(
                            id: .member(profile),
                            leftAccessory: .profile(
                                id: profile.id,
                                profile: profile
                            ),
                            title: profile.displayName(),
                            rightAccessory: .radio(
                                isSelected: { [weak self] in
                                    self?.selectedContactIdsSubject.value.contains(profile.id) == true
                                }
                            ),
                            accessibilityIdentifier: "\(EditGroupViewModel.self).\(profile.id)",
                            onTap: { [weak self] in
                                var updatedSelectedIds: Set<String> = (self?.selectedContactIdsSubject.value ?? [])
                                
                                if !updatedSelectedIds.contains(profile.id) {
                                    updatedSelectedIds.insert(profile.id)
                                }
                                else {
                                    updatedSelectedIds.remove(profile.id)
                                }
                                
                                self?.selectedContactIdsSubject.send(updatedSelectedIds)
                            }
                        )
                    }
                )
            ]
        }
        .removeDuplicates()
        .publisher(in: dependencies.storage, scheduling: dependencies.scheduler)
        .mapToSessionTableViewData(for: self)
    
    override var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> {
        selectedContactIdsSubject
            .prepend([])
            .map { [weak self] selectedContactIds in
                let contactNames: [String] = selectedContactIds
                    .compactMap { contactId in
                        guard
                            let section: EditGroupViewModel.SectionModel = self?.tableData
                                .first(where: { section in section.model == .members }),
                            let info: SessionCell.Info<EditGroupViewModel.Setting> = section.elements
                                .first(where: { info in
                                    switch info.id {
                                        case .member(let profile): return (profile.id == contactId)
                                        default: return false
                                    }
                                })
                        else { return contactId }
                        
                        return info.title?.text
                    }
                
                return SessionButton.Info(
                    style: .destructive,
                    title: (selectedContactIds.count <= 1 ?
                        "GROUP_REMOVE_USER_ACTION".localized() :
                        "GROUP_REMOVE_USERS_ACTION".localized()
                    ),
                    isEnabled: !selectedContactIds.isEmpty,
                    onTap: {
                        self?.transitionToScreen(
                            RemoveUsersModal(contactNames: contactNames),
                            transitionType: .present
                        )
                    }
                )
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Functions
    
    private func updateProfilePicture(threadViewModel: SessionThreadViewModel) {
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
        // TODO: Send the 'DELETE_MESSAGES' message
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
        // TODO: Send the 'DELETE_GROUP' message with `members: '*'`
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
