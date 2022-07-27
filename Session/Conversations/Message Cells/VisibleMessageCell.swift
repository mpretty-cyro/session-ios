// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import SessionMessagingKit

final class VisibleMessageCell: MessageCell, UITextViewDelegate, BodyTextViewDelegate {
    private var unloadContent: (() -> Void)?
    private var previousX: CGFloat = 0
    
    var albumView: MediaAlbumView?
    var bodyTextView: UITextView?
    var voiceMessageView: VoiceMessageView?
    var audioStateChanged: ((TimeInterval, Bool) -> ())?
    
    // Constraints
    private lazy var headerViewTopConstraint = headerView.pin(.top, to: .top, of: self, withInset: 1)
    private lazy var authorLabelHeightConstraint = authorLabel.set(.height, to: 0)
    private lazy var profilePictureViewLeftConstraint = profilePictureView.pin(.left, to: .left, of: self, withInset: VisibleMessageCell.groupThreadHSpacing)
    private lazy var profilePictureViewWidthConstraint = profilePictureView.set(.width, to: Values.verySmallProfilePictureSize)
    private lazy var bubbleViewLeftConstraint1 = bubbleView.pin(.left, to: .right, of: profilePictureView, withInset: VisibleMessageCell.groupThreadHSpacing)
    private lazy var bubbleViewLeftConstraint2 = bubbleView.leftAnchor.constraint(greaterThanOrEqualTo: leftAnchor, constant: VisibleMessageCell.gutterSize)
    private lazy var bubbleViewTopConstraint = bubbleView.pin(.top, to: .bottom, of: authorLabel, withInset: VisibleMessageCell.authorLabelBottomSpacing)
    private lazy var bubbleViewRightConstraint1 = bubbleView.pin(.right, to: .right, of: self, withInset: -VisibleMessageCell.contactThreadHSpacing)
    private lazy var bubbleViewRightConstraint2 = bubbleView.rightAnchor.constraint(lessThanOrEqualTo: rightAnchor, constant: -VisibleMessageCell.gutterSize)
    private lazy var messageStatusImageViewTopConstraint = messageStatusImageView.pin(.top, to: .bottom, of: bubbleView, withInset: 0)
    private lazy var messageStatusImageViewWidthConstraint = messageStatusImageView.set(.width, to: VisibleMessageCell.messageStatusImageViewSize)
    private lazy var messageStatusImageViewHeightConstraint = messageStatusImageView.set(.height, to: VisibleMessageCell.messageStatusImageViewSize)
    private lazy var timerViewOutgoingMessageConstraint = timerView.pin(.left, to: .left, of: self, withInset: VisibleMessageCell.contactThreadHSpacing)
    private lazy var timerViewIncomingMessageConstraint = timerView.pin(.right, to: .right, of: self, withInset: -VisibleMessageCell.contactThreadHSpacing)

    private lazy var panGestureRecognizer: UIPanGestureRecognizer = {
        let result = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        result.delegate = self
        return result
    }()
    
    // MARK: - UI Components
    
    private lazy var viewsToMoveForReply: [UIView] = [
        bubbleView,
        bubbleBackgroundView,
        profilePictureView,
        replyButton,
        timerView,
        messageStatusImageView
    ]
    
    private lazy var profilePictureView: ProfilePictureView = {
        let result: ProfilePictureView = ProfilePictureView()
        result.set(.height, to: Values.verySmallProfilePictureSize)
        result.size = Values.verySmallProfilePictureSize
        
        return result
    }()

    private lazy var moderatorIconImageView = UIImageView(image: #imageLiteral(resourceName: "Crown"))
    
    lazy var bubbleBackgroundView: UIView = {
        let result = UIView()
        result.layer.cornerRadius = VisibleMessageCell.largeCornerRadius
        return result
    }()

    lazy var bubbleView: UIView = {
        let result = UIView()
        result.clipsToBounds = true
        result.layer.cornerRadius = VisibleMessageCell.largeCornerRadius
        result.set(.width, greaterThanOrEqualTo: VisibleMessageCell.largeCornerRadius * 2)
        return result
    }()

    private lazy var headerView = UIView()

    private lazy var authorLabel: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.smallFontSize)
        return result
    }()

    private lazy var snContentView = UIView()

    internal lazy var messageStatusImageView: UIImageView = {
        let result = UIImageView()
        result.contentMode = .scaleAspectFit
        result.layer.cornerRadius = VisibleMessageCell.messageStatusImageViewSize / 2
        result.layer.masksToBounds = true
        return result
    }()

    private lazy var replyButton: UIView = {
        let result = UIView()
        let size = VisibleMessageCell.replyButtonSize + 8
        result.set(.width, to: size)
        result.set(.height, to: size)
        result.layer.borderWidth = 1
        result.layer.borderColor = Colors.text.cgColor
        result.layer.cornerRadius = size / 2
        result.layer.masksToBounds = true
        result.alpha = 0
        return result
    }()

    private lazy var replyIconImageView: UIImageView = {
        let result = UIImageView()
        let size = VisibleMessageCell.replyButtonSize
        result.set(.width, to: size)
        result.set(.height, to: size)
        result.image = UIImage(named: "ic_reply")?.withRenderingMode(.alwaysTemplate)
        result.tintColor = Colors.text
        return result
    }()

    private lazy var timerView: OWSMessageTimerView = OWSMessageTimerView()

    // MARK: - Settings
    
    private static let messageStatusImageViewSize: CGFloat = 16
    private static let authorLabelBottomSpacing: CGFloat = 4
    private static let groupThreadHSpacing: CGFloat = 12
    private static let profilePictureSize = Values.verySmallProfilePictureSize
    private static let authorLabelInset: CGFloat = 12
    private static let replyButtonSize: CGFloat = 24
    private static let maxBubbleTranslationX: CGFloat = 40
    private static let swipeToReplyThreshold: CGFloat = 110
    static let smallCornerRadius: CGFloat = 4
    static let largeCornerRadius: CGFloat = 18
    static let contactThreadHSpacing = Values.mediumSpacing

    static var gutterSize: CGFloat = {
        var result = groupThreadHSpacing + profilePictureSize + groupThreadHSpacing
        
        if UIDevice.current.isIPad {
            result += CGFloat(UIScreen.main.bounds.width / 2 - 88)
        }
        
        return result
    }()
    
    // MARK: Direction & Position
    
    enum Direction { case incoming, outgoing }

    // MARK: - Lifecycle
    
    override func setUpViewHierarchy() {
        super.setUpViewHierarchy()
        
        // Header view
        addSubview(headerView)
        headerViewTopConstraint.isActive = true
        headerView.pin([ UIView.HorizontalEdge.left, UIView.HorizontalEdge.right ], to: self)
        
        // Author label
        addSubview(authorLabel)
        authorLabelHeightConstraint.isActive = true
        authorLabel.pin(.top, to: .bottom, of: headerView)
        
        // Profile picture view
        addSubview(profilePictureView)
        profilePictureViewLeftConstraint.isActive = true
        profilePictureViewWidthConstraint.isActive = true
        profilePictureView.pin(.bottom, to: .bottom, of: self, withInset: -1)
        
        // Moderator icon image view
        moderatorIconImageView.set(.width, to: 20)
        moderatorIconImageView.set(.height, to: 20)
        addSubview(moderatorIconImageView)
        moderatorIconImageView.pin(.trailing, to: .trailing, of: profilePictureView, withInset: 1)
        moderatorIconImageView.pin(.bottom, to: .bottom, of: profilePictureView, withInset: 4.5)
        
        // Bubble background view (used for the 'highlighted' animation)
        addSubview(bubbleBackgroundView)
        
        // Bubble view
        addSubview(bubbleView)
        bubbleViewLeftConstraint1.isActive = true
        bubbleViewTopConstraint.isActive = true
        bubbleViewRightConstraint1.isActive = true
        bubbleBackgroundView.pin(to: bubbleView)
        
        // Timer view
        addSubview(timerView)
        timerView.center(.vertical, in: bubbleView)
        timerViewOutgoingMessageConstraint.isActive = true
        
        // Content view
        bubbleView.addSubview(snContentView)
        snContentView.pin(to: bubbleView)
        
        // Message status image view
        addSubview(messageStatusImageView)
        messageStatusImageViewTopConstraint.isActive = true
        messageStatusImageView.pin(.right, to: .right, of: bubbleView, withInset: -1)
        messageStatusImageView.pin(.bottom, to: .bottom, of: self, withInset: -1)
        messageStatusImageViewWidthConstraint.isActive = true
        messageStatusImageViewHeightConstraint.isActive = true
        
        // Reply button
        addSubview(replyButton)
        replyButton.addSubview(replyIconImageView)
        replyIconImageView.center(in: replyButton)
        replyButton.pin(.left, to: .right, of: bubbleView, withInset: Values.smallSpacing)
        replyButton.center(.vertical, in: bubbleView)
        
        // Remaining constraints
        authorLabel.pin(.left, to: .left, of: bubbleView, withInset: VisibleMessageCell.authorLabelInset)
    }

    override func setUpGestureRecognizers() {
        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        addGestureRecognizer(longPressRecognizer)
        
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tapGestureRecognizer.numberOfTapsRequired = 1
        addGestureRecognizer(tapGestureRecognizer)
        
        let doubleTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTapGestureRecognizer.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTapGestureRecognizer)
        tapGestureRecognizer.require(toFail: doubleTapGestureRecognizer)
    }

    // MARK: - Updating
    
    override func update(
        with cellViewModel: MessageViewModel,
        mediaCache: NSCache<NSString, AnyObject>,
        playbackInfo: ConversationViewModel.PlaybackInfo?,
        lastSearchText: String?
    ) {
        self.viewModel = cellViewModel
        
        let isGroupThread: Bool = (cellViewModel.threadVariant == .openGroup || cellViewModel.threadVariant == .closedGroup)
        let shouldInsetHeader: Bool = (
            cellViewModel.previousVariant?.isInfoMessage != true &&
            (
                cellViewModel.positionInCluster == .top ||
                cellViewModel.isOnlyMessageInCluster
            )
        )
        
        // Profile picture view
        profilePictureViewLeftConstraint.constant = (isGroupThread ? VisibleMessageCell.groupThreadHSpacing : 0)
        profilePictureViewWidthConstraint.constant = (isGroupThread ? VisibleMessageCell.profilePictureSize : 0)
        profilePictureView.isHidden = (!cellViewModel.shouldShowProfile || cellViewModel.profile == nil)
        profilePictureView.update(
            publicKey: cellViewModel.authorId,
            profile: cellViewModel.profile,
            threadVariant: cellViewModel.threadVariant
        )
        moderatorIconImageView.isHidden = (!cellViewModel.isSenderOpenGroupModerator || !cellViewModel.shouldShowProfile)
       
        // Bubble view
        bubbleViewLeftConstraint1.isActive = (
            cellViewModel.variant == .standardIncoming ||
            cellViewModel.variant == .standardIncomingDeleted
        )
        bubbleViewLeftConstraint1.constant = (isGroupThread ? VisibleMessageCell.groupThreadHSpacing : VisibleMessageCell.contactThreadHSpacing)
        bubbleViewLeftConstraint2.isActive = (cellViewModel.variant == .standardOutgoing)
        bubbleViewTopConstraint.constant = (cellViewModel.senderName == nil ? 0 : VisibleMessageCell.authorLabelBottomSpacing)
        bubbleViewRightConstraint1.isActive = (cellViewModel.variant == .standardOutgoing)
        bubbleViewRightConstraint2.isActive = (
            cellViewModel.variant == .standardIncoming ||
            cellViewModel.variant == .standardIncomingDeleted
        )
        bubbleView.backgroundColor = ((
            cellViewModel.variant == .standardIncoming ||
            cellViewModel.variant == .standardIncomingDeleted
        ) ? Colors.receivedMessageBackground : Colors.sentMessageBackground)
        bubbleBackgroundView.backgroundColor = bubbleView.backgroundColor
        updateBubbleViewCorners()
        
        // Content view
        populateContentView(
            for: cellViewModel,
            mediaCache: mediaCache,
            playbackInfo: playbackInfo,
            lastSearchText: lastSearchText
        )
        
        // Date break
        headerViewTopConstraint.constant = (shouldInsetHeader ? Values.mediumSpacing : 1)
        headerView.subviews.forEach { $0.removeFromSuperview() }
        populateHeader(for: cellViewModel, shouldInsetHeader: shouldInsetHeader)
        
        // Author label
        authorLabel.textColor = Colors.text
        authorLabel.isHidden = (cellViewModel.senderName == nil)
        authorLabel.text = cellViewModel.senderName
        
        let authorLabelAvailableWidth: CGFloat = (VisibleMessageCell.getMaxWidth(for: cellViewModel) - 2 * VisibleMessageCell.authorLabelInset)
        let authorLabelAvailableSpace = CGSize(width: authorLabelAvailableWidth, height: .greatestFiniteMagnitude)
        let authorLabelSize = authorLabel.sizeThatFits(authorLabelAvailableSpace)
        authorLabelHeightConstraint.constant = (cellViewModel.senderName != nil ? authorLabelSize.height : 0)
        
        // Message status image view
        let (image, tintColor, backgroundColor) = getMessageStatusImage(for: cellViewModel)
        messageStatusImageView.image = image
        messageStatusImageView.tintColor = tintColor
        messageStatusImageView.backgroundColor = backgroundColor
        messageStatusImageView.isHidden = (
            cellViewModel.variant != .standardOutgoing ||
            cellViewModel.variant == .infoCall ||
            (
                cellViewModel.state == .sent &&
                !cellViewModel.isLast
            )
        )
        messageStatusImageViewTopConstraint.constant = (messageStatusImageView.isHidden ? 0 : 5)
        [ messageStatusImageViewWidthConstraint, messageStatusImageViewHeightConstraint ]
            .forEach {
                $0.constant = (messageStatusImageView.isHidden ? 0 : VisibleMessageCell.messageStatusImageViewSize)
            }
        
        // Timer
        if
            let expiresStartedAtMs: Double = cellViewModel.expiresStartedAtMs,
            let expiresInSeconds: TimeInterval = cellViewModel.expiresInSeconds
        {
            let expirationTimestampMs: Double = (expiresStartedAtMs + (expiresInSeconds * 1000))
            
            timerView.configure(
                withExpirationTimestamp: UInt64(floor(expirationTimestampMs)),
                initialDurationSeconds: UInt32(floor(expiresInSeconds)),
                tintColor: Colors.text
            )
            timerView.isHidden = false
        }
        else {
            timerView.isHidden = true
        }
        
        timerViewOutgoingMessageConstraint.isActive = (cellViewModel.variant == .standardOutgoing)
        timerViewIncomingMessageConstraint.isActive = (
            cellViewModel.variant == .standardIncoming ||
            cellViewModel.variant == .standardIncomingDeleted
        )
        
        // Swipe to reply
        if cellViewModel.variant == .standardIncomingDeleted || cellViewModel.variant == .infoCall {
            removeGestureRecognizer(panGestureRecognizer)
        }
        else {
            addGestureRecognizer(panGestureRecognizer)
        }
    }

    private func populateHeader(for cellViewModel: MessageViewModel, shouldInsetHeader: Bool) {
        guard let date: Date = cellViewModel.dateForUI else { return }
        
        let dateBreakLabel: UILabel = UILabel()
        dateBreakLabel.font = .boldSystemFont(ofSize: Values.verySmallFontSize)
        dateBreakLabel.textColor = Colors.text
        dateBreakLabel.textAlignment = .center
        dateBreakLabel.text = date.formattedForDisplay
        headerView.addSubview(dateBreakLabel)
        dateBreakLabel.pin(.top, to: .top, of: headerView, withInset: Values.smallSpacing)
        
        let additionalBottomInset = (shouldInsetHeader ? Values.mediumSpacing : 1)
        headerView.pin(.bottom, to: .bottom, of: dateBreakLabel, withInset: Values.smallSpacing + additionalBottomInset)
        dateBreakLabel.center(.horizontal, in: headerView)
        
        let availableWidth = VisibleMessageCell.getMaxWidth(for: cellViewModel)
        let availableSpace = CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
        let dateBreakLabelSize = dateBreakLabel.sizeThatFits(availableSpace)
        dateBreakLabel.set(.height, to: dateBreakLabelSize.height)
    }

    private func populateContentView(
        for cellViewModel: MessageViewModel,
        mediaCache: NSCache<NSString, AnyObject>,
        playbackInfo: ConversationViewModel.PlaybackInfo?,
        lastSearchText: String?
    ) {
        let bodyLabelTextColor: UIColor = {
            let direction: Direction = (cellViewModel.variant == .standardOutgoing ?
                .outgoing :
                .incoming
            )
            
            switch (direction, AppModeManager.shared.currentAppMode) {
                case (.outgoing, .dark), (.incoming, .light): return .black
                case (.outgoing, .light): return Colors.grey
                default: return .white
            }
        }()
        
        snContentView.subviews.forEach { $0.removeFromSuperview() }
        albumView = nil
        bodyTextView = nil
        
        // Handle the deleted state first (it's much simpler than the others)
        guard cellViewModel.variant != .standardIncomingDeleted else {
            let deletedMessageView: DeletedMessageView = DeletedMessageView(textColor: bodyLabelTextColor)
            snContentView.addSubview(deletedMessageView)
            deletedMessageView.pin(to: snContentView)
            return
        }
        
        // If it's an incoming media message and the thread isn't trusted then show the placeholder view
        if cellViewModel.cellType != .textOnlyMessage && cellViewModel.variant == .standardIncoming && !cellViewModel.threadIsTrusted {
            let mediaPlaceholderView = MediaPlaceholderView(cellViewModel: cellViewModel, textColor: bodyLabelTextColor)
            snContentView.addSubview(mediaPlaceholderView)
            mediaPlaceholderView.pin(to: snContentView)
            return
        }

        switch cellViewModel.cellType {
            case .typingIndicator: break
            
            case .textOnlyMessage:
                let inset: CGFloat = 12
                let maxWidth: CGFloat = (VisibleMessageCell.getMaxWidth(for: cellViewModel) - 2 * inset)
                
                if let linkPreview: LinkPreview = cellViewModel.linkPreview {
                    switch linkPreview.variant {
                        case .standard:
                            let linkPreviewView: LinkPreviewView = LinkPreviewView(maxWidth: maxWidth)
                            linkPreviewView.update(
                                with: LinkPreview.SentState(
                                    linkPreview: linkPreview,
                                    imageAttachment: cellViewModel.linkPreviewAttachment
                                ),
                                isOutgoing: (cellViewModel.variant == .standardOutgoing),
                                delegate: self,
                                cellViewModel: cellViewModel,
                                bodyLabelTextColor: bodyLabelTextColor,
                                lastSearchText: lastSearchText
                            )
                            snContentView.addSubview(linkPreviewView)
                            linkPreviewView.pin(to: snContentView)
                            self.bodyTextView = linkPreviewView.bodyTextView
                            
                        case .openGroupInvitation:
                            let openGroupInvitationView: OpenGroupInvitationView = OpenGroupInvitationView(
                                name: (linkPreview.title ?? ""),
                                url: linkPreview.url,
                                textColor: bodyLabelTextColor,
                                isOutgoing: (cellViewModel.variant == .standardOutgoing)
                            )
                            
                            snContentView.addSubview(openGroupInvitationView)
                            openGroupInvitationView.pin(to: snContentView)
                    }
                }
                else {
                    // Stack view
                    let stackView = UIStackView(arrangedSubviews: [])
                    stackView.axis = .vertical
                    stackView.spacing = 2
                    
                    // Quote view
                    if let quote: Quote = cellViewModel.quote {
                        let hInset: CGFloat = 2
                        let quoteView: QuoteView = QuoteView(
                            for: .regular,
                            authorId: quote.authorId,
                            quotedText: quote.body,
                            threadVariant: cellViewModel.threadVariant,
                            currentUserPublicKey: cellViewModel.currentUserPublicKey,
                            currentUserBlindedPublicKey: cellViewModel.currentUserBlindedPublicKey,
                            direction: (cellViewModel.variant == .standardOutgoing ?
                                .outgoing :
                                .incoming
                            ),
                            attachment: cellViewModel.quoteAttachment,
                            hInset: hInset,
                            maxWidth: maxWidth
                        )
                        let quoteViewContainer = UIView(wrapping: quoteView, withInsets: UIEdgeInsets(top: 0, leading: hInset, bottom: 0, trailing: hInset))
                        stackView.addArrangedSubview(quoteViewContainer)
                    }
                    
                    // Body text view
                    let bodyTextView = VisibleMessageCell.getBodyTextView(
                        for: cellViewModel,
                        with: maxWidth,
                        textColor: bodyLabelTextColor,
                        searchText: lastSearchText,
                        delegate: self
                    )
                    self.bodyTextView = bodyTextView
                    stackView.addArrangedSubview(bodyTextView)
                    
                    // Constraints
                    snContentView.addSubview(stackView)
                    stackView.pin(to: snContentView, withInset: inset)
                }
                
            case .mediaMessage:
                // Stack view
                let stackView = UIStackView(arrangedSubviews: [])
                stackView.axis = .vertical
                stackView.spacing = Values.smallSpacing
                
                // Album view
                let maxMessageWidth: CGFloat = VisibleMessageCell.getMaxWidth(for: cellViewModel)
                let albumView = MediaAlbumView(
                    mediaCache: mediaCache,
                    items: (cellViewModel.attachments?
                        .filter { $0.isVisualMedia })
                        .defaulting(to: []),
                    isOutgoing: (cellViewModel.variant == .standardOutgoing),
                    maxMessageWidth: maxMessageWidth
                )
                self.albumView = albumView
                let size = getSize(for: cellViewModel)
                albumView.set(.width, to: size.width)
                albumView.set(.height, to: size.height)
                albumView.loadMedia()
                stackView.addArrangedSubview(albumView)
                
                // Body text view
                if let body: String = cellViewModel.body, !body.isEmpty {
                    let inset: CGFloat = 12
                    let maxWidth: CGFloat = (size.width - (2 * inset))
                    let bodyTextView = VisibleMessageCell.getBodyTextView(
                        for: cellViewModel,
                        with: maxWidth,
                        textColor: bodyLabelTextColor,
                        searchText: lastSearchText,
                        delegate: self
                    )

                    self.bodyTextView = bodyTextView
                    stackView.addArrangedSubview(UIView(wrapping: bodyTextView, withInsets: UIEdgeInsets(top: 0, left: inset, bottom: inset, right: inset)))
                }
                unloadContent = { albumView.unloadMedia() }
                
                // Constraints
                snContentView.addSubview(stackView)
                stackView.pin(to: snContentView)
                
            case .audio:
                guard let attachment: Attachment = cellViewModel.attachments?.first(where: { $0.isAudio }) else {
                    return
                }
                
                let voiceMessageView: VoiceMessageView = VoiceMessageView()
                voiceMessageView.update(
                    with: attachment,
                    isPlaying: (playbackInfo?.state == .playing),
                    progress: (playbackInfo?.progress ?? 0),
                    playbackRate: (playbackInfo?.playbackRate ?? 1),
                    oldPlaybackRate: (playbackInfo?.oldPlaybackRate ?? 1)
                )
                
                snContentView.addSubview(voiceMessageView)
                voiceMessageView.pin(to: snContentView)
                self.voiceMessageView = voiceMessageView
                
            case .genericAttachment:
                guard let attachment: Attachment = cellViewModel.attachments?.first else { preconditionFailure() }
                
                let inset: CGFloat = 12
                let maxWidth = (VisibleMessageCell.getMaxWidth(for: cellViewModel) - 2 * inset)
                
                // Stack view
                let stackView = UIStackView(arrangedSubviews: [])
                stackView.axis = .vertical
                stackView.spacing = Values.smallSpacing
                
                // Document view
                let documentView = DocumentView(attachment: attachment, textColor: bodyLabelTextColor)
                stackView.addArrangedSubview(documentView)
                
                // Body text view
                if let body: String = cellViewModel.body, !body.isEmpty { // delegate should always be set at this point
                    let bodyTextView = VisibleMessageCell.getBodyTextView(
                        for: cellViewModel,
                        with: maxWidth,
                        textColor: bodyLabelTextColor,
                        searchText: lastSearchText,
                        delegate: self
                    )
                    
                    self.bodyTextView = bodyTextView
                    stackView.addArrangedSubview(bodyTextView)
                }
                
                // Constraints
                snContentView.addSubview(stackView)
                stackView.pin(to: snContentView, withInset: inset)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateBubbleViewCorners()
    }

    private func updateBubbleViewCorners() {
        let cornersToRound: UIRectCorner = getCornersToRound()
        
        bubbleBackgroundView.layer.cornerRadius = VisibleMessageCell.largeCornerRadius
        bubbleBackgroundView.layer.maskedCorners = getCornerMask(from: cornersToRound)
        bubbleView.layer.cornerRadius = VisibleMessageCell.largeCornerRadius
        bubbleView.layer.maskedCorners = getCornerMask(from: cornersToRound)
    }
    
    override func dynamicUpdate(with cellViewModel: MessageViewModel, playbackInfo: ConversationViewModel.PlaybackInfo?) {
        guard cellViewModel.variant != .standardIncomingDeleted else { return }
        
        // If it's an incoming media message and the thread isn't trusted then show the placeholder view
        if cellViewModel.cellType != .textOnlyMessage && cellViewModel.variant == .standardIncoming && !cellViewModel.threadIsTrusted {
            return
        }

        switch cellViewModel.cellType {
            case .audio:
                guard let attachment: Attachment = cellViewModel.attachments?.first(where: { $0.isAudio }) else {
                    return
                }
                
                self.voiceMessageView?.update(
                    with: attachment,
                    isPlaying: (playbackInfo?.state == .playing),
                    progress: (playbackInfo?.progress ?? 0),
                    playbackRate: (playbackInfo?.playbackRate ?? 1),
                    oldPlaybackRate: (playbackInfo?.oldPlaybackRate ?? 1)
                )
                
            default: break
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        
        unloadContent?()
        viewsToMoveForReply.forEach { $0.transform = .identity }
        replyButton.alpha = 0
        timerView.prepareForReuse()
    }

    // MARK: - Interaction
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let bodyTextView = bodyTextView {
            let pointInBodyTextViewCoordinates = convert(point, to: bodyTextView)
            if bodyTextView.bounds.contains(pointInBodyTextViewCoordinates) {
                return bodyTextView
            }
        }
        return super.hitTest(point, with: event)
    }

    override func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true // Needed for the pan gesture recognizer to work with the table view's pan gesture recognizer
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == panGestureRecognizer {
            let v = panGestureRecognizer.velocity(in: self)
            // Only allow swipes to the left; allowing swipes to the right gets in the way of the default
            // iOS swipe to go back gesture
            guard v.x < 0 else { return false }
            
            return abs(v.x) > abs(v.y) // It has to be more horizontal than vertical
        }
        
        return true
    }

    func highlight() {
        // FIXME: This will have issues with themes
        let shawdowColour = (isLightMode ? UIColor.black.cgColor : Colors.accent.cgColor)
        let opacity: Float = (isLightMode ? 0.5 : 1)
        
        DispatchQueue.main.async { [weak self] in
            let oldMasksToBounds: Bool = (self?.layer.masksToBounds ?? false)
            self?.layer.masksToBounds = false
            self?.bubbleBackgroundView.setShadow(radius: 10, opacity: opacity, offset: .zero, color: shawdowColour)
            
            UIView.animate(
                withDuration: 1.6,
                delay: 0,
                options: .curveEaseInOut,
                animations: {
                    self?.bubbleBackgroundView.setShadow(radius: 0, opacity: 0, offset: .zero, color: UIColor.clear.cgColor)
                },
                completion: { _ in
                    self?.layer.masksToBounds = oldMasksToBounds
                }
            )
        }
    }

    @objc func handleLongPress() {
        guard let cellViewModel: MessageViewModel = self.viewModel else { return }
        
        delegate?.handleItemLongPressed(cellViewModel)
    }

    @objc private func handleTap(_ gestureRecognizer: UITapGestureRecognizer) {
        guard let cellViewModel: MessageViewModel = self.viewModel else { return }
        
        let location = gestureRecognizer.location(in: self)
        
        if profilePictureView.frame.contains(location), cellViewModel.shouldShowProfile {
            // For open groups only attempt to start a conversation if the author has a blinded id
            guard cellViewModel.threadVariant != .openGroup else {
                guard SessionId.Prefix(from: cellViewModel.authorId) == .blinded else { return }
                
                delegate?.startThread(
                    with: cellViewModel.authorId,
                    openGroupServer: cellViewModel.threadOpenGroupServer,
                    openGroupPublicKey: cellViewModel.threadOpenGroupPublicKey
                )
                return
            }
            
            delegate?.startThread(
                with: cellViewModel.authorId,
                openGroupServer: nil,
                openGroupPublicKey: nil
            )
        }
        else if replyButton.alpha > 0 && replyButton.frame.contains(location) {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            reply()
        }
        else if bubbleView.frame.contains(location) {
            delegate?.handleItemTapped(cellViewModel, gestureRecognizer: gestureRecognizer)
        }
    }

    @objc private func handleDoubleTap() {
        guard let cellViewModel: MessageViewModel = self.viewModel else { return }
        
        delegate?.handleItemDoubleTapped(cellViewModel)
    }

    @objc private func handlePan(_ gestureRecognizer: UIPanGestureRecognizer) {
        guard let cellViewModel: MessageViewModel = self.viewModel else { return }
        
        let translationX = gestureRecognizer.translation(in: self).x.clamp(-CGFloat.greatestFiniteMagnitude, 0)
        
        switch gestureRecognizer.state {
            case .began: delegate?.handleItemSwiped(cellViewModel, state: .began)
                
            case .changed:
                // The idea here is to asymptotically approach a maximum drag distance
                let damping: CGFloat = 20
                let sign: CGFloat = -1
                let x = (damping * (sqrt(abs(translationX)) / sqrt(damping))) * sign
                viewsToMoveForReply.forEach { $0.transform = CGAffineTransform(translationX: x, y: 0) }
                if timerView.isHidden {
                    replyButton.alpha = abs(translationX) / VisibleMessageCell.maxBubbleTranslationX
                } else {
                    replyButton.alpha = 0 // Always hide the reply button if the timer view is showing, otherwise they can overlap
                }
                if abs(translationX) > VisibleMessageCell.swipeToReplyThreshold && abs(previousX) < VisibleMessageCell.swipeToReplyThreshold {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred() // Let the user know when they've hit the swipe to reply threshold
                }
                previousX = translationX
                
            case .ended, .cancelled:
                if abs(translationX) > VisibleMessageCell.swipeToReplyThreshold {
                    delegate?.handleItemSwiped(cellViewModel, state: .ended)
                    reply()
                }
                else {
                    delegate?.handleItemSwiped(cellViewModel, state: .cancelled)
                    resetReply()
                }
                
            default: break
        }
    }

    func textView(_ textView: UITextView, shouldInteractWith url: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        delegate?.openUrl(url.absoluteString)
        return false
    }
    
    func textViewDidChangeSelection(_ textView: UITextView) {
        // Note: We can't just set 'isSelectable' to false otherwise the link detection/selection
        // stops working (do a null check to avoid an infinite loop on older iOS versions)
        if textView.selectedTextRange != nil {
            textView.selectedTextRange = nil
        }
    }

    private func resetReply() {
        UIView.animate(withDuration: 0.25) { [weak self] in
            self?.viewsToMoveForReply.forEach { $0.transform = .identity }
            self?.replyButton.alpha = 0
        }
    }

    private func reply() {
        guard let cellViewModel: MessageViewModel = self.viewModel else { return }
        
        resetReply()
        delegate?.handleReplyButtonTapped(for: cellViewModel)
    }

    // MARK: - Convenience
    
    private func getCornersToRound() -> UIRectCorner {
        guard viewModel?.isOnlyMessageInCluster == false else { return .allCorners }
        
        let direction: Direction = (viewModel?.variant == .standardOutgoing ? .outgoing : .incoming)
        
        switch (viewModel?.positionInCluster, direction) {
            case (.top, .outgoing): return [ .bottomLeft, .topLeft, .topRight ]
            case (.middle, .outgoing): return [ .bottomLeft, .topLeft ]
            case (.bottom, .outgoing): return [ .bottomRight, .bottomLeft, .topLeft ]
            case (.top, .incoming): return [ .topLeft, .topRight, .bottomRight ]
            case (.middle, .incoming): return [ .topRight, .bottomRight ]
            case (.bottom, .incoming): return [ .topRight, .bottomRight, .bottomLeft ]
            case (.none, _): return .allCorners
        }
    }
    
    private func getCornerMask(from rectCorner: UIRectCorner) -> CACornerMask {
        guard !rectCorner.contains(.allCorners) else {
            return [ .layerMaxXMinYCorner, .layerMinXMinYCorner, .layerMaxXMaxYCorner, .layerMinXMaxYCorner]
        }
        
        var cornerMask = CACornerMask()
        if rectCorner.contains(.topRight) { cornerMask.insert(.layerMaxXMinYCorner) }
        if rectCorner.contains(.topLeft) { cornerMask.insert(.layerMinXMinYCorner) }
        if rectCorner.contains(.bottomRight) { cornerMask.insert(.layerMaxXMaxYCorner) }
        if rectCorner.contains(.bottomLeft) { cornerMask.insert(.layerMinXMaxYCorner) }
        return cornerMask
    }

    private static func getFontSize(for cellViewModel: MessageViewModel) -> CGFloat {
        let baselineFontSize = Values.mediumFontSize
        
        guard cellViewModel.containsOnlyEmoji == true else { return baselineFontSize }
        
        switch (cellViewModel.glyphCount ?? 0) {
            case 1: return baselineFontSize + 30
            case 2: return baselineFontSize + 24
            case 3, 4, 5: return baselineFontSize + 18
            default: return baselineFontSize
        }
    }

    private func getMessageStatusImage(for cellViewModel: MessageViewModel) -> (image: UIImage?, tintColor: UIColor?, backgroundColor: UIColor?) {
        guard cellViewModel.variant == .standardOutgoing else { return (nil, nil, nil) }

        let image: UIImage
        var tintColor: UIColor? = nil
        var backgroundColor: UIColor? = nil
        
        switch (cellViewModel.state, cellViewModel.hasAtLeastOneReadReceipt) {
            case (.sending, _):
                image = #imageLiteral(resourceName: "CircleDotDotDot").withRenderingMode(.alwaysTemplate)
                tintColor = Colors.text
            
            case (.sent, false), (.skipped, _):
                image = #imageLiteral(resourceName: "CircleCheck").withRenderingMode(.alwaysTemplate)
                tintColor = Colors.text
                
            case (.sent, true):
                image = isLightMode ? #imageLiteral(resourceName: "FilledCircleCheckLightMode") : #imageLiteral(resourceName: "FilledCircleCheckDarkMode")
                backgroundColor = isLightMode ? .black : .white
                
            case (.failed, _):
                image = #imageLiteral(resourceName: "message_status_failed").withRenderingMode(.alwaysTemplate)
                tintColor = Colors.destructive
        }

        return (image, tintColor, backgroundColor)
    }

    private func getSize(for cellViewModel: MessageViewModel) -> CGSize {
        guard let mediaAttachments: [Attachment] = cellViewModel.attachments?.filter({ $0.isVisualMedia }) else {
            preconditionFailure()
        }
        
        let maxMessageWidth = VisibleMessageCell.getMaxWidth(for: cellViewModel)
        let defaultSize = MediaAlbumView.layoutSize(forMaxMessageWidth: maxMessageWidth, items: mediaAttachments)
        
        guard
            let firstAttachment: Attachment = mediaAttachments.first,
            var width: CGFloat = firstAttachment.width.map({ CGFloat($0) }),
            var height: CGFloat = firstAttachment.height.map({ CGFloat($0) }),
            mediaAttachments.count == 1,
            width > 0,
            height > 0
        else { return defaultSize }
        
        // Honor the content aspect ratio for single media
        let size: CGSize = CGSize(width: width, height: height)
        var aspectRatio = (size.width / size.height)
        // Clamp the aspect ratio so that very thin/wide content still looks alright
        let minAspectRatio: CGFloat = 0.35
        let maxAspectRatio = 1 / minAspectRatio
        let maxSize = CGSize(width: maxMessageWidth, height: maxMessageWidth)
        aspectRatio = aspectRatio.clamp(minAspectRatio, maxAspectRatio)
        
        if aspectRatio > 1 {
            width = maxSize.width
            height = width / aspectRatio
        }
        else {
            height = maxSize.height
            width = height * aspectRatio
        }
        
        // Don't blow up small images unnecessarily
        let minSize: CGFloat = 150
        let shortSourceDimension = min(size.width, size.height)
        let shortDestinationDimension = min(width, height)
        
        if shortDestinationDimension > minSize && shortDestinationDimension > shortSourceDimension {
            let factor = minSize / shortDestinationDimension
            width *= factor; height *= factor
        }
        
        return CGSize(width: width, height: height)
    }

    static func getMaxWidth(for cellViewModel: MessageViewModel) -> CGFloat {
        let screen: CGRect = UIScreen.main.bounds
        
        switch cellViewModel.variant {
            case .standardOutgoing: return (screen.width - contactThreadHSpacing - gutterSize)
            case .standardIncoming, .standardIncomingDeleted:
                let isGroupThread = (
                    cellViewModel.threadVariant == .openGroup ||
                    cellViewModel.threadVariant == .closedGroup
                )
                let leftGutterSize = (isGroupThread ? gutterSize : contactThreadHSpacing)
                
                return (screen.width - leftGutterSize - gutterSize)
                
            default: preconditionFailure()
        }
    }

    static func getBodyTextView(
        for cellViewModel: MessageViewModel,
        with availableWidth: CGFloat,
        textColor: UIColor,
        searchText: String?,
        delegate: (UITextViewDelegate & BodyTextViewDelegate)?
    ) -> UITextView {
        // Take care of:
        // • Highlighting mentions
        // • Linkification
        // • Highlighting search results
        //
        // Note: We can't just set 'isSelectable' to false otherwise the link detection/selection
        // stops working
        let isOutgoing: Bool = (cellViewModel.variant == .standardOutgoing)
        let result: BodyTextView = BodyTextView(snDelegate: delegate)
        result.isEditable = false
        
        let attributedText: NSMutableAttributedString = NSMutableAttributedString(
            attributedString: MentionUtilities.highlightMentions(
                in: (cellViewModel.body ?? ""),
                threadVariant: cellViewModel.threadVariant,
                currentUserPublicKey: cellViewModel.currentUserPublicKey,
                currentUserBlindedPublicKey: cellViewModel.currentUserBlindedPublicKey,
                isOutgoingMessage: isOutgoing,
                attributes: [
                    .foregroundColor : textColor,
                    .font : UIFont.systemFont(ofSize: getFontSize(for: cellViewModel))
                ]
            )
        )
        
        // If there is a valid search term then highlight each part that matched
        if let searchText = searchText, searchText.count >= ConversationSearchController.minimumSearchTextLength {
            let normalizedBody: String = attributedText.string.lowercased()
            
            SessionThreadViewModel.searchTermParts(searchText)
                .map { part -> String in
                    guard part.hasPrefix("\"") && part.hasSuffix("\"") else { return part }
                    
                    return String(part[part.index(after: part.startIndex)..<part.endIndex])
                }
                .forEach { part in
                    // Highlight all ranges of the text (Note: The search logic only finds results that start
                    // with the term so we use the regex below to ensure we only highlight those cases)
                    normalizedBody
                        .ranges(
                            of: (CurrentAppContext().isRTL ?
                                 "\(part.lowercased())(^|[ ])" :
                                 "(^|[ ])\(part.lowercased())"
                            ),
                            options: [.regularExpression]
                        )
                        .forEach { range in
                            let legacyRange: NSRange = NSRange(range, in: normalizedBody)
                            attributedText.addAttribute(.backgroundColor, value: UIColor.white, range: legacyRange)
                            attributedText.addAttribute(.foregroundColor, value: UIColor.black, range: legacyRange)
                        }
                }
        }
        
        result.attributedText = attributedText
        result.dataDetectorTypes = .link
        result.backgroundColor = .clear
        result.isOpaque = false
        result.textContainerInset = UIEdgeInsets.zero
        result.contentInset = UIEdgeInsets.zero
        result.textContainer.lineFragmentPadding = 0
        result.isScrollEnabled = false
        result.isUserInteractionEnabled = true
        result.delegate = delegate
        result.linkTextAttributes = [
            .foregroundColor: textColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        
        let availableSpace = CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
        let size = result.sizeThatFits(availableSpace)
        result.set(.height, to: size.height)
        
        return result
    }
}
