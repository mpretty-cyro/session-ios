// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import SessionUIKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class ConversationSettingsHeaderView: UIView {
    var disposables: Set<AnyCancellable> = Set()
    
    // MARK: - Initialization
    
    convenience init() {
        self.init(frame: CGRect.zero)
        
        setupUI()
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        setupUI()
    }
    
    // MARK: - UI
    
    private let stackView: UIStackView = {
        let stackView: UIStackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = Values.mediumSpacing
        stackView.alignment = .center
        stackView.distribution = .equalSpacing
        
        let horizontalSpacing: CGFloat = (UIScreen.main.bounds.size.height < 568 ?
            Values.largeSpacing :
            Values.veryLargeSpacing
        )
        stackView.layoutMargins = UIEdgeInsets(
            top: Values.mediumSpacing,
            leading: horizontalSpacing,
            bottom: Values.mediumSpacing,
            trailing: horizontalSpacing
        )
        stackView.isLayoutMarginsRelativeArrangement = true
        
        return stackView
    }()
    
    fileprivate let profilePictureView: ProfilePictureView = {
        let view: ProfilePictureView = ProfilePictureView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.size = Values.largeProfilePictureSize
        
        return view
    }()
    
    fileprivate let displayNameContainer: UIView = {
        let view: UIView = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.accessibilityLabel = "Edit name text field"
        view.isAccessibilityElement = true
        
        return view
    }()
    
    private lazy var displayNameLabel: UILabel = {
        let label: UILabel = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.ows_mediumFont(withSize: Values.veryLargeFontSize)
        label.textColor = Colors.text
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        
        return label
    }()
    
    fileprivate let displayNameTextField: UITextField = {
        let textField: TextField = TextField(placeholder: "Enter a name", usesDefaultHeight: false)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.textAlignment = .center
        textField.accessibilityLabel = "Edit name text field"
        textField.alpha = 0
        
        return textField
    }()
    
    private let sessionIdLabel: SRCopyableLabel = {
        let label: SRCopyableLabel = SRCopyableLabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.ows_lightFont(withSize: Values.smallFontSize)
        label.textColor = Colors.text
        label.textAlignment = .center
        label.lineBreakMode = .byCharWrapping
        label.numberOfLines = 2
        
        return label
    }()
    
    private func setupUI() {
        backgroundColor = Colors.cellBackground
        
        addSubview(stackView)
        
        stackView.addArrangedSubview(profilePictureView)
        stackView.addArrangedSubview(displayNameContainer)
        stackView.addArrangedSubview(sessionIdLabel)
        
        displayNameContainer.addSubview(displayNameLabel)
        displayNameContainer.addSubview(displayNameTextField)
        
        setupLayout()
    }
    
    // MARK: - Layout
    
    private func setupLayout() {
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leftAnchor.constraint(equalTo: leftAnchor),
            stackView.rightAnchor.constraint(equalTo: rightAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            profilePictureView.widthAnchor.constraint(equalToConstant: profilePictureView.size),
            profilePictureView.heightAnchor.constraint(equalToConstant: profilePictureView.size),
            
            displayNameContainer.heightAnchor.constraint(equalToConstant: 40),
            
            displayNameLabel.topAnchor.constraint(equalTo: displayNameContainer.topAnchor),
            displayNameLabel.leftAnchor.constraint(equalTo: displayNameContainer.leftAnchor),
            displayNameLabel.rightAnchor.constraint(equalTo: displayNameContainer.rightAnchor),
            displayNameLabel.bottomAnchor.constraint(equalTo: displayNameContainer.bottomAnchor),
            displayNameTextField.topAnchor.constraint(equalTo: displayNameContainer.topAnchor),
            displayNameTextField.leftAnchor.constraint(equalTo: displayNameContainer.leftAnchor),
            displayNameTextField.rightAnchor.constraint(equalTo: displayNameContainer.rightAnchor),
            displayNameTextField.bottomAnchor.constraint(equalTo: displayNameContainer.bottomAnchor)
        ])
    }
    
    // MARK: - Content
    
    func updateProfile(with thread: TSThread) {
        profilePictureView.update(for: thread)
    }
    
    func update(with threadName: String?, contactSessionId: String?) {
        displayNameLabel.text = (threadName != nil && threadName?.isEmpty == false ? threadName : "Anonymous")
        sessionIdLabel.text = contactSessionId
        sessionIdLabel.isHidden = (contactSessionId?.isEmpty != false)
    }
    
    func update(isEditingDisplayName: Bool, animated: Bool) {
        let changes = { [weak self] in
            self?.displayNameLabel.alpha = (isEditingDisplayName ? 0 : 1)
            self?.displayNameTextField.alpha = (isEditingDisplayName ? 1 : 0)
        }
        
        if animated {
            UIView.animate(withDuration: 0.25, animations: changes)
        }
        else {
            changes()
        }
        
        if isEditingDisplayName {
            displayNameTextField.becomeFirstResponder()
        }
        else {
            displayNameTextField.resignFirstResponder()
        }
    }
}

// MARK: - Compose

extension CombineCompatible where Self: ConversationSettingsHeaderView {
    var textPublisher: AnyPublisher<String, Never> {
        return self.displayNameTextField.publisher(for: .editingChanged)
            .map { textField -> String in (textField.text ?? "") }
            .eraseToAnyPublisher()
    }
    
    var displayNameTapPublisher: AnyPublisher<Void, Never> {
        return self.displayNameContainer.tapPublisher
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    var profilePictureTapPublisher: AnyPublisher<Void, Never> {
        return self.profilePictureView.tapPublisher
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
