// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SwiftUI

class ConversationSettingsViewController: BaseVC {
    private let viewModel: ConversationSettingsViewModel
    
    private var mediaGallery: MediaGallery?
    
    // MARK: - Initialization
    
    required init(thread: TSThread, uiDatabaseConnection: YapDatabaseConnection, didTriggerSearch: @escaping () -> ()) {
        self.viewModel = ConversationSettingsViewModel(thread: thread, uiDatabaseConnection: uiDatabaseConnection, didTriggerSearch: didTriggerSearch)
        
        super.init(nibName: nil, bundle: nil)
    }
    
    @available(*, unavailable, message:"use other constructor instead.")
    required init?(coder: NSCoder) {
        notImplemented()
    }
    
    // MARK: - UI
    
    // This is used to make the content easier to update (rather than just recreating the UI on every change)
    private var viewMap: [ConversationSettingsViewModel.Item.Id: UIView] = [:]
    
    private let scrollView: UIScrollView = {
        let scrollView: UIScrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        
        return scrollView
    }()
    
    private let stackView: UIStackView = {
        let stackView: UIStackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.distribution = .equalSpacing
        stackView.layoutMargins = UIEdgeInsets(top: 15, left: 15, bottom: 15, right: 15)
        stackView.isLayoutMarginsRelativeArrangement = true
        
        return stackView
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = Colors.settingsBackground
        ViewControllerUtilities.setUpDefaultSessionStyle(for: self, title: viewModel.title, hasCustomBackButton: true, hasCustomBackground: true)
        
        view.addSubview(scrollView)
        
        scrollView.addSubview(stackView)
        
        setupLayout()
        setupBinding()
    }
    
    // MARK: - Layout
    
    private func setupLayout() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leftAnchor.constraint(equalTo: view.leftAnchor),
            scrollView.rightAnchor.constraint(equalTo: view.rightAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.leftAnchor.constraint(equalTo: scrollView.leftAnchor),
            stackView.rightAnchor.constraint(equalTo: scrollView.rightAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: view.widthAnchor)
        ])
    }
    
    // MARK: - Binding
    
    private func setupBinding() {
        viewModel.leftNavItems.onChange { [weak self] items in
            self?.navigationItem.setLeftBarButtonItems(
                items.compactMap { item -> UIBarButtonItem? in
                    guard let systemItem: UIBarButtonItem.SystemItem = item.barButtonItem else { return nil }
                    
                    let buttonItem: ClosureBarButtonItem = ClosureBarButtonItem(barButtonSystemItem: systemItem) {
                        self?.viewModel.interaction.tap(item.action)
                    }
                    buttonItem.tintColor = item.color
                    buttonItem.accessibilityIdentifier = item.accessibilityIdentifier
                    buttonItem.accessibilityLabel = item.accessibilityIdentifier
                    buttonItem.isAccessibilityElement = true
                    
                    return buttonItem
                },
                animated: true
            )
        }
        
        viewModel.rightNavItems.onChange { [weak self] items in
            self?.navigationItem.setRightBarButtonItems(
                items.compactMap { item -> UIBarButtonItem? in
                    guard let systemItem: UIBarButtonItem.SystemItem = item.barButtonItem else { return nil }
                    
                    let buttonItem: ClosureBarButtonItem = ClosureBarButtonItem(barButtonSystemItem: systemItem) {
                        self?.viewModel.interaction.tap(item.action)
                    }
                    buttonItem.tintColor = item.color
                    buttonItem.accessibilityIdentifier = item.accessibilityIdentifier
                    buttonItem.accessibilityLabel = item.accessibilityIdentifier
                    buttonItem.isAccessibilityElement = true
                    
                    return buttonItem
                },
                animated: true
            )
        }
        
        // Create the UI once
        viewModel.items.onChange(firstOnly: true) { [weak self] items in
            let edgeInset: CGFloat = (isIPhone5OrSmaller ? Values.mediumSpacing : Values.largeSpacing)
            
            items.enumerated().forEach { sectionIndex, section in
                section.enumerated().forEach { index, item in
                    switch item.style {
                        case .header:
                            let targetView: ConversationSettingsHeaderView = ConversationSettingsHeaderView()
                            targetView.clipsToBounds = true
                            targetView.layer.cornerRadius = 8
                            
                            targetView.update(with: item.title, contactSessionId: item.subtitle)
                            targetView.profilePictureTapped = { [weak self] image in
                                self?.viewModel.interaction.tap(.viewProfilePicture, data: image)
                            }
                            targetView.displayNameTapped = { [weak self] in
                                self?.viewModel.interaction.tap(.startEditingDisplayName)
                            }
                            targetView.textChanged = { [weak self] updatedText in
                                self?.viewModel.interaction.change(.changeDisplayName, data: updatedText)
                            }
                            self?.viewMap[item.id] = targetView
                            
                            self?.stackView.addArrangedSubview(targetView)
                            
                        case .search:
                            let targetView: ConversationSettingsActionView = ConversationSettingsActionView()
                            targetView.clipsToBounds = true
                            targetView.layer.cornerRadius = (ConversationSettingsActionView.minHeight / 2)
                            targetView.update(
                                with: item.icon,
                                color: Colors.text,
                                title: item.title,
                                canHighlight: false,
                                isEnabled: item.isEnabled
                            )
                            targetView.viewTapped = { [weak self] in self?.viewModel.interaction.tap(item.action) }
                            self?.viewMap[item.id] = targetView
                            
                            self?.stackView.addArrangedSubview(targetView)
                            
                        case .standard:
                            let targetView: ConversationSettingsActionView = ConversationSettingsActionView()
                            targetView.clipsToBounds = true
                            targetView.layer.cornerRadius = 8
                            targetView.update(
                                with: item.icon,
                                color: item.color,
                                title: item.title,
                                subtitle: item.subtitle,
                                isEnabled: item.isEnabled
                            )
                            targetView.viewTapped = { [weak self] in self?.viewModel.interaction.tap(item.action) }
                            self?.viewMap[item.id] = targetView

                            self?.stackView.addArrangedSubview(targetView)
                            
                            // Round relevant corners
                            switch (index, section.count) {
                                case (_, 1): break
                                case (0, _): targetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                                case (section.count - 1, _): targetView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                                default: targetView.layer.cornerRadius = 0
                            }
                            
                            // Add a separator if there is an item after this one
                            switch index {
                                case section.count - 1: break
                                default:
                                    let separatorContainerView: UIView = UIView()
                                    separatorContainerView.backgroundColor = targetView.backgroundColor
                                     
                                    let separatorView: UIView = UIView.separator()
                                    separatorView.backgroundColor = Colors.settingsBackground
                                    
                                    separatorContainerView.addSubview(separatorView)
                                    self?.stackView.addArrangedSubview(separatorContainerView)
                                    
                                    NSLayoutConstraint.activate([
                                        separatorContainerView.heightAnchor.constraint(equalTo: separatorView.heightAnchor),
                                        separatorView.leftAnchor.constraint(equalTo: separatorContainerView.leftAnchor, constant: edgeInset),
                                        separatorView.rightAnchor.constraint(equalTo: separatorContainerView.rightAnchor, constant: -edgeInset)
                                    ])
                            }
                            
                        case .navigation: return
                    }
                }
                
                // Add a spacer at the bottom of each section (except for the last)
                if sectionIndex != (items.count - 1) {
                    self?.stackView.addArrangedSubview(UIView.vSpacer(30))
                }
            }
        }
        
        // Update content on any changes
        viewModel.thread.onChange { [weak self] thread in
            (self?.viewMap[.header] as? ConversationSettingsHeaderView)?.update(with: thread)
        }
        viewModel.items.onChange(skipFirst: true) { [weak self] items in
            items.enumerated().forEach { sectionIndex, section in
                section.enumerated().forEach { index, item in
                    switch item.style {
                        case .header:
                            (self?.viewMap[item.id] as? ConversationSettingsHeaderView)?
                                .update(with: item.title, contactSessionId: item.subtitle)
                            
                        case .search:
                            (self?.viewMap[item.id] as? ConversationSettingsActionView)?
                                .update(
                                    with: item.icon,
                                    color: Colors.text,
                                    title: item.title,
                                    canHighlight: false,
                                    isEnabled: item.isEnabled
                                )
                            
                        case .standard:
                            (self?.viewMap[item.id] as? ConversationSettingsActionView)?
                                .update(
                                    with: item.icon,
                                    color: item.color,
                                    title: item.title,
                                    subtitle: item.subtitle,
                                    isEnabled: item.isEnabled
                                )
                            
                        case .navigation: return
                    }
                }
            }
        }
        
        // Bind interactions
        
        viewModel.interaction.on(.startEditingDisplayName) { [weak self] _, _, _ in
            (self?.viewMap[.header] as? ConversationSettingsHeaderView)?.update(isEditingDisplayName: true)
        }
        
        viewModel.interaction.on(.cancelEditingDisplayName) { [weak self] _, _, _ in
            (self?.viewMap[.header] as? ConversationSettingsHeaderView)?.update(isEditingDisplayName: false)
        }
        
        viewModel.interaction.on(.saveUpdatedDisplayName) { [weak self] _, _, _ in
            (self?.viewMap[.header] as? ConversationSettingsHeaderView)?.update(isEditingDisplayName: false)
        }
        
        viewModel.interaction.on(.viewProfilePicture) { [weak self] thread, _, interactionImage in
            guard let profileImage: UIImage = interactionImage as? UIImage else { return }

            let threadName: String = (self?.viewModel.threadName?.isEmpty == false ?
                (self?.viewModel.threadName ?? "Anonymous") :
                "Anonymous"
            )
            let viewController: ProfilePictureVC = ProfilePictureVC(image: profileImage, title: threadName)
            let navController: UINavigationController = UINavigationController(rootViewController: viewController)
            navController.modalPresentationStyle = .fullScreen
            
            self?.present(navController, animated: true, completion: nil)
        }
        
        viewModel.interaction.on(.viewAddToGroup) { [weak self] thread, _, _ in
            let viewController: UserSelectionVC = UserSelectionVC(with: "vc_conversation_settings_invite_button_title".localized(), excluding: Set()) { selectedUsers in
                self?.viewModel.interaction.trigger(.addToGroupCompleted, data: selectedUsers)
            }
            
            self?.navigationController?.pushViewController(viewController, animated: true)
        }
        
        viewModel.interaction.on(.viewEditGroup) { [weak self] thread, _, _ in
            guard let threadId: String = thread.uniqueId else { return }
            
            let viewController: EditClosedGroupVC = EditClosedGroupVC(with: threadId)
            self?.navigationController?.pushViewController(viewController, animated: true)
        }
        
        viewModel.interaction.on(.viewAllMedia) { [weak self] thread, _, _ in
            guard let navController: OWSNavigationController = self?.navigationController as? OWSNavigationController else {
                return
            }
            
            // Note: Need to store the 'mediaGallery' somewhere to prevent it from being released and crashing
            let mediaGallery: MediaGallery = MediaGallery(thread: thread, options: .sliderEnabled)
            self?.mediaGallery = mediaGallery
            mediaGallery.pushTileView(fromNavController: navController)
        }
        
        viewModel.interaction.on(.viewDisappearingMessagesSettings) { [weak self] thread, disappearingMessageConfiguration, _ in
            guard let config: OWSDisappearingMessagesConfiguration = disappearingMessageConfiguration else { return }
            
            let viewController: ConversationDisappearingMessagesViewController = ConversationDisappearingMessagesViewController(thread: thread, configuration: config) { [weak self] in
                self?.viewModel.tryRefreshData(for: .disappearingMessages)
            }
            self?.navigationController?.pushViewController(viewController, animated: true)
        }
        
        viewModel.interaction.on(.viewNotificationsSettings) { [weak self] thread, _, _ in
            guard thread.isGroupThread(), let groupThread: TSGroupThread = thread as? TSGroupThread else { return }
            
            let viewController: ConversationNotificationSettingsViewController = ConversationNotificationSettingsViewController(thread: groupThread) { [weak self] in
                self?.viewModel.tryRefreshData(for: .notifications)
            }
            self?.navigationController?.pushViewController(viewController, animated: true)
        }
        
        viewModel.interaction.on(.toggleBlockUser) { [weak self] thread, _, _ in
            guard !thread.isNoteToSelf() && !thread.isGroupThread() else { return }
            guard let strongSelf: UIViewController = self else { return }
            
            // TODO: Refactor this to be more MVVM
            // (ie. actionSheet can be triggered from here but the VM should update the blocked state)
            if OWSBlockingManager.shared().isThreadBlocked(thread) {
                BlockListUIUtils.showUnblockThreadActionSheet(thread, from: strongSelf, blockingManager: OWSBlockingManager.shared()) { _ in
                    self?.viewModel.tryRefreshData(for: .blockUser)
                }
            }
            else {
                BlockListUIUtils.showBlockThreadActionSheet(thread, from: strongSelf, blockingManager: OWSBlockingManager.shared()) { _ in
                    self?.viewModel.tryRefreshData(for: .blockUser)
                }
            }
        }
        
        viewModel.interaction.on(.leaveGroup) { [weak self] thread, _, _ in
            guard let groupThread: TSGroupThread = thread as? TSGroupThread else { return }
            
            let userPublicKey: String = SNGeneralUtilities.getUserPublicKey()
            let message: String
            
            if groupThread.groupModel.groupAdminIds.contains(userPublicKey) {
                message = "Because you are the creator of this group it will be deleted for everyone. This cannot be undone."
            }
            else {
                message = NSLocalizedString("CONFIRM_LEAVE_GROUP_DESCRIPTION", comment: "")
            }
            
            let alertController: UIAlertController = UIAlertController(
                title: NSLocalizedString("CONFIRM_LEAVE_GROUP_TITLE", comment: ""),
                message: message,
                preferredStyle: .alert
            )
            alertController.addAction(
                UIAlertAction(
                    title: NSLocalizedString("LEAVE_BUTTON_TITLE", comment: ""),
                    accessibilityIdentifier: "\(ConversationSettingsViewController.self).leave_group_confirm",
                    style: .destructive
                ) { _ in
                    self?.viewModel.interaction.tap(.leaveGroupConfirmed)
                }
            )
            alertController.addAction(OWSAlerts.cancelAction)
            
            self?.presentAlert(alertController)
        }
        
        viewModel.interaction.on(.leaveGroupCompleted) { [weak self] _, _, _ in
            self?.navigationController?.popViewController(animated: true)
        }
    }
}
