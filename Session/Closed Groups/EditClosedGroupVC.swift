// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import PromiseKit
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit

@objc(SNEditClosedGroupVC)
final class EditClosedGroupVC: BaseVC, UITableViewDataSource, UITableViewDelegate {
    private struct GroupMemberDisplayInfo: FetchableRecord, Decodable {
        let profileId: String
        let role: GroupMember.Role
        let profile: Profile?
    }
    
    private let threadId: String
    private var originalName: String = ""
    private var originalMembersAndZombieIds: Set<String> = []
    private var name: String = ""
    private var hasContactsToAdd: Bool = false
    private var userPublicKey: String = ""
    private var membersAndZombies: [GroupMemberDisplayInfo] = []
    private var adminIds: Set<String> = []
    private var isEditingGroupName = false { didSet { handleIsEditingGroupNameChanged() } }
    private var tableViewHeightConstraint: NSLayoutConstraint!

    // MARK: - Components
    
    private lazy var groupNameLabel: UILabel = {
        let result: UILabel = UILabel()
        result.textColor = Colors.text
        result.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        result.lineBreakMode = .byTruncatingTail
        result.textAlignment = .center
        
        return result
    }()

    private lazy var groupNameTextField: TextField = {
        let result: TextField = TextField(placeholder: "Enter a group name", usesDefaultHeight: false)
        result.textAlignment = .center
        
        return result
    }()

    private lazy var addMembersButton: Button = {
        let result: Button = Button(style: .prominentOutline, size: .large)
        result.setTitle("Add Members", for: UIControl.State.normal)
        result.addTarget(self, action: #selector(addMembers), for: UIControl.Event.touchUpInside)
        result.contentEdgeInsets = UIEdgeInsets(top: 0, leading: Values.mediumSpacing, bottom: 0, trailing: Values.mediumSpacing)
        
        return result
    }()

    @objc private lazy var tableView: UITableView = {
        let result: UITableView = UITableView()
        result.dataSource = self
        result.delegate = self
        result.separatorStyle = .none
        result.backgroundColor = .clear
        result.isScrollEnabled = false
        result.register(view: UserCell.self)
        
        return result
    }()

    // MARK: - Lifecycle
    
    @objc(initWithThreadId:)
    init(with threadId: String) {
        self.threadId = threadId
        
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init(with:) instead.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        setUpGradientBackground()
        setUpNavBarStyle()
        setNavBarTitle("Edit Group")
        
        let backButton = UIBarButtonItem(title: "Back", style: .plain, target: nil, action: nil)
        backButton.tintColor = Colors.text
        navigationItem.backBarButtonItem = backButton
        
        let threadId: String = self.threadId
        
        Storage.shared.read { [weak self] db in
            self?.userPublicKey = getUserHexEncodedPublicKey(db)
            self?.name = try ClosedGroup
                .select(.name)
                .filter(id: threadId)
                .asRequest(of: String.self)
                .fetchOne(db)
                .defaulting(to: "Group")
            self?.originalName = (self?.name ?? "")
            
            let profileAlias: TypedTableAlias<Profile> = TypedTableAlias()
            let allGroupMembers: [GroupMemberDisplayInfo] = try GroupMember
                .filter(GroupMember.Columns.groupId == threadId)
                .including(optional: GroupMember.profile.aliased(profileAlias))
                .order(
                    (GroupMember.Columns.role == GroupMember.Role.zombie), // Non-zombies at the top
                    profileAlias[.nickname],
                    profileAlias[.name],
                    GroupMember.Columns.profileId
                )
                .asRequest(of: GroupMemberDisplayInfo.self)
                .fetchAll(db)
            self?.membersAndZombies = allGroupMembers
                .filter { $0.role == .standard || $0.role == .zombie }
            self?.adminIds = allGroupMembers
                .filter { $0.role == .admin }
                .map { $0.profileId }
                .asSet()
            
            let uniqueGroupMemberIds: Set<String> = allGroupMembers
                .map { $0.profileId }
                .asSet()
            self?.originalMembersAndZombieIds = uniqueGroupMemberIds
            self?.hasContactsToAdd = ((try Profile.fetchCount(db) - uniqueGroupMemberIds.count) > 0)
        }
        
        setUpViewHierarchy()
        updateNavigationBarButtons()
        handleMembersChanged()
    }

    private func setUpViewHierarchy() {
        // Group name container
        groupNameLabel.text = name
        
        let groupNameContainer = UIView()
        groupNameContainer.addSubview(groupNameLabel)
        groupNameLabel.pin(to: groupNameContainer)
        groupNameContainer.addSubview(groupNameTextField)
        groupNameTextField.pin(to: groupNameContainer)
        groupNameContainer.set(.height, to: 40)
        groupNameTextField.alpha = 0
        
        // Top container
        let topContainer = UIView()
        topContainer.addSubview(groupNameContainer)
        groupNameContainer.center(in: topContainer)
        topContainer.set(.height, to: 40)
        let topContainerTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(showEditGroupNameUI))
        topContainer.addGestureRecognizer(topContainerTapGestureRecognizer)
        
        // Members label
        let membersLabel = UILabel()
        membersLabel.textColor = Colors.text
        membersLabel.font = .systemFont(ofSize: Values.mediumFontSize)
        membersLabel.text = "Members"
        
        // Add members button
        if !self.hasContactsToAdd {
            addMembersButton.isUserInteractionEnabled = false
            let disabledColor = Colors.text.withAlphaComponent(Values.mediumOpacity)
            addMembersButton.layer.borderColor = disabledColor.cgColor
            addMembersButton.setTitleColor(disabledColor, for: UIControl.State.normal)
        }
        
        // Middle stack view
        let middleStackView = UIStackView(arrangedSubviews: [ membersLabel, addMembersButton ])
        middleStackView.axis = .horizontal
        middleStackView.alignment = .center
        middleStackView.layoutMargins = UIEdgeInsets(top: Values.smallSpacing, leading: Values.mediumSpacing, bottom: Values.smallSpacing, trailing: Values.mediumSpacing)
        middleStackView.isLayoutMarginsRelativeArrangement = true
        middleStackView.set(.height, to: Values.largeButtonHeight + Values.smallSpacing * 2)
        
        // Table view
        tableViewHeightConstraint = tableView.set(.height, to: 0)
        
        // Main stack view
        let mainStackView = UIStackView(arrangedSubviews: [
            UIView.vSpacer(Values.veryLargeSpacing),
            topContainer,
            UIView.vSpacer(Values.veryLargeSpacing),
            UIView.separator(),
            middleStackView,
            UIView.separator(),
            tableView
        ])
        mainStackView.axis = .vertical
        mainStackView.alignment = .fill
        mainStackView.set(.width, to: UIScreen.main.bounds.width)
        
        // Scroll view
        let scrollView = UIScrollView()
        scrollView.showsVerticalScrollIndicator = false
        scrollView.addSubview(mainStackView)
        mainStackView.pin(to: scrollView)
        view.addSubview(scrollView)
        scrollView.pin(to: view)
    }

    // MARK: Table View Data Source / Delegate
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return membersAndZombies.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: UserCell = tableView.dequeue(type: UserCell.self, for: indexPath)
        cell.update(
            with: membersAndZombies[indexPath.row].profileId,
            profile: membersAndZombies[indexPath.row].profile,
            isZombie: (membersAndZombies[indexPath.row].role == .zombie),
            accessory: (adminIds.contains(userPublicKey) ?
                .none :
                .lock
            )
        )
        
        return cell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return adminIds.contains(userPublicKey)
    }

    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath) -> [UITableViewRowAction]? {
        let profileId: String = self.membersAndZombies[indexPath.row].profileId
        
        let removeAction = UITableViewRowAction(style: .destructive, title: "Remove") { [weak self] _, _ in
            self?.adminIds.remove(profileId)
            self?.membersAndZombies.remove(at: indexPath.row)
            self?.handleMembersChanged()
        }
        removeAction.backgroundColor = Colors.destructive
        
        return [ removeAction ]
    }

    // MARK: - Updating
    
    private func updateNavigationBarButtons() {
        if isEditingGroupName {
            let cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(handleCancelGroupNameEditingButtonTapped))
            cancelButton.tintColor = Colors.text
            navigationItem.leftBarButtonItem = cancelButton
        }
        else {
            navigationItem.leftBarButtonItem = nil
        }
        
        let doneButton = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(handleDoneButtonTapped))
        doneButton.tintColor = Colors.text
        navigationItem.rightBarButtonItem = doneButton
    }

    private func handleMembersChanged() {
        tableViewHeightConstraint.constant = CGFloat(membersAndZombies.count) * 67
        tableView.reloadData()
    }

    private func handleIsEditingGroupNameChanged() {
        updateNavigationBarButtons()
        
        UIView.animate(withDuration: 0.25) {
            self.groupNameLabel.alpha = self.isEditingGroupName ? 0 : 1
            self.groupNameTextField.alpha = self.isEditingGroupName ? 1 : 0
        }
        
        if isEditingGroupName {
            groupNameTextField.becomeFirstResponder()
        }
        else {
            groupNameTextField.resignFirstResponder()
        }
    }

    // MARK: - Interaction
    
    @objc private func showEditGroupNameUI() {
        isEditingGroupName = true
    }

    @objc private func handleCancelGroupNameEditingButtonTapped() {
        isEditingGroupName = false
    }

    @objc private func handleDoneButtonTapped() {
        if isEditingGroupName {
            updateGroupName()
        }
        else {
            commitChanges()
        }
    }

    private func updateGroupName() {
        let updatedName: String = groupNameTextField.text
            .defaulting(to: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        guard !updatedName.isEmpty else {
            return showError(title: "vc_create_closed_group_group_name_missing_error".lowercased())
        }
        guard updatedName.count < 64 else {
            return showError(title: "vc_create_closed_group_group_name_too_long_error".localized())
        }
        
        isEditingGroupName = false
        groupNameLabel.text = updatedName
        self.name = updatedName
    }

    @objc private func addMembers() {
        let title = "Add Members"
        
        let userSelectionVC: UserSelectionVC = UserSelectionVC(
            with: title,
            excluding: membersAndZombies
                .map { $0.profileId }
                .asSet()
        ) { [weak self] selectedUserIds in
            Storage.shared.read { [weak self] db in
                let selectedGroupMembers: [GroupMemberDisplayInfo] = try Profile
                    .filter(selectedUserIds.contains(Profile.Columns.id))
                    .fetchAll(db)
                    .map { profile in
                        GroupMemberDisplayInfo(
                            profileId: profile.id,
                            role: .standard,
                            profile: profile
                        )
                    }
                self?.membersAndZombies = (self?.membersAndZombies ?? [])
                    .appending(contentsOf: selectedGroupMembers)
                    .sorted(by: { lhs, rhs in
                        if lhs.role == .zombie && rhs.role != .zombie {
                            return false
                        }
                        else if lhs.role != .zombie && rhs.role == .zombie {
                            return true
                        }
                        
                        let lhsDisplayName: String = Profile.displayName(
                            for: .contact,
                            id: lhs.profileId,
                            name: lhs.profile?.name,
                            nickname: lhs.profile?.nickname
                        )
                        let rhsDisplayName: String = Profile.displayName(
                            for: .contact,
                            id: rhs.profileId,
                            name: rhs.profile?.name,
                            nickname: rhs.profile?.nickname
                        )
                        
                        return (lhsDisplayName < rhsDisplayName)
                    })
                    .filter { $0.role == .standard || $0.role == .zombie }
                
                let uniqueGroupMemberIds: Set<String> = (self?.membersAndZombies ?? [])
                    .map { $0.profileId }
                    .asSet()
                    .inserting(contentsOf: self?.adminIds)
                self?.hasContactsToAdd = ((try Profile.fetchCount(db) - uniqueGroupMemberIds.count) > 0)
            }
            
            let color = (self?.hasContactsToAdd == true ?
                Colors.accent :
                Colors.text.withAlphaComponent(Values.mediumOpacity)
            )
            self?.addMembersButton.isUserInteractionEnabled = (self?.hasContactsToAdd == true)
            self?.addMembersButton.layer.borderColor = color.cgColor
            self?.addMembersButton.setTitleColor(color, for: UIControl.State.normal)
            self?.handleMembersChanged()
        }
        
        navigationController?.pushViewController(userSelectionVC, animated: true, completion: nil)
    }

    private func commitChanges() {
        let popToConversationVC: ((EditClosedGroupVC?) -> ()) = { editVC in
            guard
                let viewControllers: [UIViewController] = editVC?.navigationController?.viewControllers,
                let conversationVC: ConversationVC = viewControllers.first(where: { $0 is ConversationVC }) as? ConversationVC
            else {
                editVC?.navigationController?.popViewController(animated: true)
                return
            }
            
            editVC?.navigationController?.popToViewController(conversationVC, animated: true)
        }
        
        let threadId: String = self.threadId
        let updatedName: String = self.name
        let userPublicKey: String = self.userPublicKey
        let updatedMemberIds: Set<String> = self.membersAndZombies
            .map { $0.profileId }
            .asSet()
        
        guard updatedMemberIds != self.originalMembersAndZombieIds || updatedName != self.originalName else {
            return popToConversationVC(self)
        }
        
        if !updatedMemberIds.contains(userPublicKey) {
            guard self.originalMembersAndZombieIds.removing(userPublicKey) == updatedMemberIds else {
                return showError(
                    title: "Couldn't Update Group",
                    message: "Can't leave while adding or removing other members."
                )
            }
        }
        guard updatedMemberIds.count <= 100 else {
            return showError(title: "vc_create_closed_group_too_many_group_members_error".localized())
        }
        
        ModalActivityIndicatorViewController.present(fromViewController: navigationController) { _ in
            Storage.shared
                .writeAsync { db in
                    if !updatedMemberIds.contains(userPublicKey) {
                        return try MessageSender.leave(db, groupPublicKey: threadId)
                    }
                    
                    return try MessageSender.update(
                        db,
                        groupPublicKey: threadId,
                        with: updatedMemberIds,
                        name: updatedName
                    )
                }
                .done(on: DispatchQueue.main) { [weak self] in
                    self?.dismiss(animated: true, completion: nil) // Dismiss the loader
                    popToConversationVC(self)
                }
                .catch(on: DispatchQueue.main) { [weak self] error in
                    self?.dismiss(animated: true, completion: nil) // Dismiss the loader
                    self?.showError(title: "Couldn't Update Group", message: error.localizedDescription)
                }
                .retainUntilComplete()
        }
    }

    // MARK: - Convenience
    
    private func showError(title: String, message: String = "") {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "BUTTON_OK".localized(), style: .default, handler: nil))
        presentAlert(alert)
    }
}
