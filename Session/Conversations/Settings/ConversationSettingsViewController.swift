// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

class ConversationSettingsViewController: BaseVC {
    private let viewModel: ConversationSettingsViewModel
    
    // MARK: - Initialization
    
    required init(thread: TSThread, uiDatabaseConnection: YapDatabaseConnection) {
        self.viewModel = ConversationSettingsViewModel(thread: thread, uiDatabaseConnection: uiDatabaseConnection)
        
        super.init(nibName: nil, bundle: nil)
    }
    
    @available(*, unavailable, message:"use other constructor instead.")
    required init?(coder: NSCoder) {
        notImplemented()
    }
    
    // MARK: - UI
    
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
        
//        if ([self.thread isKindOfClass:TSContactThread.class]) {
//            [self updateNavBarButtons];
//        }
        
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
        // Bind the items from the viewModel to the UI generation
        viewModel.onItemsChanged = { [weak self] (thread: TSThread, items: [[ConversationSettingsViewModel.Item]]) in
            DispatchQueue.main.async {
                // Keep the contentOffset between generation
                let oldContentOffset: CGPoint? = self?.scrollView.contentOffset
                
                // Clear out old content
                self?.stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
                
                // Generate new content
                items.enumerated().forEach { sectionIndex, section in
                    section.enumerated().forEach { index, item in
                        switch item.style {
                            case .header:
                                let targetView: ConversationSettingsHeaderView = ConversationSettingsHeaderView()
                                targetView.clipsToBounds = true
                                targetView.layer.cornerRadius = 8
                                
                                targetView.update(with: thread, threadName: item.title, contactSessionId: item.subtitle)
                                targetView.profilePictureTapped = { [weak self] in self?.viewModel.profilePictureTapped() }
                                targetView.displayNameTapped = { [weak self] in self?.viewModel.displayNameTapped() }
                                
                                self?.stackView.addArrangedSubview(targetView)
                                
                            case .search:
                                let targetView: ConversationSettingsActionView = ConversationSettingsActionView()
                                targetView.clipsToBounds = true
                                targetView.layer.cornerRadius = (ConversationSettingsActionView.minHeight / 2)
                                targetView.update(with: item.icon, color: Colors.text, title: item.title, canHighlight: false)
                                targetView.viewTapped = { [weak self] in self?.viewModel.itemTapped(item.id) }
                                
                                self?.stackView.addArrangedSubview(targetView)
                                
                            case .action, .actionDestructive:
                                let targetView: ConversationSettingsActionView = ConversationSettingsActionView()
                                targetView.clipsToBounds = true
                                targetView.layer.cornerRadius = 8
                                targetView.update(
                                    with: item.icon,
                                    color: (item.style == .actionDestructive ?
                                        Colors.destructive :
                                        Colors.text
                                    ),
                                    title: item.title,
                                    subtitle: item.subtitle
                                )
                                targetView.viewTapped = { [weak self] in self?.viewModel.itemTapped(item.id) }

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
                                            separatorView.leftAnchor.constraint(equalTo: separatorContainerView.leftAnchor, constant: 24),
                                            separatorView.rightAnchor.constraint(equalTo: separatorContainerView.rightAnchor, constant: -24)
                                        ])
                                }
                        }
                    }
                    
                    // Add a spacer at the bottom of each section (except for the last)
                    if sectionIndex != (items.count - 1) {
                        self?.stackView.addArrangedSubview(UIView.vSpacer(30))
                    }
                }
                
                // Restore contentOffset
                self?.scrollView.contentOffset = (oldContentOffset ?? CGPoint.zero)
            }
        }
        
        // Bind interactions
        
        viewModel.on(.editGroup) { [weak self] thread, _ in
            guard let threadId: String = thread.uniqueId else { return }
            
            let viewController: EditClosedGroupVC = EditClosedGroupVC(with: threadId)
            self?.navigationController?.pushViewController(viewController, animated: true)
        }
        
        viewModel.on(.disappearingMessages) { [weak self] thread, disappearingMessageConfiguration in
            guard let config: OWSDisappearingMessagesConfiguration = disappearingMessageConfiguration else { return }
            
            let viewController: ConversationDisappearingMessagesViewController = ConversationDisappearingMessagesViewController(thread: thread, configuration: config) { [weak self] in
                self?.viewModel.tryRefreshData(for: .disappearingMessages)
            }
            self?.navigationController?.pushViewController(viewController, animated: true)
        }
    }
}
