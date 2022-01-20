// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

class ConversationSettingsOptionView: UIView {
    static let minHeight: CGFloat = 50
    
    var viewTapped: (() -> ())?
    
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
    
    private lazy var tapGestureRecognizer: UITapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(internalViewTapped))
    
    private lazy var highlightView: UIView = {
        let view: UIView = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = Colors.cellSelected
        view.alpha = 0
        
        return view
    }()
    
    private lazy var stackView: UIStackView = {
        let stackView: UIStackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.distribution = .fill
        stackView.spacing = (isIPhone5OrSmaller ? Values.smallSpacing : Values.mediumSpacing)
        
        return stackView
    }()
    
    private lazy var titleLabel: UILabel = {
        let label: UILabel = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.font = UIFont.systemFont(ofSize: Values.mediumFontSize)
        label.lineBreakMode = .byTruncatingTail
        
        return label
    }()
    
    private lazy var imageView: UIImageView = {
        let imageView: UIImageView = UIImageView(image: UIImage(named: "checkmark")?.withRenderingMode(.alwaysTemplate))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = Colors.accent
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .trilinear
        
        return imageView
    }()
    
    private func setupUI() {
        backgroundColor = Colors.cellBackground
        addGestureRecognizer(tapGestureRecognizer)
        
        addSubview(highlightView)
        addSubview(stackView)
        
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(imageView)
        
        setupLayout()
    }
    
    // MARK: - Layout
    
    private func setupLayout() {
        let edgeInset: CGFloat = (isIPhone5OrSmaller ? Values.mediumSpacing : Values.largeSpacing)
        
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: ConversationSettingsActionView.minHeight),
            
            highlightView.topAnchor.constraint(equalTo: topAnchor),
            highlightView.leftAnchor.constraint(equalTo: leftAnchor),
            highlightView.rightAnchor.constraint(equalTo: rightAnchor),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leftAnchor.constraint(equalTo: leftAnchor, constant: edgeInset),
            stackView.rightAnchor.constraint(equalTo: rightAnchor, constant: -edgeInset),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            imageView.widthAnchor.constraint(equalToConstant: 24),
            imageView.heightAnchor.constraint(equalToConstant: 24)
        ])
    }
    
    // MARK: - Content
    
    func update(withColor color: UIColor, title: String, isActive: Bool) {
        titleLabel.text = title
        titleLabel.textColor = color
        imageView.isHidden = !isActive
    }
    
    // MARK: - Interaction
    // Using the 'touches' callbacks rather than a button to replicate the UITableViewCell touch behaviour
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        
        highlightView.alpha = 1
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        
        highlightView.alpha = 0
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        
        highlightView.alpha = 0
    }
    
    @objc private func internalViewTapped() {
        viewTapped?()
    }
}
