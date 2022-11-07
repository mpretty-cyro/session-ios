// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

class GroupMembersViewModel: SessionTableViewModel<NoNav, GroupMembersViewModel.Section, GroupMembersViewModel.Setting> {
    // MARK: - Config
    
    public enum Variant {
        case list
        case invite
        case promote
        
        var title: String {
            switch self {
                case .list: return "GROUP_MEMBERS".localized()
                case .invite: return "GROUP_INVITE_TITLE".localized()
                case .promote: return "ADD_ADMINS".localized()
            }
        }
    }
    
    public enum Section: SessionTableSection {
        case sessionId
        case search
        case members
        
        var style: SessionTableSectionStyle {
            switch self {
                case .search: return .padding
                case .members: return .padding
                default: return .none
            }
        }
    }
    
    public enum Setting: Equatable, Hashable, Differentiable {
        case sessionId
        case search
        case member(Profile)
        case emptyState
    }
    
    // MARK: - Variables
    
    private let dependencies: Dependencies
    private let threadId: String
    private let variant: Variant
    
    // MARK: - Initialization
    
    init(
        dependencies: Dependencies = Dependencies(),
        threadId: String,
        variant: Variant
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.variant = variant
        
        super.init()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let allContactProfiles: [Profile] = dependencies.storage
                .read { db in
                    switch variant {
                        case .list:
                            let contactIdsInGroup: Set<String> = (try? GroupMember
                                .filter(GroupMember.Columns.groupId == threadId)
                                .select(.profileId)
                                .asRequest(of: String.self)
                                .fetchSet(db))
                                .defaulting(to: [])
                            
                            return try Profile
                                .fetchSet(db, ids: contactIdsInGroup)
                                .sorted(by: { lhs, rhs -> Bool in lhs.displayName() < rhs.displayName() })
                            
                        case .invite:
                            let contactIdsInGroup: Set<String> = (try? GroupMember
                                .filter(GroupMember.Columns.groupId == threadId)
                                .filter(GroupMember.Columns.role == GroupMember.Role.standard)
                                .select(.profileId)
                                .asRequest(of: String.self)
                                .fetchSet(db))
                                .defaulting(to: [])
                            
                            return try Profile
                                .allContactProfiles(excluding: contactIdsInGroup)
                                .fetchAll(db)
                                .sorted(by: { lhs, rhs -> Bool in lhs.displayName() < rhs.displayName() })
                            
                        case .promote:
                            let contactIdsInGroup: Set<String> = (try? GroupMember
                                .filter(GroupMember.Columns.groupId == threadId)
                                .filter(GroupMember.Columns.role == GroupMember.Role.standard)
                                .select(.profileId)
                                .asRequest(of: String.self)
                                .fetchSet(db))
                                .defaulting(to: [])
                            let adminIdsInGroup: Set<String> = (try? GroupMember
                                .filter(GroupMember.Columns.groupId == threadId)
                                .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                                .select(.profileId)
                                .asRequest(of: String.self)
                                .fetchSet(db))
                                .defaulting(to: [])
                            
                            return try Profile
                                .fetchSet(db, ids: contactIdsInGroup.subtracting(adminIdsInGroup))
                                .sorted(by: { lhs, rhs -> Bool in lhs.displayName() < rhs.displayName() })
                    }
                }
                .defaulting(to: [])
            
            self?.allProfilesSubject.send(allContactProfiles)
        }
    }
    
    // MARK: - Content
    
    override var title: String { return variant.title }
    
    private let allProfilesSubject: CurrentValueSubject<[Profile], Never> = CurrentValueSubject([])
    private let selectedContactIdsSubject: CurrentValueSubject<Set<String>, Never> = CurrentValueSubject([])
    private lazy var searchTermPublisher: AnyPublisher<String, Never> = textChanged
        .filter { _, item in item == .search }
        .map { value, _ in (value ?? "") }
        .shareReplay(1)
        .prepend("")
        .eraseToAnyPublisher()
    public override var observableTableData: ObservableData { _observableTableData }
    
    /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
    /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
    ///
    /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
    /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
    /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
    /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
    private lazy var _observableTableData: ObservableData = Just(self.variant)
        .map { variant -> [SectionModel] in
            [
                (variant != .invite ? nil :
                    SectionModel(
                        model: .sessionId,
                        elements: [
                            SessionCell.Info(
                                id: .sessionId,
                                title: SessionCell.TextInfo(
                                    "",
                                    font: .subtitle,
                                    alignment: .left,
                                    editingPlaceholder: "vc_enter_public_key_text_field_hint".localized(),
                                    interaction: .alwaysEditing
                                ),
                                styling: SessionCell.StyleInfo(
                                    customPadding: SessionCell.Padding(
                                        // Note: Need 1pt here so the top border of the text entry
                                        // is visible
                                        top: 1,
                                        bottom: 0
                                    ),
                                    backgroundStyle: .noBackground
                                )
                            )
                        ]
                    )
                ),
                SectionModel(
                    model: .search,
                    elements: [
                        SessionCell.Info(
                            id: .search,
                            accessory: .search(
                                placeholder: "Search Contacts",
                                searchTermChanged: { [weak self] term in
                                    self?.textChanged(term, for: .search)
                                }
                            ),
                            styling: SessionCell.StyleInfo(
                                customPadding: SessionCell.Padding(
                                    top: 0,
                                    leading: 0,
                                    trailing: 0,
                                    bottom: 0
                                ),
                                backgroundStyle: .noBackground
                            ),
                            accessibilityIdentifier: "\(GroupMembersViewModel.self).search"
                        )
                    ]
                )
            ].compactMap { $0 }
        }
        .combineLatest(allProfilesSubject, searchTermPublisher)
        .map { [weak self] initialSections, allProfiles, searchTerm -> [SectionModel] in
            guard !allProfiles.isEmpty else {
                return initialSections
                    .appending(
                        SectionModel(
                            model: .members,
                            elements: [
                                SessionCell.Info(
                                    id: .emptyState,
                                    title: SessionCell.TextInfo(
                                        {
                                            switch self?.variant {
                                                case .promote: return "ADD_ADMIN_NO_NON_ADMINS".localized()
                                                case .invite: return "GROUP_INVITE_NO_OTHER_CONTACTS".localized()
                                                default: return "GROUP_MEMBERS_NO_CONTACTS".localized()
                                            }
                                        }(),
                                        font: .subtitle,
                                        alignment: .center
                                    ),
                                    styling: SessionCell.StyleInfo(
                                        tintColor: .textSecondary,
                                        backgroundStyle: .noBackground
                                    )
                                )
                            ]
                        )
                    )
            }
            
            // Filter the profiles based on the search term
            let filteredProfileInfo: [SessionCell.Info<Setting>] = allProfiles
                .filter {
                    searchTerm.isEmpty ||
                    $0.displayName().lowercased().contains(searchTerm.lowercased())
                }
                .map { profile -> SessionCell.Info<Setting> in
                    SessionCell.Info(
                        id: .member(profile),
                        leftAccessory: .profile(
                            id: profile.id,
                            profile: profile
                        ),
                        title: profile.displayName(),
                        rightAccessory: (self?.variant == .list ? nil :
                            .radio(
                                isSelected: {
                                    self?.selectedContactIdsSubject.value.contains(profile.id) == true
                                }
                            )
                        ),
                        accessibilityIdentifier: "\(GroupMembersViewModel.self).\(profile.id)",
                        onTap: {
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
            
            guard !filteredProfileInfo.isEmpty else {
                return initialSections
                    .appending(
                        SectionModel(
                            model: .members,
                            elements: [
                                SessionCell.Info(
                                    id: .emptyState,
                                    title: SessionCell.TextInfo(
                                        "CONVERSATION_SEARCH_NO_RESULTS".localized(),
                                        font: .subtitle,
                                        alignment: .center
                                    ),
                                    styling: SessionCell.StyleInfo(
                                        tintColor: .textSecondary,
                                        backgroundStyle: .noBackground
                                    )
                                )
                            ]
                        )
                    )
            }
            
            return initialSections
                .appending(SectionModel(model: .members, elements: filteredProfileInfo))
        }
        .removeDuplicates()
        .setFailureType(to: Error.self)
        .eraseToAnyPublisher()
        .mapToSessionTableViewData(for: self)
    
    override var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> {
        switch variant {
            case .list: return Just(nil).eraseToAnyPublisher()
            
            case .invite:
                return Publishers
                    .CombineLatest(
                        selectedContactIdsSubject
                            .prepend([]),
                        textChanged
                            .filter { _, item in item == .sessionId }
                            .map { value, _ in (value ?? "") }
                            .prepend("")
                    )
                    .map { [weak self] selectedContactIds, onsNameOrPublicKey in
                        SessionButton.Info(
                            style: .bordered,
                            title: "GROUP_INVITE_ACTION".localized(),
                            isEnabled: (!selectedContactIds.isEmpty || !onsNameOrPublicKey.isEmpty),
                            onTap: {
                                self?.addUsersToClosedGroup(
                                    selectedContactIds: selectedContactIds,
                                    onsNameOrPublicKey: onsNameOrPublicKey
                                )
                            }
                        )
                    }
                    .eraseToAnyPublisher()
                
            case .promote:
                return selectedContactIdsSubject
                    .prepend([])
                    .map { [weak self] selectedContactIds in
                        SessionButton.Info(
                            style: .bordered,
                            title: "ADD_ADMINS_ACTION".localized(),
                            isEnabled: !selectedContactIds.isEmpty,
                            onTap: { self?.promoteUsersToAdmin(selectedContactIds: selectedContactIds) }
                        )
                    }
                    .eraseToAnyPublisher()
        }
    }
    
    // MARK: - Functions
    
    private func addUsersToClosedGroup(
        selectedContactIds: Set<String>,
        onsNameOrPublicKey: String
    ) {
        let maybeSessionId: SessionId? = SessionId(from: onsNameOrPublicKey)
        
        // Block invitations to non-standard session ids
        guard maybeSessionId?.prefix != .blinded && maybeSessionId?.prefix != .unblinded else {
            self.transitionToScreen(
                ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "GROUP_INVITE_ERROR_BLINDED_ID".localized(),
                        cancelTitle: "BUTTON_OK".localized(),
                        cancelStyle: .alert_text
                    )
                ),
                transitionType: .present
            )
            return
        }

        guard onsNameOrPublicKey.isEmpty || maybeSessionId?.prefix == .standard else {
            // This could be an ONS name
            let activityIndicator: ModalActivityIndicatorViewController = ModalActivityIndicatorViewController(
                canCancel: false,
                message: nil
            ) { [weak self] modalActivityIndicator in
                SnodeAPI
                        .getSessionID(for: onsNameOrPublicKey)
                        .done { sessionId in
                            modalActivityIndicator.dismiss {
                                self?.addUsersToClosedGroup(
                                    selectedContactIds: selectedContactIds,
                                    onsNameOrPublicKey: sessionId
                                )
                            }
                        }
                        .catch { error in
                            modalActivityIndicator.dismiss {
                                var messageOrNil: String?
                                if let error = error as? SnodeAPIError {
                                    switch error {
                                        case .decryptionFailed, .hashingFailed, .validationFailed:
                                            messageOrNil = error.errorDescription
                                        default: break
                                    }
                                }
                                let message: String = {
                                    if let messageOrNil: String = messageOrNil {
                                        return messageOrNil
                                    }

                                    return (maybeSessionId?.prefix == .blinded ?
                                        "DM_ERROR_DIRECT_BLINDED_ID".localized() :
                                        "DM_ERROR_INVALID".localized()
                                    )
                                }()

                                let modal: ConfirmationModal = ConfirmationModal(
                                    info: ConfirmationModal.Info(
                                        title: "ALERT_ERROR_TITLE".localized(),
                                        explanation: message,
                                        cancelTitle: "BUTTON_OK".localized(),
                                        cancelStyle: .alert_text
                                    )
                                )
                                self?.transitionToScreen(modal, transitionType: .present)
                            }
                        }
            }
            self.transitionToScreen(activityIndicator, transitionType: .present)
            return
        }
        
        // Now that we have validated the custom id, confirm the user wants to make them admins
        let threadId: String = self.threadId
        let contactNames: [String] = selectedContactIds
            .compactMap { contactId in
                guard
                    let section: GroupMembersViewModel.SectionModel = self.tableData
                        .first(where: { section in section.model == .members }),
                    let info: SessionCell.Info<GroupMembersViewModel.Setting> = section.elements
                        .first(where: { info in
                            switch info.id {
                                case .member(let profile): return (profile.id == contactId)
                                default: return false
                            }
                        })
                else { return contactId }
                
                return info.title?.text
            }
            .inserting(
                SessionId(from: onsNameOrPublicKey)
                    .map { sessionId in Profile.truncated(id: sessionId.publicKey, truncating: .middle) }
                    .defaulting(to: onsNameOrPublicKey),
                at: 0
            )
            .filter { !$0.isEmpty }
        
//        dependencies.storage.writeAsync { db in
//            guard let openGroup: OpenGroup = try OpenGroup.fetchOne(db, id: threadId) else { return }
//
//            let urlString: String = "\(openGroup.server)/\(openGroup.roomToken)?public_key=\(openGroup.publicKey)"
//
//            try selectedUsers.forEach { userId in
//                let thread: SessionThread = try SessionThread.fetchOrCreate(db, id: userId, variant: .contact)
//
//                try LinkPreview(
//                    url: urlString,
//                    variant: .openGroupInvitation,
//                    title: openGroup.name
//                )
//                .save(db)
//
//                let interaction: Interaction = try Interaction(
//                    threadId: thread.id,
//                    authorId: userId,
//                    variant: .standardOutgoing,
//                    timestampMs: Int64(floor(Date().timeIntervalSince1970 * 1000)),
//                    expiresInSeconds: try? DisappearingMessagesConfiguration
//                        .select(.durationSeconds)
//                        .filter(id: userId)
//                        .filter(DisappearingMessagesConfiguration.Columns.isEnabled == true)
//                        .asRequest(of: TimeInterval.self)
//                        .fetchOne(db),
//                    linkPreviewUrl: urlString
//                )
//                .inserted(db)
//
//                try MessageSender.send(
//                    db,
//                    interaction: interaction,
//                    in: thread
//                )
//            }
//        }
        
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "GROUP_INVITE_SENT_TITLE".localized(),
                attributedExplanation: ConfirmationModal.boldedUserString(
                    contactNames: contactNames,
                    singleUserString: "GROUP_INVITE_SENT_EXPLANATION_SINGLE".localized(),
                    twoUserString: "GROUP_INVITE_SENT_EXPLANATION_TWO".localized(),
                    manyUserString: "GROUP_INVITE_SENT_EXPLANATION_MANY".localized()
                ),
                cancelTitle: nil,
                showCloseButton: true
            )
        )
        
        self.transitionToScreen(modal, transitionType: .present)
    }
    
    private func promoteUsersToAdmin(selectedContactIds: Set<String>) {
        let contactNames: [String] = selectedContactIds
            .compactMap { contactId in
                guard
                    let section: GroupMembersViewModel.SectionModel = self.tableData
                        .first(where: { section in section.model == .members }),
                    let info: SessionCell.Info<GroupMembersViewModel.Setting> = section.elements
                        .first(where: { info in
                            switch info.id {
                                case .member(let profile): return (profile.id == contactId)
                                default: return false
                            }
                        })
                else { return contactId }
                
                return info.title?.text
            }
        
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: (selectedContactIds.count == 1 ?
                    "ADD_ADMIN".localized() :
                    "ADD_ADMINS".localized()
                ),
                attributedExplanation: ConfirmationModal.boldedUserString(
                    contactNames: contactNames,
                    singleUserString: "ADD_ADMIN_EXPLANATION_SINGLE".localized(),
                    twoUserString: "ADD_ADMIN_EXPLANATION_TWO".localized(),
                    manyUserString: "ADD_ADMIN_EXPLANATION_MANY".localized()
                ),
                cancelTitle: nil,
                showCloseButton: true,
                onConfirm: { _ in
                }
            )
        )
        
        self.transitionToScreen(modal, transitionType: .present)
    }
}
