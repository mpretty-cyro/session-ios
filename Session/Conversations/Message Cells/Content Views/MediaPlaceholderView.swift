// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionMessagingKit
import SessionUIKit

final class MediaPlaceholderView: UIView {
    private static let iconImageViewSize: CGFloat = 18
    
    // MARK: - Lifecycle
    
    init(cellViewModel: MessageViewModel, textColor: ThemeValue) {
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy(cellViewModel: cellViewModel, textColor: textColor)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(viewItem:textColor:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(viewItem:textColor:) instead.")
    }
    
    private func setUpViewHierarchy(
        cellViewModel: MessageViewModel,
        textColor: ThemeValue
    ) {
        // Image view
        let imageView = UIImageView(
            image: UIImage(named: "icon_attachment")?
                .withRenderingMode(.alwaysTemplate)
        )
        imageView.themeTintColor = textColor
        imageView.contentMode = .scaleAspectFit
        imageView.set(
            .width,
            to: (
                MediaPlaceholderView.iconImageViewSize *
                ((imageView.image?.size.width ?? 1) / (imageView.image?.size.height ?? 1))
            )
        )
        imageView.set(.height, to: MediaPlaceholderView.iconImageViewSize)
        
        // Body label (if there are multiple attachments then add their types)
        let attachments: [Attachment] = (cellViewModel.attachments ?? [])
        let totalFileSize: UInt = attachments
            .map { $0.byteCount }
            .reduce(0, +)
        let fileTypes: String = {
            guard cellViewModel.variant == .standardIncoming else {
                return "file\(attachments.count == 1 ? "" : "s")"
            }
            
            if !attachments.contains(where: { !$0.isAudio }) { return "audio" }
            if !attachments.contains(where: { !$0.isImage }) {
                return "image\(attachments.count == 1 ? "" : "s")"
            }
            if !attachments.contains(where: { !$0.isVideo }) {
                return "video\(attachments.count == 1 ? "" : "s")"
            }
            
            return "file\(attachments.count == 1 ? "" : "s")"
        }()
        let titleLabel = UILabel()
        titleLabel.font = .systemFont(ofSize: Values.mediumFontSize)
        titleLabel.text = [
            Format.fileSize(totalFileSize),
            (attachments.count == 1 ?
                nil :
                String(
                    format: "ATTACHMENT_DOWNLOAD_INFO_MULTIPLE".localized(),
                    attachments.count,
                    fileTypes
                )
            ),
            (attachments.count > 1 ?
                nil :
                String(
                    format: "ATTACHMENT_DOWNLOAD_INFO".localized(),
                    fileTypes
                )
            )
        ]
        .compactMap { $0 }
        .reversed(if: CurrentAppContext().isRTL)
        .joined(separator: " • ")
        titleLabel.themeTextColor = textColor
        titleLabel.lineBreakMode = .byTruncatingTail
        
        // Stack view
        let stackView = UIStackView(arrangedSubviews: [ imageView, titleLabel ])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Values.smallSpacing
        addSubview(stackView)
        
        stackView.pin(.top, to: .top, of: self, withInset: Values.smallSpacing)
        stackView.pin(.leading, to: .leading, of: self, withInset: Values.mediumSpacing)
        stackView.pin(.trailing, to: .trailing, of: self, withInset: -Values.mediumSpacing)
        stackView.pin(.bottom, to: .bottom, of: self, withInset: -Values.smallSpacing)
    }
}
