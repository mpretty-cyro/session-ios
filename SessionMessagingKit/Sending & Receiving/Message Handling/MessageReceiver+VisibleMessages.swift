// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionSnodeKit
import SessionUtilitiesKit

extension MessageReceiver {
    @discardableResult public static func handleVisibleMessage(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: VisibleMessage,
        preparedAttachments: [String: Attachment]?,
        associatedWithProto proto: SNProtoContent,
        canShowNotification: Bool,
        using dependencies: Dependencies = Dependencies()
    ) throws -> Int64 {
        guard let sender: String = message.sender, let dataMessage = proto.dataMessage else {
            throw MessageReceiverError.invalidMessage
        }
        
        // Note: `message.sentTimestamp` is in ms (convert to TimeInterval before converting to
        // seconds to maintain the accuracy)
        let messageSentTimestamp: TimeInterval = (TimeInterval(message.sentTimestamp ?? 0) / 1000)
        let isMainAppActive: Bool = (UserDefaults.sharedLokiProject?[.isMainAppActive]).defaulting(to: false)
        
        // Update profile if needed (want to do this regardless of whether the message exists or
        // not to ensure the profile info gets sync between a users devices at every chance)
        if let profile = message.profile {
            try ProfileManager.updateProfileIfNeeded(
                db,
                publicKey: sender,
                name: profile.displayName,
                blocksCommunityMessageRequests: profile.blocksCommunityMessageRequests,
                avatarUpdate: {
                    guard
                        let profilePictureUrl: String = profile.profilePictureUrl,
                        let profileKey: Data = profile.profileKey
                    else { return .remove }
                    
                    return .updateTo(
                        url: profilePictureUrl,
                        key: profileKey,
                        fileName: nil
                    )
                }(),
                sentTimestamp: messageSentTimestamp,
                using: dependencies
            )
        }
        
        switch threadVariant {
            case .contact: break // Always continue
            
            case .community:
                // Only process visible messages for communities if they have an existing thread
                guard (try? SessionThread.exists(db, id: threadId)) == true else {
                    throw MessageReceiverError.noThread
                }
                        
            case .legacyGroup, .group:
                // Only process visible messages for groups if they have a ClosedGroup record
                guard (try? ClosedGroup.exists(db, id: threadId)) == true else {
                    throw MessageReceiverError.noThread
                }
        }
        
        // Store the message variant so we can run variant-specific behaviours
        let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
        let thread: SessionThread = try SessionThread
            .fetchOrCreate(db, id: threadId, variant: threadVariant, shouldBeVisible: nil)
        let maybeOpenGroup: OpenGroup? = {
            guard threadVariant == .community else { return nil }
            
            return try? OpenGroup.fetchOne(db, id: threadId)
        }()
        
        // Handle emoji reacts first (otherwise it's essentially an invalid message)
        if let interactionId: Int64 = try handleEmojiReactIfNeeded(
            db,
            thread: thread,
            message: message,
            associatedWithProto: proto,
            sender: sender,
            messageSentTimestamp: messageSentTimestamp,
            openGroup: maybeOpenGroup
        ) {
            return interactionId
        }
        
        // Retrieve the disappearing messages config to set the 'expiresInSeconds' value
        // accoring to the config
        let disappearingMessagesConfiguration: DisappearingMessagesConfiguration = (try? thread.disappearingMessagesConfiguration.fetchOne(db))
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(thread.id))
        
        // Try to insert the interaction
        //
        // Note: There are now a number of unique constraints on the database which
        // prevent the ability to insert duplicate interactions at a database level
        // so we don't need to check for the existance of a message beforehand anymore
        let interaction: Interaction
        let interactionVariant: Interaction.Variant = try getVariant(
            db,
            threadId: thread.id,
            threadVariant: thread.variant,
            message: message,
            currentUserPublicKey: currentUserPublicKey,
            openGroup: maybeOpenGroup,
            using: dependencies
        )
        
        do {
            interaction = try createInteraction(
                db,
                threadId: thread.id,
                threadVariant: thread.variant,
                message: message,
                customBody: nil,
                interactionVariant: interactionVariant,
                associatedWithProto: proto,
                currentUserPublicKey: currentUserPublicKey,
                openGroup: maybeOpenGroup,
                disappearingMessagesConfiguration: disappearingMessagesConfiguration
            ).inserted(db)
        }
        catch {
            switch error {
                case DatabaseError.SQLITE_CONSTRAINT_UNIQUE:
                    guard
                        interactionVariant == .standardOutgoing,
                        let existingInteractionId: Int64 = try? thread.interactions
                            .select(.id)
                            .filter(Interaction.Columns.timestampMs == (messageSentTimestamp * 1000))
                            .filter(Interaction.Columns.variant == interactionVariant)
                            .filter(Interaction.Columns.authorId == sender)
                            .asRequest(of: Int64.self)
                            .fetchOne(db)
                    else { break }
                    
                    // If we receive an outgoing message that already exists in the database
                    // then we still need up update the recipient and read states for the
                    // message (even if we don't need to do anything else)
                    try updateRecipientAndReadStatesForOutgoingInteraction(
                        db,
                        thread: thread,
                        interactionId: existingInteractionId,
                        messageSentTimestamp: messageSentTimestamp,
                        variant: interactionVariant,
                        syncTarget: message.syncTarget
                    )
                    
                default: break
            }
            
            throw error
        }
        
        guard let interactionId: Int64 = interaction.id else { throw StorageError.failedToSave }
        
        // Update and recipient and read states as needed
        try updateRecipientAndReadStatesForOutgoingInteraction(
            db,
            thread: thread,
            interactionId: interactionId,
            messageSentTimestamp: messageSentTimestamp,
            variant: interactionVariant,
            syncTarget: message.syncTarget
        )
        
        // Parse & persist attachments
        let attachments: [Attachment] = try dataMessage.attachments
            .compactMap { proto -> Attachment? in
                // If we have a prepared attachment then use that over the proto
                let attachment: Attachment = (preparedAttachments?["\(proto.id)"] ?? Attachment(proto: proto))
                
                // Attachments on received messages must have a 'downloadUrl' otherwise
                // they are invalid and we can ignore them
                return (attachment.downloadUrl != nil ? attachment : nil)
            }
            .enumerated()
            .map { index, attachment in
                let savedAttachment: Attachment = try attachment.saved(db)
                
                // Link the attachment to the interaction and add to the id lookup
                try InteractionAttachment(
                    albumIndex: index,
                    interactionId: interactionId,
                    attachmentId: savedAttachment.id
                ).insert(db)
                
                return savedAttachment
            }
        
        message.attachmentIds = attachments.map { $0.id }
        
        // Persist quote if needed
        let quote: Quote? = try? Quote(
            db,
            proto: dataMessage,
            interactionId: interactionId,
            thread: thread,
            preparedAttachments: preparedAttachments
        )?.inserted(db)
        
        // Parse link preview if needed
        let linkPreview: LinkPreview? = try? LinkPreview(
            db,
            proto: dataMessage,
            body: message.text,
            sentTimestampMs: (messageSentTimestamp * 1000),
            preparedAttachments: preparedAttachments
        )?.saved(db)
        
        // Open group invitations are stored as LinkPreview values so create one if needed
        if
            let openGroupInvitationUrl: String = message.openGroupInvitation?.url,
            let openGroupInvitationName: String = message.openGroupInvitation?.name
        {
            try LinkPreview(
                url: openGroupInvitationUrl,
                timestamp: LinkPreview.timestampFor(sentTimestampMs: (messageSentTimestamp * 1000)),
                variant: .openGroupInvitation,
                title: openGroupInvitationName
            ).save(db)
        }
        
        // Start attachment downloads if needed (ie. trusted contact or group thread)
        // FIXME: Replace this to check the `autoDownloadAttachments` flag we are adding to threads
        let isContactTrusted: Bool = ((try? Contact.fetchOne(db, id: sender))?.isTrusted ?? false)

        if isContactTrusted || thread.variant != .contact {
            attachments
                .map { $0.id }
                .appending(quote?.attachmentId)
                .appending(linkPreview?.attachmentId)
                .forEach { attachmentId in
                    dependencies.jobRunner.add(
                        db,
                        job: Job(
                            variant: .attachmentDownload,
                            threadId: thread.id,
                            interactionId: interactionId,
                            details: AttachmentDownloadJob.Details(
                                attachmentId: attachmentId
                            )
                        ),
                        canStartJob: isMainAppActive,
                        using: dependencies
                    )
                }
        }
        
        // Cancel any typing indicators if needed
        if isMainAppActive {
            TypingIndicators.didStopTyping(db, threadId: thread.id, direction: .incoming)
        }
        
        // Update the contact's approval status of the current user if needed (if we are getting messages from
        // them outside of a group then we can assume they have approved the current user)
        //
        // Note: This is to resolve a rare edge-case where a conversation was started with a user on an old
        // version of the app and their message request approval state was set via a migration rather than
        // by using the approval process
        if thread.variant == .contact {
            try MessageReceiver.updateContactApprovalStatusIfNeeded(
                db,
                senderSessionId: sender,
                threadId: thread.id
            )
        }
        
        // Notify the user if needed
        guard
            canShowNotification &&
            interactionVariant == .standardIncoming &&
            !interaction.wasRead
        else { return interactionId }
        
        // Use the same identifier for notifications when in backgroud polling to prevent spam
        Environment.shared?.notificationsManager.wrappedValue?
            .notifyUser(
                db,
                for: interaction,
                in: thread,
                applicationState: (isMainAppActive ? .active : .background)
            )
        
        return interactionId
    }
    
    /// This function checks the database to see if a message trips any of the unique constraints, this should only be used as a
    /// "likely to be a duplicate" check and we should still attempt to insert the message to rely on the actual unique constraints
    /// just in case some are added/removed in the future
    ///
    /// The logic in this method should always match the unique constrants on the `Interaction` table
    public static func isDuplicateMessage(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message
    ) -> Bool {
        switch threadVariant {
            case .community:
                // If we don't have an 'openGroupServerMessageId' for some reason then the unique constraint won't
                // be triggered
                guard let openGroupServerMessageId: UInt64 = message.openGroupServerMessageId else { return false }
                
                /// Community conversations use a different identifier so we should only use that to check
                /// if there is an existing entry:
                ///   `threadId`                                        - Unique per thread
                ///   `openGroupServerMessageId`     - Unique for VisibleMessage's on an OpenGroup server
                return Interaction
                    .filter(
                        Interaction.Columns.threadId == threadId &&
                        Interaction.Columns.openGroupServerMessageId == Int64(openGroupServerMessageId)
                    )
                    .isNotEmpty(db)
                
            default:
                // If a message doesn't have a sender then it's considered invalid and we can ignore it
                guard let sender: String = message.sender else { return false }
                
                /// Other conversations have a number of different combinations which indicate whether a message is a duplicate:
                ///   "Sync" messages (messages we resend to the current to ensure it appears on all linked devices):
                ///     `threadId`                    - Unique per thread
                ///     `authorId`                    - Unique per user
                ///     `timestampMs`              - Very low chance of collision (especially combined with other two)
                ///
                ///   Standard messages #1:
                ///     `threadId`                    - Unique per thread
                ///     `serverHash`                - Unique per message (deterministically generated)
                ///
                ///   Standard messages #1:
                ///     `threadId`                    - Unique per thread
                ///     `messageUuid`             - Very low chance of collision (especially combined with threadId)
                return Interaction
                    .filter(
                        Interaction.Columns.threadId == threadId && (
                            (
                                Interaction.Columns.authorId == sender &&
                                Interaction.Columns.timestampMs == (TimeInterval(message.sentTimestamp ?? 0) / 1000)
                            ) || (
                                message.serverHash != nil &&
                                Interaction.Columns.serverHash == message.serverHash
                            ) || (
                                (message as? CallMessage)?.uuid != nil &&
                                Interaction.Columns.messageUuid == (message as? CallMessage)?.uuid
                            )
                        )
                    )
                    .isNotEmpty(db)
        }
    }
    
    public static func getVariant(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        currentUserPublicKey: String,
        openGroup: OpenGroup? = nil,
        using dependencies: Dependencies = Dependencies()
    ) throws -> Interaction.Variant {
        let maybeOpenGroup: OpenGroup? = {
            guard threadVariant == .community else { return nil }
            
            return (openGroup ?? (try? OpenGroup.fetchOne(db, id: threadId)))
        }()
        
        guard
            let sender: String = message.sender,
            let senderSessionId: SessionId = SessionId(from: sender),
            let openGroup: OpenGroup = maybeOpenGroup
        else {
            return (message.sender == currentUserPublicKey ?
                .standardOutgoing :
                .standardIncoming
            )
        }

        // Need to check if the blinded id matches for open groups
        switch senderSessionId.prefix {
            case .blinded15, .blinded25:
                guard
                    let userEdKeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db),
                    let blindedKeyPair: KeyPair = dependencies.crypto.generate(
                        .blindedKeyPair(
                            serverPublicKey: openGroup.publicKey,
                            edKeyPair: userEdKeyPair,
                            using: dependencies
                        )
                    )
                else { return .standardIncoming }
                
                let senderIdCurrentUserBlinded: Bool = (
                    sender == SessionId(.blinded15, publicKey: blindedKeyPair.publicKey).hexString ||
                    sender == SessionId(.blinded25, publicKey: blindedKeyPair.publicKey).hexString
                )
                
                return (senderIdCurrentUserBlinded ?
                    .standardOutgoing :
                    .standardIncoming
                )
                
            case .standard, .unblinded:
                return (sender == currentUserPublicKey ?
                    .standardOutgoing :
                    .standardIncoming
                )
                
            case .group:
                SNLog("Ignoring message with invalid sender.")
                throw HTTPError.parsingFailed
        }
    }
    
    public static func createInteraction(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        customBody: String?,
        interactionVariant: Interaction.Variant,
        associatedWithProto proto: SNProtoContent?,
        currentUserPublicKey: String,
        openGroup: OpenGroup? = nil,
        disappearingMessagesConfiguration: DisappearingMessagesConfiguration? = nil,
        using dependencies: Dependencies = Dependencies()
    ) throws -> Interaction {
        guard
            let sender: String = message.sender,
            let timestampMs: Int64 = message.sentTimestamp.map({ Int64($0) })
        else { throw MessageReceiverError.invalidMessage }
        
        let disappearingMessagesConfiguration: DisappearingMessagesConfiguration = disappearingMessagesConfiguration
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(threadId))
        
        return Interaction(
            serverHash: message.serverHash, // Keep track of server hash
            threadId: threadId,
            authorId: sender,
            variant: interactionVariant,
            body: (customBody ?? (message as? VisibleMessage)?.text),
            timestampMs: timestampMs,
            wasRead: Interaction.isAlreadyRead(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                variant: interactionVariant,
                timestampMs: timestampMs,
                currentUserPublicKey: currentUserPublicKey,
                openGroup: openGroup
            ),
            hasMention: (message as? VisibleMessage)
                .map {
                    Interaction.isUserMentioned(
                        db,
                        threadId: threadId,
                        body: $0.text,
                        quoteAuthorId: proto?.dataMessage?.quote?.author,
                        using: dependencies
                    )
                }
                .defaulting(to: false),
            // Note: Ensure we don't ever expire open group messages
            expiresInSeconds: (disappearingMessagesConfiguration.isEnabled && message.openGroupServerMessageId == nil ?
                disappearingMessagesConfiguration.durationSeconds :
                nil
            ),
            expiresStartedAtMs: nil,
            // OpenGroupInvitations are stored as LinkPreview's in the database
            linkPreviewUrl: (message as? VisibleMessage).map { ($0.linkPreview?.url ?? $0.openGroupInvitation?.url) },
            // Keep track of the open group server message ID ↔ message ID relationship
            openGroupServerMessageId: message.openGroupServerMessageId.map { Int64($0) },
            openGroupWhisperMods: (message.recipient?.contains(".mods") == true),
            openGroupWhisperTo: {
                guard
                    let recipientParts: [String] = message.recipient?.components(separatedBy: "."),
                    recipientParts.count >= 3  // 'server.roomToken.whisperTo.whisperMods'
                else { return nil }
                
                return recipientParts[2]
            }()
        )
    }
    
    private static func handleEmojiReactIfNeeded(
        _ db: Database,
        thread: SessionThread,
        message: VisibleMessage,
        associatedWithProto proto: SNProtoContent,
        sender: String,
        messageSentTimestamp: TimeInterval,
        openGroup: OpenGroup?
    ) throws -> Int64? {
        guard
            let reaction: VisibleMessage.VMReaction = message.reaction,
            proto.dataMessage?.reaction != nil
        else { return nil }
        
        let maybeInteractionId: Int64? = try? Interaction
            .select(.id)
            .filter(Interaction.Columns.threadId == thread.id)
            .filter(Interaction.Columns.timestampMs == reaction.timestamp)
            .filter(Interaction.Columns.authorId == reaction.publicKey)
            .filter(Interaction.Columns.variant != Interaction.Variant.standardIncomingDeleted)
            .asRequest(of: Int64.self)
            .fetchOne(db)
        
        guard let interactionId: Int64 = maybeInteractionId else {
            throw StorageError.objectNotFound
        }
        
        let sortId = Reaction.getSortId(
            db,
            interactionId: interactionId,
            emoji: reaction.emoji
        )
        
        switch reaction.kind {
            case .react:
                // Determine whether the app is active based on the prefs rather than the UIApplication state to avoid
                // requiring main-thread execution
                let isMainAppActive: Bool = (UserDefaults.sharedLokiProject?[.isMainAppActive]).defaulting(to: false)
                let timestampMs: Int64 = Int64(messageSentTimestamp * 1000)
                let currentUserPublicKey: String = getUserHexEncodedPublicKey(db)
                let reaction: Reaction = try Reaction(
                    interactionId: interactionId,
                    serverHash: message.serverHash,
                    timestampMs: timestampMs,
                    authorId: sender,
                    emoji: reaction.emoji,
                    count: 1,
                    sortId: sortId
                ).inserted(db)
                let timestampAlreadyRead: Bool = SessionUtil.timestampAlreadyRead(
                    threadId: thread.id,
                    threadVariant: thread.variant,
                    timestampMs: timestampMs,
                    userPublicKey: currentUserPublicKey,
                    openGroup: openGroup
                )
                
                // Don't notify if the reaction was added before the lastest read timestamp for
                // the conversation
                if sender != currentUserPublicKey && !timestampAlreadyRead {
                    Environment.shared?.notificationsManager.wrappedValue?
                        .notifyUser(
                            db,
                            forReaction: reaction,
                            in: thread,
                            applicationState: (isMainAppActive ? .active : .background)
                        )
                }
            case .remove:
                try Reaction
                    .filter(Reaction.Columns.interactionId == interactionId)
                    .filter(Reaction.Columns.authorId == sender)
                    .filter(Reaction.Columns.emoji == reaction.emoji)
                    .deleteAll(db)
        }
        
        return interactionId
    }
    
    private static func updateRecipientAndReadStatesForOutgoingInteraction(
        _ db: Database,
        thread: SessionThread,
        interactionId: Int64,
        messageSentTimestamp: TimeInterval,
        variant: Interaction.Variant,
        syncTarget: String?
    ) throws {
        guard variant == .standardOutgoing else { return }
        
        // Immediately update any existing outgoing message 'RecipientState' records to be 'sent'
        _ = try? RecipientState
            .filter(RecipientState.Columns.interactionId == interactionId)
            .filter(RecipientState.Columns.state != RecipientState.State.sent)
            .updateAll(db, RecipientState.Columns.state.set(to: RecipientState.State.sent))
        
        // Create any addiitonal 'RecipientState' records as needed
        switch thread.variant {
            case .contact:
                if let syncTarget: String = syncTarget {
                    try RecipientState(
                        interactionId: interactionId,
                        recipientId: syncTarget,
                        state: .sent
                    ).save(db)
                }
                
            case .legacyGroup, .group:
                try GroupMember
                    .filter(GroupMember.Columns.groupId == thread.id)
                    .fetchAll(db)
                    .forEach { member in
                        try RecipientState(
                            interactionId: interactionId,
                            recipientId: member.profileId,
                            state: .sent
                        ).save(db)
                    }
                
            case .community:
                try RecipientState(
                    interactionId: interactionId,
                    recipientId: thread.id, // For open groups this will always be the thread id
                    state: .sent
                ).save(db)
        }
    
        // For outgoing messages mark all older interactions as read (the user should have seen
        // them if they send a message - also avoids a situation where the user has "phantom"
        // unread messages that they need to scroll back to before they become marked as read)
        try Interaction.markAsRead(
            db,
            interactionId: interactionId,
            threadId: thread.id,
            threadVariant: thread.variant,
            includingOlder: true,
            trySendReadReceipt: false
        )
        
        // Process any PendingReadReceipt values
        let maybePendingReadReceipt: PendingReadReceipt? = try PendingReadReceipt
            .filter(PendingReadReceipt.Columns.threadId == thread.id)
            .filter(PendingReadReceipt.Columns.interactionTimestampMs == Int64(messageSentTimestamp * 1000))
            .fetchOne(db)
        
        if let pendingReadReceipt: PendingReadReceipt = maybePendingReadReceipt {
            try Interaction.markAsRead(
                db,
                recipientId: thread.id,
                timestampMsValues: [pendingReadReceipt.interactionTimestampMs],
                readTimestampMs: pendingReadReceipt.readTimestampMs
            )
            
            _ = try pendingReadReceipt.delete(db)
        }
    }
}
