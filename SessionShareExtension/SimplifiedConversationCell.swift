// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit

final class SimplifiedConversationCell: UITableViewCell {
    private static let conversationTypeImageHeight: CGFloat = 12
    
    // MARK: - Initialization
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setUpViewHierarchy()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViewHierarchy()
    }
    
    // MARK: - UI
    
    private lazy var conversationTypeImageViewWidthConstraint: NSLayoutConstraint = conversationTypeImageView.set(.width, to: 0)
    
    private lazy var stackView: UIStackView = {
        let stackView: UIStackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Values.mediumSpacing
        
        return stackView
    }()
    
    private lazy var accentLineView: UIView = {
        let result = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.themeBackgroundColor = .danger
        
        return result
    }()
    
    private lazy var profilePictureView: ProfilePictureView = {
        let view: ProfilePictureView = ProfilePictureView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    private lazy var conversationTitleStackView: UIStackView = {
        let stackView: UIStackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Values.smallSpacing
        
        return stackView
    }()
    
    private let conversationTypeImageView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.themeTintColor = .conversationButton_typeIcon
        result.contentMode = .scaleAspectFit
        result.isHidden = true
        result.set(.height, to: SimplifiedConversationCell.conversationTypeImageHeight)
        
        return result
    }()
    
    private lazy var displayNameLabel: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()
    
    // MARK: - Initialization
    
    private func setUpViewHierarchy() {
        themeBackgroundColor = .conversationButton_background
        
        let selectedBackgroundView = UIView()
        selectedBackgroundView.themeBackgroundColor = .highlighted(.conversationButton_background)
        self.selectedBackgroundView = selectedBackgroundView
        
        addSubview(stackView)
        
        stackView.addArrangedSubview(accentLineView)
        stackView.addArrangedSubview(profilePictureView)
        stackView.addArrangedSubview(conversationTitleStackView)
        
        conversationTitleStackView.addArrangedSubview(conversationTypeImageView)
        conversationTitleStackView.addArrangedSubview(displayNameLabel)
        conversationTitleStackView.addArrangedSubview(UIView.hSpacer(0))
        
        setupLayout()
    }
    
    // MARK: - Layout
    
    private func setupLayout() {
        accentLineView.set(.width, to: Values.accentLineThickness)
        accentLineView.set(.height, to: 68)
        
        profilePictureView.set(.width, to: Values.mediumProfilePictureSize)
        profilePictureView.set(.height, to: Values.mediumProfilePictureSize)
        profilePictureView.size = Values.mediumProfilePictureSize
        
        stackView.pin(to: self)
        conversationTitleStackView.set(.height, to: .height, of: stackView)
    }
    
    // MARK: - Updating
    
    public func update(with cellViewModel: SessionThreadViewModel) {
        accentLineView.alpha = (cellViewModel.threadIsBlocked == true ? 1 : 0)
        profilePictureView.update(
            publicKey: cellViewModel.threadId,
            threadVariant: cellViewModel.threadVariant,
            customImageData: cellViewModel.openGroupProfilePictureData,
            profile: cellViewModel.profile,
            additionalProfile: cellViewModel.additionalProfile
        )
        displayNameLabel.text = cellViewModel.displayName
        
        let targetImage: UIImage? = {
            switch cellViewModel.threadVariant {
                case .closedGroup: return UIImage(named: "Group")?.withRenderingMode(.alwaysTemplate)
                case .openGroup: return UIImage(named: "Globe")?.withRenderingMode(.alwaysTemplate)
                case .contact: return nil
            }
        }()
        conversationTypeImageView.isHidden = (cellViewModel.threadVariant == .contact)
        conversationTypeImageView.image = targetImage
        conversationTypeImageViewWidthConstraint.constant = (
            ((targetImage?.size.width ?? 1) / (targetImage?.size.height ?? 1)) *
            SimplifiedConversationCell.conversationTypeImageHeight
        )
    }
}
