// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

class ConversationSettingsActionView: UIView {
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
        stackView.spacing = 12
        
        return stackView
    }()
    
    private lazy var imageView: UIImageView = {
        let imageView: UIImageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .trilinear
        
        return imageView
    }()
    
    private lazy var titleLabel: UILabel = {
        let label: UILabel = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.font = UIFont.systemFont(ofSize: Values.mediumFontSize)
        label.lineBreakMode = .byTruncatingTail
        
        return label
    }()
    
    private lazy var subtitleLabel: UILabel = {
        let label: UILabel = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.font = UIFont.systemFont(ofSize: Values.mediumFontSize)
        label.textColor = Colors.border//unimportant
        //label.font = UIFont.ows_lightFont(withSize: <#T##CGFloat#>) UIFont.systemFont(ofSize: Values.mediumFontSize)
        label.lineBreakMode = .byTruncatingTail
        
        return label
    }()
    
    private func setupUI() {
        backgroundColor = Colors.cellBackground
        addGestureRecognizer(tapGestureRecognizer)
        
        addSubview(highlightView)
        addSubview(stackView)
        
        stackView.addArrangedSubview(imageView)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(subtitleLabel)
        
        setupLayout()
    }
    
    // MARK: - Layout
    
    private func setupLayout() {
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: ConversationSettingsActionView.minHeight),
            
            highlightView.topAnchor.constraint(equalTo: topAnchor),
            highlightView.leftAnchor.constraint(equalTo: leftAnchor),
            highlightView.rightAnchor.constraint(equalTo: rightAnchor),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leftAnchor.constraint(equalTo: leftAnchor, constant: 24),
            stackView.rightAnchor.constraint(equalTo: rightAnchor, constant: -24),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            
//            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
//            imageView.leftAnchor.constraint(equalTo: leftAnchor, constant: 24),
            imageView.widthAnchor.constraint(equalToConstant: 24),
            imageView.heightAnchor.constraint(equalToConstant: 24)//,
            
//            titleLabel.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
//            titleLabel.leftAnchor.constraint(equalTo: imageView.rightAnchor, constant: 12),
//            titleLabel.rightAnchor.constraint(equalTo: rightAnchor, constant: -24)
        ])
    }
    
    // MARK: - Content
    
    func update(with icon: UIImage?, color: UIColor, title: String, subtitle: String? = nil, canHighlight: Bool = true) {
        imageView.image = icon
        imageView.tintColor = color
        titleLabel.text = title
        titleLabel.textColor = color
        subtitleLabel.text = subtitle
        highlightView.isHidden = !canHighlight
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
