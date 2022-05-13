// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionMessagingKit

final class MediaPlaceholderView: UIView {
    private static let iconSize: CGFloat = 24
    private static let iconImageViewSize: CGFloat = 40
    
    // MARK: - Lifecycle
    
    init(item: ConversationViewModel.Item, textColor: UIColor) {
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy(item: item, textColor: textColor)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(viewItem:textColor:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(viewItem:textColor:) instead.")
    }
    
    private func setUpViewHierarchy(
        item: ConversationViewModel.Item,
        textColor: UIColor
    ) {
        let (iconName, attachmentDescription): (String, String) = {
            guard
                item.interactionVariant == .standardIncoming,
                let attachment: Attachment = item.attachments?.first
            else {
                return ("actionsheet_document_black", "file") // Should never occur
            }
            
            if attachment.isAudio { return ("attachment_audio", "audio") }
            if attachment.isImage || attachment.isVideo { return ("actionsheet_camera_roll_black", "media") }
            
            return ("actionsheet_document_black", "file")
        }()
        
        // Image view
        let imageView = UIImageView(
            image: UIImage(named: iconName)?
                .withRenderingMode(.alwaysTemplate)
                .resizedImage(
                    to: CGSize(
                        width: MediaPlaceholderView.iconSize,
                        height: MediaPlaceholderView.iconSize
                    )
                )
        )
        imageView.tintColor = textColor
        imageView.contentMode = .center
        imageView.set(.width, to: MediaPlaceholderView.iconImageViewSize)
        imageView.set(.height, to: MediaPlaceholderView.iconImageViewSize)
        
        // Body label
        let titleLabel = UILabel()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.text = "Tap to download \(attachmentDescription)"
        titleLabel.textColor = textColor
        titleLabel.font = .systemFont(ofSize: Values.mediumFontSize)
        
        // Stack view
        let stackView = UIStackView(arrangedSubviews: [ imageView, titleLabel ])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.layoutMargins = UIEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 12)
        addSubview(stackView)
        stackView.pin(to: self, withInset: Values.smallSpacing)
    }
}
