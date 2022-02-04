// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import NVActivityIndicatorView
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit
import SwiftUI

class ConversationSettingsViewController: BaseVC {
    private let viewModel: ConversationSettingsViewModel
    private var disposables: Set<AnyCancellable> = Set()
    
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
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Force the viewModel to refresh it's data when the view appears in case the state changed
        viewModel.forceRefreshData.send()
    }
    
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
        // Content
        
        viewModel.leftNavItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                self?.navigationItem.setLeftBarButtonItems(
                    items.map { item -> DisposableBarButtonItem in
                        let buttonItem: DisposableBarButtonItem = DisposableBarButtonItem(barButtonSystemItem: item.data.systemItem, target: nil, action: nil, accessibilityIdentifier: item.data.accessibilityIdentifier)
                        buttonItem.tintColor = Colors.text
                        buttonItem.accessibilityIdentifier = item.data.accessibilityIdentifier
                        buttonItem.accessibilityLabel = item.data.accessibilityIdentifier
                        buttonItem.isAccessibilityElement = true
                        
                        buttonItem.tapPublisher
                            .mapToVoid()
                            .sink(into: item.action)
                            .store(in: &buttonItem.disposables)
                        
                        return buttonItem
                    },
                    animated: true
                )
            }
            .store(in: &disposables)
        
        viewModel.rightNavItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                self?.navigationItem.setRightBarButtonItems(
                    items.map { item -> DisposableBarButtonItem in
                        let buttonItem: DisposableBarButtonItem = DisposableBarButtonItem(barButtonSystemItem: item.data.systemItem, target: nil, action: nil, accessibilityIdentifier: item.data.accessibilityIdentifier)
                        buttonItem.tintColor = Colors.text
                        buttonItem.accessibilityIdentifier = item.data.accessibilityIdentifier
                        buttonItem.accessibilityLabel = item.data.accessibilityIdentifier
                        buttonItem.isAccessibilityElement = true
                        
                        buttonItem.tapPublisher
                            .mapToVoid()
                            .sink(into: item.action)
                            .store(in: &buttonItem.disposables)
                        
                        return buttonItem
                    },
                    animated: true
                )
            }
            .store(in: &disposables)
        
        viewModel.items
            .first()    // Just want to create the UI once, can update the content separately
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let viewModel: ConversationSettingsViewModel = self?.viewModel else { return }
                
                let edgeInset: CGFloat = (isIPhone5OrSmaller ? Values.mediumSpacing : Values.largeSpacing)
                
                items.enumerated().forEach { sectionIndex, section in
                    section.enumerated().forEach { index, item in
                        switch item.data.style {
                            case .header:
                                let targetView: ConversationSettingsHeaderView = ConversationSettingsHeaderView()
                                targetView.clipsToBounds = true
                                targetView.layer.cornerRadius = 8
                                targetView.update(with: item.data.title, contactSessionId: item.data.subtitle)
                                targetView.update(isEditingDisplayName: item.data.isEditing, animated: false)
                                
                                targetView.displayNameTapPublisher
                                    .mapToVoid()
                                    .sink(into: viewModel.editDisplayNameTapped)
                                    .store(in: &targetView.disposables)
                                
                                targetView.profilePictureTapPublisher
                                    .mapToVoid()
                                    .sink(into: viewModel.profilePictureTapped)
                                    .store(in: &targetView.disposables)
                                
                                targetView.textPublisher
                                    .assign(to: \.displayName, on: viewModel)
                                    .store(in: &targetView.disposables)
                                
                                self?.viewMap[item.data.id] = targetView
                                self?.stackView.addArrangedSubview(targetView)
                                
                            case .search:
                                let targetView: ConversationSettingsActionView = ConversationSettingsActionView()
                                targetView.clipsToBounds = true
                                targetView.layer.cornerRadius = (ConversationSettingsActionView.minHeight / 2)
                                targetView.update(
                                    with: item.data.icon,
                                    color: Colors.text,
                                    title: item.data.title,
                                    canHighlight: false,
                                    isEnabled: item.data.isEnabled
                                )
                                
                                targetView.tapPublisher
                                    .mapToVoid()
                                    .sink(into: item.action)
                                    .store(in: &targetView.disposables)
                                
                                self?.viewMap[item.data.id] = targetView
                                self?.stackView.addArrangedSubview(targetView)
                                
                            case .standard:
                                let targetView: ConversationSettingsActionView = ConversationSettingsActionView()
                                targetView.clipsToBounds = true
                                targetView.layer.cornerRadius = 8
                                targetView.update(
                                    with: item.data.icon,
                                    color: (item.data.isNegativeAction ?
                                        Colors.destructive :
                                        Colors.text
                                    ),
                                    title: item.data.title,
                                    subtitle: item.data.subtitle,
                                    isEnabled: item.data.isEnabled
                                )
                                
                                targetView.tapPublisher
                                    .mapToVoid()
                                    .sink(into: item.action)
                                    .store(in: &targetView.disposables)
                                
                                self?.viewMap[item.data.id] = targetView
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
                        }
                    }
                    
                    // Add a spacer at the bottom of each section (except for the last)
                    if sectionIndex != (items.count - 1) {
                        self?.stackView.addArrangedSubview(UIView.vSpacer(30))
                    }
                }
            }
            .store(in: &disposables)
        
        Publishers
            .CombineLatest(
                // Note: Don't care about this value but want to wait until it has emitted so that the
                // header gets updated correctly with the 'thread'
                viewModel.items.first(),
                viewModel.profileContent
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, thread in
                // TODO: Refactor the 'ProfilePictureView' so it's not dependant on a TSThread
                // (will make this cleaner or not needed)
                (self?.viewMap[.header] as? ConversationSettingsHeaderView)?.updateProfile(with: thread)
            }
            .store(in: &disposables)
        
        viewModel.items
            .dropFirst()    // Only want changes here as the UI gets created in the previous sink
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                items.enumerated().forEach { sectionIndex, section in
                    section.enumerated().forEach { index, item in
                        switch item.data.style {
                            case .header:
                                (self?.viewMap[item.data.id] as? ConversationSettingsHeaderView)?
                                    .update(with: item.data.title, contactSessionId: item.data.subtitle)
                                (self?.viewMap[item.data.id] as? ConversationSettingsHeaderView)?
                                    .update(isEditingDisplayName: item.data.isEditing, animated: true)
                                
                            case .search:
                                (self?.viewMap[item.data.id] as? ConversationSettingsActionView)?
                                    .update(
                                        with: item.data.icon,
                                        color: Colors.text,
                                        title: item.data.title,
                                        canHighlight: false,
                                        isEnabled: item.data.isEnabled
                                    )
                                
                            case .standard:
                                (self?.viewMap[item.data.id] as? ConversationSettingsActionView)?
                                    .update(
                                        with: item.data.icon,
                                        color: (item.data.isNegativeAction ?
                                            Colors.destructive :
                                            Colors.text
                                        ),
                                        title: item.data.title,
                                        subtitle: item.data.subtitle,
                                        isEnabled: item.data.isEnabled
                                    )
                        }
                    }
                }
            }
            .store(in: &disposables)
        
        // Bind interactions
        
        viewModel.viewProfilePicture
            .receive(on: DispatchQueue.main)
            .sink { [weak self] profileImage, threadName in
                let viewController: ProfilePictureVC = ProfilePictureVC(image: profileImage, title: threadName)
                let navController: UINavigationController = UINavigationController(rootViewController: viewController)
                navController.modalPresentationStyle = .fullScreen
                
                self?.present(navController, animated: true, completion: nil)
            }
            .store(in: &disposables)
        
        viewModel.viewSearch
            .sink(receiveValue: {}) // viewModel handles everything for now
            .store(in: &disposables)
        
        viewModel.viewAddToGroup
            .receive(on: DispatchQueue.main)
            .sink { [weak self] thread in
                let viewController: UserSelectionVC = UserSelectionVC(with: "vc_conversation_settings_invite_button_title".localized(), excluding: Set()) { selectedUsers in
                    self?.viewModel.addUsersToOpenGoup(selectedUsers: selectedUsers)
                }
                
                self?.navigationController?.pushViewController(viewController, animated: true)
            }
            .store(in: &disposables)
        
        viewModel.viewEditGroup
            .receive(on: DispatchQueue.main)
            .sink { [weak self] threadId in
                let viewController: EditClosedGroupVC = EditClosedGroupVC(with: threadId)
                self?.navigationController?.pushViewController(viewController, animated: true)
            }
            .store(in: &disposables)
        
        viewModel.viewAllMedia
            .receive(on: DispatchQueue.main)
            .sink { [weak self] thread in
                guard let navController: OWSNavigationController = self?.navigationController as? OWSNavigationController else {
                    return
                }
                
                // Note: Need to store the 'mediaGallery' somewhere to prevent it from being released and crashing
                let mediaGallery: MediaGallery = MediaGallery(thread: thread, options: [ .sliderEnabled, .newestFirst ])
                self?.mediaGallery = mediaGallery
                mediaGallery.pushTileView(fromNavController: navController)
            }
            .store(in: &disposables)
        
        viewModel.viewDisappearingMessages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] thread, config in
                let viewController: ConversationDisappearingMessagesViewController = ConversationDisappearingMessagesViewController(thread: thread, configuration: config) { [weak self] in
                    // In case the change takes too long force the viewModel to refresh it's state
                    self?.viewModel.forceRefreshData.send()
                }
                self?.navigationController?.pushViewController(viewController, animated: true)
            }
            .store(in: &disposables)
        
        viewModel.viewNotificationSettings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] groupThread in
                let viewController: ConversationNotificationSettingsViewController = ConversationNotificationSettingsViewController(thread: groupThread) { [weak self] in
                    // In case the change takes too long force the viewModel to refresh it's state
                    self?.viewModel.forceRefreshData.send()
                }
                self?.navigationController?.pushViewController(viewController, animated: true)
            }
            .store(in: &disposables)
        
        viewModel.viewDeleteMessagesAlert
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let alertController: UIAlertController = UIAlertController(
                    title: "DELETE_MESSAGES".localized(),
                    message: "DELETE_MESSAGES_CONFIRMATION_MESSAGE".localized(),
                    preferredStyle: .alert
                )
                alertController.addAction(
                    UIAlertAction(
                        title: "TXT_DELETE_TITLE".localized(),
                        accessibilityIdentifier: "\(ConversationSettingsViewController.self).delete_messages_confirm",
                        style: .destructive
                    ) { _ in
                        self?.viewModel.deleteMessages()
                    }
                )
                alertController.addAction(OWSAlerts.cancelAction)
                
                self?.presentAlert(alertController)
            }
            .store(in: &disposables)
        
        viewModel.loadingStateVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                guard isLoading else {
                    guard self?.presentedViewController is LoadingViewController else { return }

                    self?.presentedViewController?.dismiss(animated: true, completion: nil)
                    return
                }
                
                let viewController: LoadingViewController = LoadingViewController()
                viewController.modalTransitionStyle = .crossDissolve
                viewController.modalPresentationStyle = .overCurrentContext
                
                self?.present(viewController, animated: true, completion: nil)
            }
            .store(in: &disposables)
        
        viewModel.viewLeaveGroupAlert
            .receive(on: DispatchQueue.main)
            .sink { [weak self] groupThread in
                let userPublicKey: String = SNGeneralUtilities.getUserPublicKey()
                let message: String
                
                if groupThread.groupModel.groupAdminIds.contains(userPublicKey) {
                    message = "Because you are the creator of this group it will be deleted for everyone. This cannot be undone."
                }
                else {
                    message = "CONFIRM_LEAVE_GROUP_DESCRIPTION".localized()
                }
                
                let alertController: UIAlertController = UIAlertController(
                    title: "CONFIRM_LEAVE_GROUP_TITLE".localized(),
                    message: message,
                    preferredStyle: .alert
                )
                alertController.addAction(
                    UIAlertAction(
                        title: "LEAVE_BUTTON_TITLE".localized(),
                        accessibilityIdentifier: "\(ConversationSettingsViewController.self).leave_group_confirm",
                        style: .destructive
                    ) { _ in
                        self?.viewModel.leaveGroup()
                    }
                )
                alertController.addAction(OWSAlerts.cancelAction)
                
                self?.presentAlert(alertController)
            }
            .store(in: &disposables)
        
        viewModel.viewBlockUserAlert
            .receive(on: DispatchQueue.main)
            .sink { [weak self] thread in
                guard let strongSelf: UIViewController = self else { return }
                
                // TODO: Refactor this to be more MVVM
                // (ie. actionSheet can be triggered from here but the VM should update the blocked state)
                if OWSBlockingManager.shared().isThreadBlocked(thread) {
                    BlockListUIUtils.showUnblockThreadActionSheet(thread, from: strongSelf, blockingManager: OWSBlockingManager.shared()) { _ in
                        self?.viewModel.forceRefreshData.send()
                    }
                }
                else {
                    BlockListUIUtils.showBlockThreadActionSheet(thread, from: strongSelf, blockingManager: OWSBlockingManager.shared()) { _ in
                        self?.viewModel.forceRefreshData.send()
                    }
                }
            }
            .store(in: &disposables)
    }
}
