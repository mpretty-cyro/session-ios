// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SignalUtilitiesKit

class ConversationSettingsHeaderView: UIView {
    var profilePictureTapped: (() -> ())?
    var displayNameTapped: (() -> ())?
    
    var isEditingDisplayName: Bool = false {
        didSet {
            guard isEditingDisplayName != oldValue else { return }
            
            let newValue: Bool = isEditingDisplayName
            
            UIView.animate(withDuration: 0.25) { [weak self] in
                self?.displayNameLabel.alpha = (newValue ? 0 : 1)
                self?.displayNameTextField.alpha = (newValue ? 1 : 0)
            }
            
            if isEditingDisplayName {
                displayNameTextField.becomeFirstResponder()
            }
            else {
                displayNameTextField.resignFirstResponder()
            }
        }
    }
    
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
    
    private lazy var profilePictureView: ProfilePictureView = {
        let view: ProfilePictureView = ProfilePictureView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.size = Values.largeProfilePictureSize
        
        let tapGestureRecognizer: UITapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(internalProfilePictureTapped))
        view.addGestureRecognizer(tapGestureRecognizer)
        
        return view
    }()
    
    private let displayNameContainer: UIView = {
        let view: UIView = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.accessibilityLabel = "Edit name text field"
        view.isAccessibilityElement = true
        
        let tapGestureRecognizer: UITapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(internalDisplayNameTapped))
        view.addGestureRecognizer(tapGestureRecognizer)
        
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
    
    private let displayNameTextField: UIView = {
        let view: TextField = TextField(placeholder: "Enter a name", usesDefaultHeight: false)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.textAlignment = .center
        view.accessibilityLabel = "Edit name text field"
        view.alpha = 0
        
        return view
    }()
    
    private lazy var sessionIdLabel: SRCopyableLabel = {
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
    
    func update(with thread: TSThread, threadName: String?, contactSessionId: String?) {
        profilePictureView.update(for: thread)
        displayNameLabel.text = (threadName != nil && threadName?.isEmpty == false ? threadName : "Anonymous")
        sessionIdLabel.text = contactSessionId
        sessionIdLabel.isHidden = (contactSessionId?.isEmpty != false)
    }
    
    // MARK: - Interaction
    
    @objc private func internalProfilePictureTapped() {
        profilePictureTapped?()
    }
    
    @objc private func internalDisplayNameTapped() {
        displayNameTapped?()
    }
}
