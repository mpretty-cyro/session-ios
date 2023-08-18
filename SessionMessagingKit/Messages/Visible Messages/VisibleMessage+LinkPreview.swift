// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public extension VisibleMessage {
    struct VMLinkPreview: Codable {
        public let title: String?
        public let url: String?
        public let attachmentId: String?

        public var isValid: Bool { title != nil && url != nil && attachmentId != nil }
        
        // MARK: - Initialization

        internal init(title: String?, url: String, attachmentId: String?) {
            self.title = title
            self.url = url
            self.attachmentId = attachmentId
        }
        
        // MARK: - Proto Conversion

        public static func fromProto(_ proto: SNProtoDataMessagePreview) -> VMLinkPreview? {
            return VMLinkPreview(
                title: proto.title,
                url: proto.url,
                attachmentId: nil
            )
        }

        public func toProto(attachment: Attachment?) throws -> SNProtoDataMessagePreview? {
            guard let url = url else {
                SNLog("Couldn't construct link preview proto from: \(self).")
                return nil
            }
            let linkPreviewProto = SNProtoDataMessagePreview.builder(url: url)
            if let title = title { linkPreviewProto.setTitle(title) }
            
            if
                attachmentId != nil,
                let attachment: Attachment = attachment,
                let attachmentProto = attachment.buildProto()
            {
                linkPreviewProto.setImage(attachmentProto)
            }
            
            do {
                return try linkPreviewProto.build()
            } catch {
                SNLog("Couldn't construct link preview proto from: \(self).")
                return nil
            }
        }
        
        // MARK: - Description
        
        public var description: String {
            """
            LinkPreview(
                title: \(title ?? "null"),
                url: \(url ?? "null"),
                attachmentId: \(attachmentId ?? "null")
            )
            """
        }
    }
}

// MARK: - Database Type Conversion

public extension VisibleMessage.VMLinkPreview {
    static func from(_ db: Database, linkPreview: LinkPreview) -> VisibleMessage.VMLinkPreview {
        return VisibleMessage.VMLinkPreview(
            title: linkPreview.title,
            url: linkPreview.url,
            attachmentId: linkPreview.attachmentId
        )
    }
}
