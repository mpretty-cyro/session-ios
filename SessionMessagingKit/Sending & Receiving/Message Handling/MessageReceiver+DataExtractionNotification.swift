// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleDataExtractionNotification(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: DataExtractionNotification
    ) throws {
        guard
            threadVariant == .contact,
            let sender: String = message.sender,
            let messageKind: DataExtractionNotification.Kind = message.kind
        else { throw MessageReceiverError.invalidMessage }
        
        let timestampMs: Int64 = (
            message.sentTimestamp.map { Int64($0) } ??
            SnodeAPI.currentOffsetTimestampMs()
        )
        let variant: Interaction.Variant = {
            switch messageKind {
                case .screenshot: return .infoScreenshotNotification
                case .mediaSaved: return .infoMediaSavedNotification
            }
        }()
        _ = try Interaction(
            serverHash: message.serverHash,
            threadId: threadId,
            authorId: sender,
            variant: variant,
            timestampMs: timestampMs,
            wasRead: Interaction.isAlreadyRead(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                variant: variant,
                timestampMs: timestampMs,
                currentUserPublicKey: getUserHexEncodedPublicKey(db)
            )
        ).inserted(db)
    }
}
