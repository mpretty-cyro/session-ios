// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionMessagingKit

class ConversationDisappearingMessagesViewController: BaseVC {
    private let viewModel: ConversationDisappearingMessagesViewModel
    
    // MARK: - Initialization
    
    required init(thread: TSThread, configuration: OWSDisappearingMessagesConfiguration, dataChanged: @escaping () -> ()) {
        self.viewModel = ConversationDisappearingMessagesViewModel(thread: thread, disappearingMessagesConfiguration: configuration, dataChanged: dataChanged)
        
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
        
        view.addSubview(scrollView)
        
        scrollView.addSubview(stackView)
        
        setupLayout()
        setupBinding()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        viewModel.trySaveChanges()
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
        viewModel.onItemsChanged = { [weak self] items in
            DispatchQueue.main.async {
                // Keep the contentOffset between generation
                let oldContentOffset: CGPoint? = self?.scrollView.contentOffset
                
                // Clear out old content
                self?.stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
                
                // Generate new content
                items.enumerated().forEach { index, item in
                    let optionView: ConversationSettingsOptionView = ConversationSettingsOptionView()
                    optionView.clipsToBounds = true
                    optionView.layer.cornerRadius = 8
                    optionView.update(
                        withColor: Colors.text,
                        title: item.title,
                        isActive: item.isActive
                    )
                    optionView.viewTapped = { [weak self] in self?.viewModel.itemTapped(index) }

                    self?.stackView.addArrangedSubview(optionView)
                    
                    // Round relevant corners
                    switch (index, items.count) {
                        case (_, 1): break
                        case (0, _): optionView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                        case (items.count - 1, _): optionView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                        default: optionView.layer.cornerRadius = 0
                    }
                    
                    // Add a separator if there is an item after this one
                    switch index {
                        case items.count - 1: break
                        default:
                            let separatorContainerView: UIView = UIView()
                            separatorContainerView.backgroundColor = optionView.backgroundColor
                             
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
                
                // Restore contentOffset
                self?.scrollView.contentOffset = (oldContentOffset ?? CGPoint.zero)
            }
        }
    }
}
