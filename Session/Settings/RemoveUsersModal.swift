// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SignalUtilitiesKit

final class RemoveUsersModal: Modal {
    private let threadId: String
    private let contacts: [(id: String, name: String?)]
    
    // MARK: - Initialization
    
    init(
        threadId: String,
        contacts: [(id: String, name: String?)],
        targetView: UIView? = nil,
        afterClosed: (() -> ())? = nil
    ) {
        self.threadId = threadId
        self.contacts = contacts
        
        super.init(targetView: targetView, afterClosed: afterClosed)
        
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Components
    
    private lazy var titleLabel: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.text = (contacts.count <= 1 ?
            "GROUP_REMOVE_USER_ACTION".localized() :
            "GROUP_REMOVE_USERS_ACTION".localized()
        )
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var explanationLabel: UILabel = {
        let result = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.attributedText = ConfirmationModal.boldedUserString(
            contactNames: contacts
                // Prioritise displaying actual names over truncated ids
                .sorted { lhs, rhs in (lhs.name != nil || rhs.name == nil) }
                .map { id, name in (name ?? Profile.truncated(id: id, truncating: .middle)) },
            singleUserString: "GROUP_REMOVE_USER_CONFIRMATION_EXPLANATION_SINGLE".localized(),
            twoUserString: "GROUP_REMOVE_USER_CONFIRMATION_EXPLANATION_TWO".localized(),
            manyUserString: "GROUP_REMOVE_USER_CONFIRMATION_EXPLANATION_MANY".localized()
        )
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var removeUserRadio: RadioButton = {
        let result: RadioButton = RadioButton(size: .small) { [weak self] radio in
            self?.removeUserAndMessagesRadio.update(isSelected: false)
            radio.update(isSelected: true)
        }
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.text = (contacts.count == 1 ?
            "GROUP_REMOVE_USER_OPTION".localized() :
            "GROUP_REMOVE_USERS_OPTION".localized()
        )
        result.update(isSelected: true)
        
        return result
    }()
    
    private lazy var removeUserAndMessagesRadio: RadioButton = {
        let result: RadioButton = RadioButton(size: .small) { [weak self] radio in
            self?.removeUserRadio.update(isSelected: false)
            radio.update(isSelected: true)
        }
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.text = (contacts.count == 1 ?
            "GROUP_REMOVE_USER_AND_MESSAGES_OPTION".localized() :
            "GROUP_REMOVE_USERS_AND_MESSAGES_OPTION".localized()
        )
        
        return result
    }()
    
    private lazy var clearDataButton: UIButton = {
        let result: UIButton = Modal.createButton(
            title: "GROUP_ACTION_REMOVE".localized(),
            titleColor: .danger
        )
        result.addTarget(self, action: #selector(removeUsersAndMessages), for: UIControl.Event.touchUpInside)
        
        return result
    }()
    
    private lazy var buttonStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ clearDataButton, cancelButton ])
        result.axis = .horizontal
        result.distribution = .fillEqually
        
        return result
    }()
    
    private lazy var contentStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [
            titleLabel,
            explanationLabel,
            removeUserRadio,
            UIView.separator(),
            removeUserAndMessagesRadio
        ])
        result.axis = .vertical
        result.spacing = Values.smallSpacing
        result.isLayoutMarginsRelativeArrangement = true
        result.layoutMargins = UIEdgeInsets(
            top: Values.largeSpacing,
            leading: Values.largeSpacing,
            bottom: Values.verySmallSpacing,
            trailing: Values.largeSpacing
        )
        
        return result
    }()
    
    private lazy var mainStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ contentStackView, buttonStackView ])
        result.axis = .vertical
        result.spacing = Values.largeSpacing - Values.smallFontSize / 2
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    override func populateContentView() {
        contentView.addSubview(mainStackView)
        
        mainStackView.pin(to: contentView)
    }
    
    // MARK: - Interaction
    
    @objc private func removeUsersAndMessages() {
        guard removeUserAndMessagesRadio.isSelected else {
            removeUsersOnly()
            return
        }
        
        ModalActivityIndicatorViewController.present(fromViewController: self, canCancel: false) { [weak self] _ in
        }
    }
    
    private func removeUsersOnly() {
        let threadId: String = self.threadId
        let contactIds: [String] = self.contacts.map { id, _ in id }
        
        ModalActivityIndicatorViewController.present(fromViewController: self, canCancel: false) { [weak self] _ in
            Storage.shared
                .writeAsync(
                    updates: { db in
                        let contactThreads: [SessionThread] = try contactIds
                            .map { try SessionThread.fetchOrCreate(db, id: $0, variant: .contact) }
                        
                        guard
                            let encryptionKeyPair: ClosedGroupKeyPair = try ClosedGroupKeyPair .fetchLatestKeyPair(db, threadId: threadId)
                        else { return }
                        
                        // Send a deletion message to each user to be removed
                        for thread in contactThreads {
                            // TODO: Encrypt this for the target user
                            let lastEncryptionKey: Data = encryptionKeyPair.secretKey
                            
                            try MessageSender.send(
                                db,
                                message: GroupDeleteMessage(
                                    publicKey: Data(hex: threadId),
                                    lastEncryptionKey: lastEncryptionKey
                                ),
                                interactionId: nil,
                                in: thread
                            )
                        }
                    },
                    completion: { _, result in
                        DispatchQueue.main.async {
                            switch result {
                                case .failure:
                                    self?.dismiss(animated: true) {
                                    }
                                    
                                case .success:
                                    self?.dismiss(animated: true, completion: nil) // Dismiss the loader
                            }
                        }
                    }
                )
        }
    }
}
