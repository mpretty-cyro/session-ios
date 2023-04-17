// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit

public final class FullConversationCell: UITableViewCell {
    public static let unreadCountViewSize: CGFloat = 20
    private static let statusIndicatorSize: CGFloat = 14
    
    // MARK: - UI
    
    private let accentLineView: UIView = UIView()

    private lazy var profilePictureView: ProfilePictureView = ProfilePictureView()

    private lazy var displayNameLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()

    private lazy var unreadCountView: UIView = {
        let result: UIView = UIView()
        result.clipsToBounds = true
        result.themeBackgroundColor = .conversationButton_unreadBubbleBackground
        result.layer.cornerRadius = (FullConversationCell.unreadCountViewSize / 2)
        result.set(.width, greaterThanOrEqualTo: FullConversationCell.unreadCountViewSize)
        result.set(.height, to: FullConversationCell.unreadCountViewSize)
        
        return result
    }()

    private lazy var unreadCountLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.verySmallFontSize)
        result.themeTextColor = .conversationButton_unreadBubbleText
        result.textAlignment = .center
        
        return result
    }()

    private lazy var hasMentionView: UIView = {
        let result: UIView = UIView()
        result.clipsToBounds = true
        result.themeBackgroundColor = .conversationButton_unreadBubbleBackground
        result.layer.cornerRadius = (FullConversationCell.unreadCountViewSize / 2)
        result.set(.width, to: FullConversationCell.unreadCountViewSize)
        result.set(.height, to: FullConversationCell.unreadCountViewSize)
        
        return result
    }()

    private lazy var hasMentionLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.verySmallFontSize)
        result.themeTextColor = .conversationButton_unreadBubbleText
        result.text = "@"
        result.textAlignment = .center
        
        return result
    }()

    private lazy var isPinnedIcon: UIImageView = {
        let result: UIImageView = UIImageView(
            image: UIImage(named: "Pin")?
                .withRenderingMode(.alwaysTemplate)
        )
        result.clipsToBounds = true
        result.themeTintColor = .textSecondary
        result.contentMode = .scaleAspectFit
        result.set(.width, to: FullConversationCell.unreadCountViewSize)
        result.set(.height, to: FullConversationCell.unreadCountViewSize)
        
        return result
    }()

    private lazy var timestampLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textSecondary
        result.lineBreakMode = .byTruncatingTail
        result.alpha = Values.lowOpacity
        
        return result
    }()

    private lazy var snippetLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()

    private lazy var typingIndicatorView = TypingIndicatorView()

    private lazy var statusIndicatorView: UIImageView = {
        let result: UIImageView = UIImageView()
        result.clipsToBounds = true
        result.contentMode = .scaleAspectFit
        
        return result
    }()

    private lazy var topLabelStackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.axis = .horizontal
        result.alignment = .center
        result.spacing = Values.smallSpacing / 2 // Effectively Values.smallSpacing because there'll be spacing before and after the invisible spacer
        
        return result
    }()

    private lazy var bottomLabelStackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.axis = .horizontal
        result.alignment = .center
        result.spacing = Values.smallSpacing / 2 // Effectively Values.smallSpacing because there'll be spacing before and after the invisible spacer
        
        return result
    }()

    // MARK: - Initialization
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        setUpViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViewHierarchy()
    }

    private func setUpViewHierarchy() {
        let cellHeight: CGFloat = 68
        
        // Background color
        themeBackgroundColor = .conversationButton_background
        
        // Highlight color
        let selectedBackgroundView = UIView()
        selectedBackgroundView.themeBackgroundColor = .highlighted(.conversationButton_background)
        self.selectedBackgroundView = selectedBackgroundView
        
        // Accent line view
        accentLineView.set(.width, to: Values.accentLineThickness)
        accentLineView.set(.height, to: cellHeight)
        
        // Profile picture view
        let profilePictureViewSize = Values.mediumProfilePictureSize
        profilePictureView.set(.width, to: profilePictureViewSize)
        profilePictureView.set(.height, to: profilePictureViewSize)
        profilePictureView.size = profilePictureViewSize
        
        // Unread count view
        unreadCountView.addSubview(unreadCountLabel)
        unreadCountLabel.setCompressionResistanceHigh()
        unreadCountLabel.pin([ VerticalEdge.top, VerticalEdge.bottom ], to: unreadCountView)
        unreadCountView.pin(.leading, to: .leading, of: unreadCountLabel, withInset: -4)
        unreadCountView.pin(.trailing, to: .trailing, of: unreadCountLabel, withInset: 4)
        
        // Has mention view
        hasMentionView.addSubview(hasMentionLabel)
        hasMentionLabel.setCompressionResistanceHigh()
        hasMentionLabel.pin(to: hasMentionView)
        
        // Label stack view
        let topLabelSpacer = UIView.hStretchingSpacer()
        [ displayNameLabel, isPinnedIcon, unreadCountView, hasMentionView, topLabelSpacer, timestampLabel ].forEach{ view in
            topLabelStackView.addArrangedSubview(view)
        }
        
        let snippetLabelContainer = UIView()
        snippetLabelContainer.addSubview(snippetLabel)
        snippetLabelContainer.addSubview(typingIndicatorView)
        
        let bottomLabelSpacer = UIView.hStretchingSpacer()
        [ snippetLabelContainer, bottomLabelSpacer, statusIndicatorView ].forEach{ view in
            bottomLabelStackView.addArrangedSubview(view)
        }
        
        let labelContainerView = UIStackView(arrangedSubviews: [ topLabelStackView, bottomLabelStackView ])
        labelContainerView.axis = .vertical
        labelContainerView.alignment = .fill
        labelContainerView.spacing = 6
        labelContainerView.isUserInteractionEnabled = false
        
        // Main stack view
        let stackView = UIStackView(arrangedSubviews: [ accentLineView, profilePictureView, labelContainerView ])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Values.mediumSpacing
        contentView.addSubview(stackView)
        
        // Constraints
        accentLineView.pin(.top, to: .top, of: contentView)
        accentLineView.pin(.bottom, to: .bottom, of: contentView)
        timestampLabel.setContentCompressionResistancePriority(.required, for: NSLayoutConstraint.Axis.horizontal)
        
        // HACK: The 4 lines below are part of a workaround for a weird layout bug
        topLabelStackView.set(.height, to: 20)
        topLabelSpacer.set(.height, to: 20)
        
        bottomLabelStackView.set(.height, to: 18)
        bottomLabelSpacer.set(.height, to: 18)
        
        statusIndicatorView.set(.width, to: FullConversationCell.statusIndicatorSize)
        statusIndicatorView.set(.height, to: FullConversationCell.statusIndicatorSize)
        
        snippetLabel.pin(to: snippetLabelContainer)
        
        typingIndicatorView.pin(.leading, to: .leading, of: snippetLabelContainer)
        typingIndicatorView.centerYAnchor.constraint(equalTo: snippetLabel.centerYAnchor).isActive = true
        
        stackView.pin([ UIView.VerticalEdge.bottom, UIView.VerticalEdge.top, UIView.HorizontalEdge.leading ], to: contentView)
        stackView.pin(.trailing, to: .trailing, of: contentView, withInset: -Values.mediumSpacing)
    }
    
    // MARK: - Content
    
    // MARK: --Search Results
    
    public func updateForMessageSearchResult(with cellViewModel: SessionThreadViewModel, searchText: String) {
        profilePictureView.update(
            publicKey: cellViewModel.threadId,
            profile: cellViewModel.profile,
            additionalProfile: cellViewModel.additionalProfile,
            threadVariant: cellViewModel.threadVariant,
            openGroupProfilePictureData: cellViewModel.openGroupProfilePictureData,
            useFallbackPicture: (cellViewModel.threadVariant == .openGroup && cellViewModel.openGroupProfilePictureData == nil)
        )
        
        isPinnedIcon.isHidden = true
        unreadCountView.isHidden = true
        hasMentionView.isHidden = true
        timestampLabel.isHidden = false
        timestampLabel.text = cellViewModel.lastInteractionDate.formattedForDisplay
        bottomLabelStackView.isHidden = false
        
        ThemeManager.onThemeChange(observer: displayNameLabel) { [weak displayNameLabel] theme, _ in
            guard let textColor: UIColor = theme.color(for: .textPrimary) else { return }
                
            displayNameLabel?.attributedText = NSMutableAttributedString(
                string: cellViewModel.displayName,
                attributes: [ .foregroundColor: textColor ]
            )
        }
        
        ThemeManager.onThemeChange(observer: displayNameLabel) { [weak self, weak snippetLabel] theme, _ in
            guard let textColor: UIColor = theme.color(for: .textPrimary) else { return }
            
            snippetLabel?.attributedText = self?.getHighlightedSnippet(
                content: Interaction.previewText(
                    variant: (cellViewModel.interactionVariant ?? .standardIncoming),
                    body: cellViewModel.interactionBody,
                    authorDisplayName: cellViewModel.authorName(for: .contact),
                    attachmentDescriptionInfo: cellViewModel.interactionAttachmentDescriptionInfo,
                    attachmentCount: cellViewModel.interactionAttachmentCount,
                    isOpenGroupInvitation: (cellViewModel.interactionIsOpenGroupInvitation == true)
                ),
                authorName: (cellViewModel.authorId != cellViewModel.currentUserPublicKey ?
                    cellViewModel.authorName(for: .contact) :
                    nil
                ),
                currentUserPublicKey: cellViewModel.currentUserPublicKey,
                currentUserBlindedPublicKey: cellViewModel.currentUserBlindedPublicKey,
                searchText: searchText.lowercased(),
                fontSize: Values.smallFontSize,
                textColor: textColor
            )
        }
    }
    
    public func updateForContactAndGroupSearchResult(with cellViewModel: SessionThreadViewModel, searchText: String) {
        profilePictureView.update(
            publicKey: cellViewModel.threadId,
            profile: cellViewModel.profile,
            additionalProfile: cellViewModel.additionalProfile,
            threadVariant: cellViewModel.threadVariant,
            openGroupProfilePictureData: cellViewModel.openGroupProfilePictureData,
            useFallbackPicture: (cellViewModel.threadVariant == .openGroup && cellViewModel.openGroupProfilePictureData == nil)
        )
        
        isPinnedIcon.isHidden = true
        unreadCountView.isHidden = true
        hasMentionView.isHidden = true
        timestampLabel.isHidden = true
        
        ThemeManager.onThemeChange(observer: displayNameLabel) { [weak self, weak displayNameLabel] theme, _ in
            guard let textColor: UIColor = theme.color(for: .textPrimary) else { return }
            
            displayNameLabel?.attributedText = self?.getHighlightedSnippet(
                content: cellViewModel.displayName,
                currentUserPublicKey: cellViewModel.currentUserPublicKey,
                currentUserBlindedPublicKey: cellViewModel.currentUserBlindedPublicKey,
                searchText: searchText.lowercased(),
                fontSize: Values.mediumFontSize,
                textColor: textColor
            )
        }
        
        switch cellViewModel.threadVariant {
            case .contact, .openGroup: bottomLabelStackView.isHidden = true
                
            case .closedGroup:
                bottomLabelStackView.isHidden = (cellViewModel.threadMemberNames ?? "").isEmpty
        
                ThemeManager.onThemeChange(observer: displayNameLabel) { [weak self, weak snippetLabel] theme, _ in
                    guard let textColor: UIColor = theme.color(for: .textPrimary) else { return }
                    if cellViewModel.threadVariant == .closedGroup {
                        snippetLabel?.attributedText = self?.getHighlightedSnippet(
                            content: (cellViewModel.threadMemberNames ?? ""),
                            currentUserPublicKey: cellViewModel.currentUserPublicKey,
                            currentUserBlindedPublicKey: cellViewModel.currentUserBlindedPublicKey,
                            searchText: searchText.lowercased(),
                            fontSize: Values.smallFontSize,
                            textColor: textColor
                        )
                    }
                }
        }
    }

    // MARK: --Standard
    
    public func update(with cellViewModel: SessionThreadViewModel) {
        let unreadCount: UInt = (cellViewModel.threadUnreadCount ?? 0)
        let themeBackgroundColor: ThemeValue = (unreadCount > 0 ?
            .conversationButton_unreadBackground :
            .conversationButton_background
        )
        self.themeBackgroundColor = themeBackgroundColor
        self.selectedBackgroundView?.themeBackgroundColor = .highlighted(themeBackgroundColor)
        
        if cellViewModel.threadIsBlocked == true {
            accentLineView.themeBackgroundColor = .danger
            accentLineView.alpha = 1
        }
        else {
            accentLineView.themeBackgroundColor = .conversationButton_unreadStripBackground
            accentLineView.alpha = (unreadCount > 0 ? 1 : 0)
        }
        
        isPinnedIcon.isHidden = !cellViewModel.threadIsPinned
        unreadCountView.isHidden = (unreadCount <= 0)
        unreadCountLabel.text = (unreadCount < 10000 ? "\(unreadCount)" : "9999+")
        unreadCountLabel.font = .boldSystemFont(
            ofSize: (unreadCount < 10000 ? Values.verySmallFontSize : 8)
        )
        hasMentionView.isHidden = !(
            ((cellViewModel.threadUnreadMentionCount ?? 0) > 0) &&
            (cellViewModel.threadVariant == .closedGroup || cellViewModel.threadVariant == .openGroup)
        )
        profilePictureView.update(
            publicKey: cellViewModel.threadId,
            profile: cellViewModel.profile,
            additionalProfile: cellViewModel.additionalProfile,
            threadVariant: cellViewModel.threadVariant,
            openGroupProfilePictureData: cellViewModel.openGroupProfilePictureData,
            useFallbackPicture: (
                cellViewModel.threadVariant == .openGroup &&
                cellViewModel.openGroupProfilePictureData == nil
            ),
            showMultiAvatarForClosedGroup: true
        )
        displayNameLabel.text = cellViewModel.displayName
        timestampLabel.text = cellViewModel.lastInteractionDate.formattedForDisplay
        
        if cellViewModel.threadContactIsTyping == true {
            snippetLabel.text = ""
            typingIndicatorView.isHidden = false
            typingIndicatorView.startAnimation()
        }
        else {
            typingIndicatorView.isHidden = true
            typingIndicatorView.stopAnimation()
            
            ThemeManager.onThemeChange(observer: snippetLabel) { [weak self, weak snippetLabel] theme, _ in
                if cellViewModel.interactionVariant == .infoClosedGroupCurrentUserLeaving {
                    guard let textColor: UIColor = theme.color(for: .textSecondary) else { return }
                    
                    self?.displayNameLabel.themeTextColor = .textSecondary
                    
                    snippetLabel?.attributedText = self?.getSnippet(
                        cellViewModel: cellViewModel,
                        textColor: textColor
                    )
                } else if cellViewModel.interactionVariant == .infoClosedGroupCurrentUserErrorLeaving {
                    guard let textColor: UIColor = theme.color(for: .danger) else { return }
                    
                    self?.displayNameLabel.themeTextColor = .textPrimary
                    
                    snippetLabel?.attributedText = self?.getSnippet(
                        cellViewModel: cellViewModel,
                        textColor: textColor
                    )
                } else {
                    guard let textColor: UIColor = theme.color(for: .textPrimary) else { return }
                    
                    self?.displayNameLabel.themeTextColor = .textPrimary
                    
                    snippetLabel?.attributedText = self?.getSnippet(
                        cellViewModel: cellViewModel,
                        textColor: textColor
                    )
                }
            }
        }
        
        let stateInfo = cellViewModel.interactionState?.statusIconInfo(
            variant: (cellViewModel.interactionVariant ?? .standardOutgoing),
            hasAtLeastOneReadReceipt: (cellViewModel.interactionHasAtLeastOneReadReceipt ?? false)
        )
        statusIndicatorView.image = stateInfo?.image
        statusIndicatorView.themeTintColor = stateInfo?.themeTintColor
        statusIndicatorView.isHidden = (
            cellViewModel.interactionVariant != .standardOutgoing &&
            cellViewModel.interactionState != .skipped
        )
    }
    
    public func optimisticUpdate(
        isMuted: Bool? = nil,
        isPinned: Bool? = nil,
        hasUnread: Bool? = nil
    ) {
        if let isMuted: Bool = isMuted {
            if isMuted {
                
            } else {
                
            }
        }
        
        if let isPinned: Bool = isPinned {
            isPinnedIcon.isHidden = !isPinned
        }
        
        if let hasUnread: Bool = hasUnread {
            if hasUnread {
                unreadCountView.isHidden = false
                unreadCountLabel.text = "1"
                unreadCountLabel.font = .boldSystemFont(ofSize: Values.verySmallFontSize)
                accentLineView.alpha = 1
            } else {
                unreadCountView.isHidden = true
                accentLineView.alpha = 0
            }
        }
    }
    
    // MARK: - Snippet generation

    private func getSnippet(
        cellViewModel: SessionThreadViewModel,
        textColor: UIColor
    ) -> NSMutableAttributedString {
        // If we don't have an interaction then do nothing
        guard cellViewModel.interactionId != nil else { return NSMutableAttributedString() }
        
        let result = NSMutableAttributedString()
        
        if Date().timeIntervalSince1970 < (cellViewModel.threadMutedUntilTimestamp ?? 0) {
            result.append(NSAttributedString(
                string: "\u{e067}  ",
                attributes: [
                    .font: UIFont.ows_elegantIconsFont(10),
                    .foregroundColor: textColor
                ]
            ))
        }
        else if cellViewModel.threadOnlyNotifyForMentions == true {
            let imageAttachment = NSTextAttachment()
            imageAttachment.image = UIImage(named: "NotifyMentions.png")?.withTint(textColor)
            imageAttachment.bounds = CGRect(x: 0, y: -2, width: Values.smallFontSize, height: Values.smallFontSize)
            
            let imageString = NSAttributedString(attachment: imageAttachment)
            result.append(imageString)
            result.append(NSAttributedString(
                string: "  ",
                attributes: [
                    .font: UIFont.ows_elegantIconsFont(10),
                    .foregroundColor: textColor
                ]
            ))
        }
        
        if
            (cellViewModel.threadVariant == .closedGroup || cellViewModel.threadVariant == .openGroup) &&
            (cellViewModel.interactionVariant?.isGroupControlMessage == false)
        {
            let authorName: String = cellViewModel.authorName(for: cellViewModel.threadVariant)
            
            result.append(NSAttributedString(
                string: "\(authorName): ",
                attributes: [ .foregroundColor: textColor ]
            ))
        }
        
        let previewText: String = {
            if cellViewModel.interactionVariant == .infoClosedGroupCurrentUserErrorLeaving { return "group_leave_error".localized() }
            return Interaction.previewText(
                variant: (cellViewModel.interactionVariant ?? .standardIncoming),
                body: cellViewModel.interactionBody,
                threadContactDisplayName: cellViewModel.threadContactName(),
                authorDisplayName: cellViewModel.authorName(for: cellViewModel.threadVariant),
                attachmentDescriptionInfo: cellViewModel.interactionAttachmentDescriptionInfo,
                attachmentCount: cellViewModel.interactionAttachmentCount,
                isOpenGroupInvitation: (cellViewModel.interactionIsOpenGroupInvitation == true)
            )
        }()
        
        result.append(NSAttributedString(
            string: MentionUtilities.highlightMentionsNoAttributes(
                in: previewText,
                threadVariant: cellViewModel.threadVariant,
                currentUserPublicKey: cellViewModel.currentUserPublicKey,
                currentUserBlindedPublicKey: cellViewModel.currentUserBlindedPublicKey
            ),
            attributes: [ .foregroundColor: textColor ]
        ))
            
        return result
    }
    
    private func getHighlightedSnippet(
        content: String,
        authorName: String? = nil,
        currentUserPublicKey: String,
        currentUserBlindedPublicKey: String?,
        searchText: String,
        fontSize: CGFloat,
        textColor: UIColor
    ) -> NSAttributedString {
        guard !content.isEmpty, content != "NOTE_TO_SELF".localized() else {
            return NSMutableAttributedString(
                string: (authorName != nil && authorName?.isEmpty != true ?
                    "\(authorName ?? ""): \(content)" :
                    content
                ),
                attributes: [ .foregroundColor: textColor ]
            )
        }
        
        // Replace mentions in the content
        //
        // Note: The 'threadVariant' is used for profile context but in the search results
        // we don't want to include the truncated id as part of the name so we exclude it
        let mentionReplacedContent: String = MentionUtilities.highlightMentionsNoAttributes(
            in: content,
            threadVariant: .contact,
            currentUserPublicKey: currentUserPublicKey,
            currentUserBlindedPublicKey: currentUserBlindedPublicKey
        )
        let result: NSMutableAttributedString = NSMutableAttributedString(
            string: mentionReplacedContent,
            attributes: [
                .foregroundColor: textColor
                    .withAlphaComponent(Values.lowOpacity)
            ]
        )
        
        // Bold each part of the searh term which matched
        let normalizedSnippet: String = mentionReplacedContent.lowercased()
        var firstMatchRange: Range<String.Index>?
        
        SessionThreadViewModel.searchTermParts(searchText)
            .map { part -> String in
                guard part.hasPrefix("\"") && part.hasSuffix("\"") else { return part }
                
                let partRange = (part.index(after: part.startIndex)..<part.index(before: part.endIndex))
                return String(part[partRange])
            }
            .forEach { part in
                // Highlight all ranges of the text (Note: The search logic only finds results that start
                // with the term so we use the regex below to ensure we only highlight those cases)
                normalizedSnippet
                    .ranges(
                        of: (CurrentAppContext().isRTL ?
                             "(\(part.lowercased()))(^|[^a-zA-Z0-9])" :
                             "(^|[^a-zA-Z0-9])(\(part.lowercased()))"
                        ),
                        options: [.regularExpression]
                    )
                    .forEach { range in
                        let targetRange: Range<String.Index> = {
                            let term: String = String(normalizedSnippet[range])
                            
                            // If the matched term doesn't actually match the "part" value then it means
                            // we've matched a term after a non-alphanumeric character so need to shift
                            // the range over by 1
                            guard term.starts(with: part.lowercased()) else {
                                return (normalizedSnippet.index(after: range.lowerBound)..<range.upperBound)
                            }
                            
                            return range
                        }()
                        
                        // Store the range of the first match so we can focus it in the content displayed
                        if firstMatchRange == nil {
                            firstMatchRange = targetRange
                        }
                        
                        let legacyRange: NSRange = NSRange(targetRange, in: normalizedSnippet)
                        result.addAttribute(.foregroundColor, value: textColor, range: legacyRange)
                        result.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: fontSize), range: legacyRange)
                    }
            }
        
        // We then want to truncate the content so the first matching term is visible
        let startOfSnippet: String.Index = (
            firstMatchRange.map {
                max(
                    mentionReplacedContent.startIndex,
                    mentionReplacedContent
                        .index(
                            $0.lowerBound,
                            offsetBy: -10,
                            limitedBy: mentionReplacedContent.startIndex
                        )
                        .defaulting(to: mentionReplacedContent.startIndex)
                )
            } ??
            mentionReplacedContent.startIndex
        )
        
        // This method determines if the content is probably too long and returns the truncated or untruncated
        // content accordingly
        func truncatingIfNeeded(approxWidth: CGFloat, content: NSAttributedString) -> NSAttributedString {
            let approxFullWidth: CGFloat = (approxWidth + profilePictureView.size + (Values.mediumSpacing * 3))
            
            guard ((bounds.width - approxFullWidth) < 0) else { return content }
            
            return content.attributedSubstring(
                from: NSRange(startOfSnippet..<normalizedSnippet.endIndex, in: normalizedSnippet)
            )
        }
        
        // Now that we have generated the focused snippet add the author name as a prefix (if provided)
        return authorName
            .map { authorName -> NSAttributedString? in
                guard !authorName.isEmpty else { return nil }
                
                let authorPrefix: NSAttributedString = NSAttributedString(
                    string: "\(authorName): ...",
                    attributes: [ .foregroundColor: textColor ]
                )
                
                return authorPrefix
                    .appending(
                        truncatingIfNeeded(
                            approxWidth: (authorPrefix.size().width + result.size().width),
                            content: result
                        )
                    )
            }
            .defaulting(
                to: truncatingIfNeeded(
                    approxWidth: result.size().width,
                    content: result
                )
            )
    }
}
