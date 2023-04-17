// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionMessagingKit

extension ContextMenuVC {
    struct Action {
        let icon: UIImage?
        let title: String
        let isEmojiAction: Bool
        let isEmojiPlus: Bool
        let isDismissAction: Bool
        let accessibilityLabel: String?
        let work: () -> Void
        
        // MARK: - Initialization
        
        init(
            icon: UIImage? = nil,
            title: String = "",
            isEmojiAction: Bool = false,
            isEmojiPlus: Bool = false,
            isDismissAction: Bool = false,
            accessibilityLabel: String? = nil,
            work: @escaping () -> Void
        ) {
            self.icon = icon
            self.title = title
            self.isEmojiAction = isEmojiAction
            self.isEmojiPlus = isEmojiPlus
            self.isDismissAction = isDismissAction
            self.accessibilityLabel = accessibilityLabel
            self.work = work
        }
        
        // MARK: - Actions
        
        static func info(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_info"),
                title: "context_menu_info".localized(),
                accessibilityLabel: "Message info"
            ) { delegate?.info(cellViewModel) }
        }

        static func retry(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(systemName: "arrow.triangle.2.circlepath"),
                title: (cellViewModel.state == .failedToSync ?
                    "context_menu_resync".localized() :
                    "context_menu_resend".localized()
                ),
                accessibilityLabel: (cellViewModel.state == .failedToSync ? "Resync message" : "Resend message")
            ) { delegate?.retry(cellViewModel) }
        }

        static func reply(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_reply"),
                title: "context_menu_reply".localized(),
                accessibilityLabel: "Reply to message"
            ) { delegate?.reply(cellViewModel) }
        }

        static func copy(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_copy"),
                title: "copy".localized(),
                accessibilityLabel: "Copy text"
            ) { delegate?.copy(cellViewModel) }
        }

        static func copySessionID(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_copy"),
                title: "vc_conversation_settings_copy_session_id_button_title".localized(),
                accessibilityLabel: "Copy Session ID"
                
            ) { delegate?.copySessionID(cellViewModel) }
        }

        static func delete(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_trash"),
                title: "TXT_DELETE_TITLE".localized(),
                accessibilityLabel: "Delete message"
            ) { delegate?.delete(cellViewModel) }
        }

        static func save(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_download"),
                title: "context_menu_save".localized(),
                accessibilityLabel: "Save attachment"
            ) { delegate?.save(cellViewModel) }
        }

        static func ban(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_block"),
                title: "context_menu_ban_user".localized(),
                accessibilityLabel: "Ban user"
            ) { delegate?.ban(cellViewModel) }
        }
        
        static func banAndDeleteAllMessages(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                icon: UIImage(named: "ic_block"),
                title: "context_menu_ban_and_delete_all".localized(),
                accessibilityLabel: "Ban user and delete"
            ) { delegate?.banAndDeleteAllMessages(cellViewModel) }
        }
        
        static func react(_ cellViewModel: MessageViewModel, _ emoji: EmojiWithSkinTones, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                title: emoji.rawValue,
                isEmojiAction: true
            ) { delegate?.react(cellViewModel, with: emoji) }
        }
        
        static func emojiPlusButton(_ cellViewModel: MessageViewModel, _ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                isEmojiPlus: true,
                accessibilityLabel: "Add emoji"
            ) { delegate?.showFullEmojiKeyboard(cellViewModel) }
        }
        
        static func dismiss(_ delegate: ContextMenuActionDelegate?) -> Action {
            return Action(
                isDismissAction: true
            ) { delegate?.contextMenuDismissed() }
        }
    }

    static func actions(
        for cellViewModel: MessageViewModel,
        recentEmojis: [EmojiWithSkinTones],
        currentUserPublicKey: String,
        currentUserBlindedPublicKey: String?,
        currentUserIsOpenGroupModerator: Bool,
        currentThreadIsMessageRequest: Bool,
        delegate: ContextMenuActionDelegate?
    ) -> [Action]? {
        switch cellViewModel.variant {
            case .standardIncomingDeleted, .infoCall,
                .infoScreenshotNotification, .infoMediaSavedNotification,
                .infoClosedGroupCreated, .infoClosedGroupUpdated,
                .infoClosedGroupCurrentUserLeft, .infoClosedGroupCurrentUserLeaving, .infoClosedGroupCurrentUserErrorLeaving,
                .infoMessageRequestAccepted, .infoDisappearingMessagesUpdate:
                // Let the user delete info messages and unsent messages
                return [ Action.delete(cellViewModel, delegate) ]
                
            case .standardOutgoing, .standardIncoming: break
        }
        
        let canRetry: Bool = (
            cellViewModel.variant == .standardOutgoing && (
                cellViewModel.state == .failed || (
                    cellViewModel.threadVariant == .contact &&
                    cellViewModel.state == .failedToSync
                )
            )
        )
        let canReply: Bool = (
            cellViewModel.variant != .standardOutgoing || (
                cellViewModel.state != .failed &&
                cellViewModel.state != .sending
            )
        )
        let canCopy: Bool = (
            cellViewModel.cellType == .textOnlyMessage || (
                (
                    cellViewModel.cellType == .genericAttachment ||
                    cellViewModel.cellType == .mediaMessage
                ) &&
                (cellViewModel.attachments ?? []).count == 1 &&
                (cellViewModel.attachments ?? []).first?.isVisualMedia == true &&
                (cellViewModel.attachments ?? []).first?.isValid == true && (
                    (cellViewModel.attachments ?? []).first?.state == .downloaded ||
                    (cellViewModel.attachments ?? []).first?.state == .uploaded
                )
            )
        )
        let canSave: Bool = (
            cellViewModel.cellType == .mediaMessage &&
            (cellViewModel.attachments ?? [])
                .filter { attachment in
                    attachment.isValid &&
                    attachment.isVisualMedia && (
                        attachment.state == .downloaded ||
                        attachment.state == .uploaded
                    )
                }.isEmpty == false
        )
        let canCopySessionId: Bool = (
            cellViewModel.variant == .standardIncoming &&
            cellViewModel.threadVariant != .openGroup
        )
        let canDelete: Bool = (
            cellViewModel.threadVariant != .openGroup ||
            currentUserIsOpenGroupModerator ||
            cellViewModel.authorId == currentUserPublicKey ||
            cellViewModel.authorId == currentUserBlindedPublicKey ||
            cellViewModel.state == .failed
        )
        let canBan: Bool = (
            cellViewModel.threadVariant == .openGroup &&
            currentUserIsOpenGroupModerator
        )
        
        let shouldShowEmojiActions: Bool = {
            if cellViewModel.threadVariant == .openGroup {
                return OpenGroupManager.isOpenGroupSupport(.reactions, on: cellViewModel.threadOpenGroupServer)
            }
            return !currentThreadIsMessageRequest
        }()
        
        let shouldShowInfo: Bool = (cellViewModel.attachments?.isEmpty == false)
        
        let generatedActions: [Action] = [
            (canRetry ? Action.retry(cellViewModel, delegate) : nil),
            (canReply ? Action.reply(cellViewModel, delegate) : nil),
            (canCopy ? Action.copy(cellViewModel, delegate) : nil),
            (canSave ? Action.save(cellViewModel, delegate) : nil),
            (canCopySessionId ? Action.copySessionID(cellViewModel, delegate) : nil),
            (canDelete ? Action.delete(cellViewModel, delegate) : nil),
            (canBan ? Action.ban(cellViewModel, delegate) : nil),
            (canBan ? Action.banAndDeleteAllMessages(cellViewModel, delegate) : nil),
            (shouldShowInfo ? Action.info(cellViewModel, delegate) : nil),
        ]
        .appending(contentsOf: (shouldShowEmojiActions ? recentEmojis : []).map { Action.react(cellViewModel, $0, delegate) })
        .appending(Action.emojiPlusButton(cellViewModel, delegate))
        .compactMap { $0 }
        
        guard !generatedActions.isEmpty else { return [] }
        
        return generatedActions.appending(Action.dismiss(delegate))
    }
}

// MARK: - Delegate

protocol ContextMenuActionDelegate {
    func info(_ cellViewModel: MessageViewModel)
    func retry(_ cellViewModel: MessageViewModel)
    func reply(_ cellViewModel: MessageViewModel)
    func copy(_ cellViewModel: MessageViewModel)
    func copySessionID(_ cellViewModel: MessageViewModel)
    func delete(_ cellViewModel: MessageViewModel)
    func save(_ cellViewModel: MessageViewModel)
    func ban(_ cellViewModel: MessageViewModel)
    func banAndDeleteAllMessages(_ cellViewModel: MessageViewModel)
    func react(_ cellViewModel: MessageViewModel, with emoji: EmojiWithSkinTones)
    func showFullEmojiKeyboard(_ cellViewModel: MessageViewModel)
    func contextMenuDismissed()
}
