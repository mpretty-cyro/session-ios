// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

extension MessageSender {
    
    // MARK: - Durable
    
    public static func send(
        _ db: Database,
        interaction: Interaction,
        threadId: String,
        threadVariant: SessionThread.Variant,
        isSyncMessage: Bool = false,
        using dependencies: Dependencies
    ) throws {
        // Only 'VisibleMessage' types can be sent via this method
        guard interaction.variant == .standardOutgoing else { throw MessageSenderError.invalidMessage }
        guard let interactionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
        
        send(
            db,
            message: VisibleMessage.from(db, interaction: interaction),
            threadId: threadId,
            interactionId: interactionId,
            to: try Message.Destination.from(db, threadId: threadId, threadVariant: threadVariant),
            isSyncMessage: isSyncMessage,
            using: dependencies
        )
    }
    
    public static func send(
        _ db: Database,
        message: Message,
        interactionId: Int64?,
        threadId: String,
        threadVariant: SessionThread.Variant,
        isSyncMessage: Bool = false,
        using dependencies: Dependencies
    ) throws {
        send(
            db,
            message: message,
            threadId: threadId,
            interactionId: interactionId,
            to: try Message.Destination.from(db, threadId: threadId, threadVariant: threadVariant),
            isSyncMessage: isSyncMessage,
            using: dependencies
        )
    }
    
    public static func send(
        _ db: Database,
        message: Message,
        threadId: String?,
        interactionId: Int64?,
        to destination: Message.Destination,
        isSyncMessage: Bool = false,
        using dependencies: Dependencies
    ) {
        // If it's a sync message then we need to make some slight tweaks before sending so use the proper
        // sync message sending process instead of the standard process
        guard !isSyncMessage else {
            scheduleSyncMessageIfNeeded(
                db,
                message: message,
                destination: destination,
                threadId: threadId,
                interactionId: interactionId,
                isAlreadySyncMessage: false,
                using: dependencies
            )
            return
        }
        
        dependencies.jobRunner.add(
            db,
            job: Job(
                variant: .messageSend,
                threadId: threadId,
                interactionId: interactionId,
                details: MessageSendJob.Details(
                    destination: destination,
                    message: message,
                    isSyncMessage: isSyncMessage
                )
            ),
            canStartJob: true,
            using: dependencies
        )
    }

    // MARK: - Non-Durable
    
    public static func preparedSendData(
        _ db: Database,
        message: Message,
        preparedAttachments: [Attachment.PreparedUpload]?,
        threadId: String,
        threadVariant: SessionThread.Variant,
        using dependencies: Dependencies
    ) throws -> PreparedSendData {
        return try MessageSender.preparedSendData(
            db,
            message: message,
            preparedAttachments: preparedAttachments,
            to: try Message.Destination.from(db, threadId: threadId, threadVariant: threadVariant),
            namespace: try Message.Destination
                .from(db, threadId: threadId, threadVariant: threadVariant)
                .defaultNamespace,
            interactionId: nil,
            using: dependencies
        )
    }
}
