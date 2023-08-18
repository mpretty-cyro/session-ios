// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class VisibleMessage: Message {
    private enum CodingKeys: String, CodingKey {
        case syncTarget
        case text = "body"
        case attachmentIds = "attachments"
        case quote
        case linkPreview
        case profile
        case openGroupInvitation
        case reaction
    }
    
    /// In the case of a sync message, the public key of the person the message was targeted at.
    ///
    /// - Note: `nil` if this isn't a sync message.
    public var syncTarget: String?
    public let text: String?
    public var attachmentIds: [String]
    public let quote: VMQuote?
    public let linkPreview: VMLinkPreview?
    public var profile: VMProfile?
    public let openGroupInvitation: VMOpenGroupInvitation?
    public let reaction: VMReaction?

    public override var isSelfSendValid: Bool { true }
    
    // MARK: - Validation
    
    public override var isValid: Bool {
        guard super.isValid else { return false }
        if !attachmentIds.isEmpty { return true }
        if openGroupInvitation != nil { return true }
        if reaction != nil { return true }
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return true }
        return false
    }
    
    // MARK: - Initialization
    
    public init(
        sender: String? = nil,
        sentTimestamp: UInt64? = nil,
        recipient: String? = nil,
        groupPublicKey: String? = nil,
        syncTarget: String? = nil,
        text: String?,
        attachmentIds: [String] = [],
        quote: VMQuote? = nil,
        linkPreview: VMLinkPreview? = nil,
        profile: VMProfile? = nil,
        openGroupInvitation: VMOpenGroupInvitation? = nil,
        reaction: VMReaction? = nil
    ) {
        self.syncTarget = syncTarget
        self.text = text
        self.attachmentIds = attachmentIds
        self.quote = quote
        self.linkPreview = linkPreview
        self.profile = profile
        self.openGroupInvitation = openGroupInvitation
        self.reaction = reaction
        
        super.init(
            sentTimestamp: sentTimestamp,
            recipient: recipient,
            sender: sender,
            groupPublicKey: groupPublicKey
        )
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        syncTarget = try? container.decode(String.self, forKey: .syncTarget)
        text = try? container.decode(String.self, forKey: .text)
        attachmentIds = ((try? container.decode([String].self, forKey: .attachmentIds)) ?? [])
        quote = try? container.decode(VMQuote.self, forKey: .quote)
        linkPreview = try? container.decode(VMLinkPreview.self, forKey: .linkPreview)
        profile = try? container.decode(VMProfile.self, forKey: .profile)
        openGroupInvitation = try? container.decode(VMOpenGroupInvitation.self, forKey: .openGroupInvitation)
        reaction = try? container.decode(VMReaction.self, forKey: .reaction)
        
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encodeIfPresent(syncTarget, forKey: .syncTarget)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(attachmentIds, forKey: .attachmentIds)
        try container.encodeIfPresent(quote, forKey: .quote)
        try container.encodeIfPresent(linkPreview, forKey: .linkPreview)
        try container.encodeIfPresent(profile, forKey: .profile)
        try container.encodeIfPresent(openGroupInvitation, forKey: .openGroupInvitation)
        try container.encodeIfPresent(reaction, forKey: .reaction)
    }

    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> VisibleMessage? {
        guard let dataMessage = proto.dataMessage else { return nil }
        
        return VisibleMessage(
            syncTarget: dataMessage.syncTarget,
            text: dataMessage.body,
            attachmentIds: [],    // Attachments are handled in MessageReceiver
            quote: dataMessage.quote.map { VMQuote.fromProto($0) },
            linkPreview: dataMessage.preview.first.map { VMLinkPreview.fromProto($0) },
            profile: VMProfile.fromProto(dataMessage),
            openGroupInvitation: dataMessage.openGroupInvitation.map { VMOpenGroupInvitation.fromProto($0) },
            reaction: dataMessage.reaction.map { VMReaction.fromProto($0) }
        )
    }

    public override func toProto(attachments: [Attachment]?) throws -> SNProtoContent? {
        let proto = SNProtoContent.builder()
        let dataMessage: SNProtoDataMessage.SNProtoDataMessageBuilder
        var processedAttachmentIds: [String] = self.attachmentIds
        var processedAttachments: [Attachment] = (attachments ?? [])
        
        func allOrNothing(_ elements: [Any?]) -> Bool {
            let existingElements: [Any] = elements.compactMap { $0 }
            
            return (existingElements.isEmpty || existingElements.count == elements.count)
        }
        
        // Profile
        if let profile = profile, let profileProto: SNProtoDataMessage = try? profile.toProto() {
            dataMessage = profileProto.asBuilder()
        }
        else {
            dataMessage = SNProtoDataMessage.builder()
        }
        
        // Text
        if let text = text { dataMessage.setBody(text) }
        
        // Quote (make sure if we have an id then we also have the attachment)
        let quoteAttachmentId: String? = processedAttachmentIds.popFirst { $0 == quote?.attachmentId }
        let quoteAttachment: Attachment? = processedAttachments.popFirst { $0.id == quote?.attachmentId }
        
        guard allOrNothing([quote?.attachmentId, quoteAttachmentId, quoteAttachment]) else {
            throw MessageSenderError.invalidMessage
        }
        
        if let quoteProto = try? quote?.toProto(attachment: quoteAttachment) {
            dataMessage.setQuote(quoteProto)
        }
        
        // Link preview (make sure if we have an id then we also have the attachment)
        let previewAttachmentId: String? = processedAttachmentIds.popFirst { $0 == linkPreview?.attachmentId }
        let previewAttachment: Attachment? = processedAttachments.popFirst { $0.id == linkPreview?.attachmentId }
                
        guard allOrNothing([linkPreview?.attachmentId, previewAttachmentId, previewAttachment]) else {
            throw MessageSenderError.invalidMessage
        }
        
        if let linkPreviewProto = try? linkPreview?.toProto(attachment: previewAttachment) {
            dataMessage.setPreview([ linkPreviewProto ])
        }
        
        // Attachments (make sure the ids match (ignoring ordering - the `attachments` array should
        // be in the correct order)
        guard processedAttachmentIds.asSet() == processedAttachments.map({ $0.id }).asSet() else {
            throw MessageSenderError.invalidMessage
        }
        
        let attachmentProtos = processedAttachments.compactMap { $0.buildProto() }
        dataMessage.setAttachments(attachmentProtos)
        
        // Open group invitation
        if
            let openGroupInvitation = openGroupInvitation,
            let openGroupInvitationProto = openGroupInvitation.toProto()
        {
            dataMessage.setOpenGroupInvitation(openGroupInvitationProto)
        }
        
        // Emoji react
        if let reaction = reaction, let reactionProto = reaction.toProto() {
            dataMessage.setReaction(reactionProto)
        }
        
        // Sync target
        if let syncTarget = syncTarget {
            dataMessage.setSyncTarget(syncTarget)
        }
        
        // Build
        do {
            proto.setDataMessage(try dataMessage.build())
            return try proto.build()
        } catch {
            SNLog("Couldn't construct visible message proto from: \(self).")
            return nil
        }
    }
    
    // MARK: - Description
    
    public var description: String {
        """
        VisibleMessage(
            text: \(text ?? "null"),
            attachmentIds: \(attachmentIds),
            quote: \(quote?.description ?? "null"),
            linkPreview: \(linkPreview?.description ?? "null"),
            profile: \(profile?.description ?? "null"),
            reaction: \(reaction?.description ?? "null"),
            openGroupInvitation: \(openGroupInvitation?.description ?? "null")
        )
        """
    }
}

// MARK: - Database Type Conversion

public extension VisibleMessage {
    static func from(_ db: Database, interaction: Interaction) -> VisibleMessage {
        let linkPreview: LinkPreview? = try? interaction.linkPreview.fetchOne(db)
        let quote: Quote? = try? interaction.quote.fetchOne(db)
        
        return VisibleMessage.from(
            authorId: interaction.authorId,
            sentTimestamp: UInt64(interaction.timestampMs),
            recipientId: (try? interaction.recipientStates.fetchOne(db))?.recipientId,
            groupPublicKey: try? interaction.thread
                .filter(
                    SessionThread.Columns.variant == SessionThread.Variant.legacyGroup ||
                    SessionThread.Columns.variant == SessionThread.Variant.group
                )
                .select(.id)
                .asRequest(of: String.self)
                .fetchOne(db),
            body: interaction.body,
            attachmentIds: ((try? interaction.attachments.fetchAll(db)) ?? [])
                .map { $0.id }
                .appending(quote?.attachmentId)
                .appending(linkPreview?.attachmentId),
            quote: quote.map { VMQuote.from(db, quote: $0) },
            linkPreview: linkPreview
                .map { linkPreview in
                    guard linkPreview.variant == .standard else { return nil }
                    
                    return VMLinkPreview.from(db, linkPreview: linkPreview)
                },
            openGroupInvitation: linkPreview.map { linkPreview in
                guard linkPreview.variant == .openGroupInvitation else { return nil }
                
                return VMOpenGroupInvitation.from(
                    db,
                    linkPreview: linkPreview
                )
            }
        )
    }
    
    static func from(
        authorId: String,
        sentTimestamp: UInt64,
        recipientId: String?,
        groupPublicKey: String?,
        body: String?,
        attachmentIds: [String],
        quote: VMQuote?,
        linkPreview: VMLinkPreview?,
        openGroupInvitation: VMOpenGroupInvitation?
    ) -> VisibleMessage {
        return VisibleMessage(
            sender: authorId,
            sentTimestamp: sentTimestamp,
            recipient: recipientId,
            groupPublicKey: groupPublicKey,
            syncTarget: nil,
            text: body,
            attachmentIds: attachmentIds,
            quote: quote,
            linkPreview: linkPreview,
            profile: nil,   // Don't attach the profile to avoid sending a legacy version (set in MessageSender)
            openGroupInvitation: openGroupInvitation,
            reaction: nil   // Reactions are custom messages sent separately
        )
    }
}
