// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionMessagingKit

class ConversationDisappearingMessagesViewController: BaseVC {
    private let viewModel: ConversationDisappearingMessagesViewModel
    
    // MARK: - Initialization
    
    required init(configuration: OWSDisappearingMessagesConfiguration?) {
        self.viewModel = ConversationDisappearingMessagesViewModel(disappearingMessageConfiguration: configuration)
        
        super.init(nibName: nil, bundle: nil)
    }
    
//    - (void)toggleDisappearingMessages:(BOOL)flag
//    {
//        self.disappearingMessagesConfiguration.enabled = flag;
//
//        [self updateTableContents];
//    }
//    UISlider *slider = [UISlider new];
//    slider.maximumValue = (float)(strongSelf.disappearingMessagesDurations.count - 1);
//    slider.minimumValue = 0;
//    slider.tintColor = LKColors.accent;
//    slider.continuous = NO;
//    slider.value = strongSelf.disappearingMessagesConfiguration.durationIndex;
//    [slider addTarget:strongSelf action:@selector(durationSliderDidChange:)
//        forControlEvents:UIControlEventValueChanged];
//    [cell.contentView addSubview:slider];
//    [slider autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:topRow withOffset:6];
//    [slider autoPinEdge:ALEdgeLeading toEdge:ALEdgeLeading ofView:rowLabel];
//    [slider autoPinTrailingToSuperviewMargin];
//    [slider autoPinBottomToSuperviewMargin];
//    - (void)durationSliderDidChange:(UISlider *)slider
//    {
//        // snap the slider to a valid value
//        NSUInteger index = (NSUInteger)(slider.value + 0.5);
//        [slider setValue:index animated:YES];
//        NSNumber *numberOfSeconds = self.disappearingMessagesDurations[index];
//        self.disappearingMessagesConfiguration.durationSeconds = [numberOfSeconds unsignedIntValue];
//
//        [self updateDisappearingMessagesDurationLabel];
//    }
    
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
        
        // Add the content from the viewModel
        viewModel.items.enumerated().forEach { index, item in
            let optionView: ConversationSettingsOptionView = ConversationSettingsOptionView()
            optionView.clipsToBounds = true
            optionView.layer.cornerRadius = 8
            optionView.update(
                withColor: Colors.text,
                title: item.title,
                isActive: item.isActive
            )
//            optionView.viewTapped = { [weak self] in self?.viewModel.itemTapped(item.id) }

            stackView.addArrangedSubview(optionView)
            
            // Round relevant corners
            switch (index, viewModel.items.count) {
                case (_, 1): break
                case (0, _): optionView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                case (viewModel.items.count - 1, _): optionView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                default: optionView.layer.cornerRadius = 0
            }
            
            // Add a separator if there is an item after this one
            switch index {
                case viewModel.items.count - 1: break
                default:
                    let separatorContainerView: UIView = UIView()
                    separatorContainerView.backgroundColor = optionView.backgroundColor
                     
                    let separatorView: UIView = UIView.separator()
                    separatorView.backgroundColor = Colors.settingsBackground
                    
                    separatorContainerView.addSubview(separatorView)
                    stackView.addArrangedSubview(separatorContainerView)
                    
                    NSLayoutConstraint.activate([
                        separatorContainerView.heightAnchor.constraint(equalTo: separatorView.heightAnchor),
                        separatorView.leftAnchor.constraint(equalTo: separatorContainerView.leftAnchor, constant: 24),
                        separatorView.rightAnchor.constraint(equalTo: separatorContainerView.rightAnchor, constant: -24)
                    ])
            }
        }
        
        setupLayout()
        setupBinding()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        
//        if (self.disappearingMessagesConfiguration.isNewRecord && !self.disappearingMessagesConfiguration.isEnabled) {
//            // don't save defaults, else we'll unintentionally save the configuration and notify the contact.
//            return;
//        }
//
//        if (self.disappearingMessagesConfiguration.dictionaryValueDidChange) {
//            [LKStorage writeWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
//                [self.disappearingMessagesConfiguration saveWithTransaction:transaction];
//                OWSDisappearingConfigurationUpdateInfoMessage *infoMessage = [[OWSDisappearingConfigurationUpdateInfoMessage alloc]
//                             initWithTimestamp:[NSDate ows_millisecondTimeStamp]
//                                        thread:self.thread
//                                 configuration:self.disappearingMessagesConfiguration
//                           createdByRemoteName:nil
//                        createdInExistingGroup:NO];
//                [infoMessage saveWithTransaction:transaction];
//
//                SNExpirationTimerUpdate *expirationTimerUpdate = [SNExpirationTimerUpdate new];
//                BOOL isEnabled = self.disappearingMessagesConfiguration.enabled;
//                expirationTimerUpdate.duration = isEnabled ? self.disappearingMessagesConfiguration.durationSeconds : 0;
//                [SNMessageSender send:expirationTimerUpdate inThread:self.thread usingTransaction:transaction];
//            }];
//        }
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
//        viewModel.on(.editGroup) { [weak self] thread in
//            guard let threadId: String = thread.uniqueId else { return }
//
//            let viewController: EditClosedGroupVC = EditClosedGroupVC(with: threadId)
//            self?.navigationController?.pushViewController(viewController, animated: true)
//        }
    }
}
