// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SignalCoreKit
import SessionUtilitiesKit

public struct ClosedGroup: Codable, Identifiable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "closedGroup" }
    internal static let threadForeignKey = ForeignKey([Columns.threadId], to: [SessionThread.Columns.id])
    private static let thread = belongsTo(SessionThread.self, using: threadForeignKey)
    internal static let keyPairs = hasMany(
        ClosedGroupKeyPair.self,
        using: ClosedGroupKeyPair.closedGroupForeignKey
    )
    public static let members = hasMany(GroupMember.self, using: GroupMember.closedGroupForeignKey)
    public static let maxNameLength: Int = 30
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case threadId
        case name
        case groupImageUrl
        case groupImageFileName
        case groupImageEncryptionKey
        case groupDescription
        case formationTimestamp
    }
    
    public var id: String { threadId }  // Identifiable
    public var publicKey: String { threadId }

    /// The id for the thread this closed group belongs to
    ///
    /// **Note:** This value will always be publicKey for the closed group
    public let threadId: String
    
    /// The name for the group
    public let name: String
    
    /// The URL from which to fetch the groups image
    public let groupImageUrl: String?

    /// The file name of the groups image in local storage
    public let groupImageFileName: String?

    /// The key with which the group image is encrypted
    public let groupImageEncryptionKey: OWSAES256Key?
    
    /// The description set for the group
    public let groupDescription: String?
    
    /// The timestamp at which the group was created
    public let formationTimestamp: TimeInterval
    
    // MARK: - Relationships
    
    public var thread: QueryInterfaceRequest<SessionThread> {
        request(for: ClosedGroup.thread)
    }
    
    public var keyPairs: QueryInterfaceRequest<ClosedGroupKeyPair> {
        request(for: ClosedGroup.keyPairs)
    }
    
    public var allMembers: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
    }
    
    public var members: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.standard)
    }
    
    public var zombies: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.zombie)
    }
    
    public var moderators: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.moderator)
    }
    
    public var admins: QueryInterfaceRequest<GroupMember> {
        request(for: ClosedGroup.members)
            .filter(GroupMember.Columns.role == GroupMember.Role.admin)
    }
    
    // MARK: - Initialization
    
    public init(
        threadId: String,
        name: String,
        groupImageUrl: String? = nil,
        groupImageFileName: String? = nil,
        groupImageEncryptionKey: OWSAES256Key? = nil,
        groupDescription: String? = nil,// TODO: Remove default values?
        formationTimestamp: TimeInterval
    ) {
        self.threadId = threadId
        self.name = name
        self.groupImageUrl = groupImageUrl
        self.groupImageFileName = groupImageFileName
        self.groupImageEncryptionKey = groupImageEncryptionKey
        self.groupDescription = groupDescription
        self.formationTimestamp = formationTimestamp
    }
}

// MARK: - Codable

public extension ClosedGroup {
    init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        var groupImageEncryptionKey: OWSAES256Key?
        var groupImageUrl: String?
        
        // If we have both a `groupImageEncryptionKey` and a `groupImageUrl` then the key MUST be valid
        if
            let groupImageEncryptionKeyData: Data = try? container.decode(Data.self, forKey: .groupImageEncryptionKey),
            let groupImageUrlValue: String = try? container.decode(String.self, forKey: .groupImageUrl)
        {
            if let validGroupImageEncryptionKey: OWSAES256Key = OWSAES256Key(data: groupImageEncryptionKeyData) {
                groupImageEncryptionKey = validGroupImageEncryptionKey
                groupImageUrl = groupImageUrlValue
            }
            else {
                SNLog("Failed to make groupImageEncryptionKey for ClosedGroup key data")
            }
        }
        
        self = ClosedGroup(
            threadId: try container.decode(String.self, forKey: .threadId),
            name: try container.decode(String.self, forKey: .name),
            groupImageUrl: groupImageUrl,
            groupImageFileName: try? container.decode(String.self, forKey: .groupImageFileName),
            groupImageEncryptionKey: groupImageEncryptionKey,
            groupDescription: try? container.decode(String.self, forKey: .groupDescription),
            formationTimestamp: try container.decode(TimeInterval.self, forKey: .formationTimestamp)
        )
    }
    
    func encode(to encoder: Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(threadId, forKey: .threadId)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(groupImageUrl, forKey: .groupImageUrl)
        try container.encodeIfPresent(groupImageFileName, forKey: .groupImageFileName)
        try container.encodeIfPresent(
            groupImageEncryptionKey?.keyData,
            forKey: .groupImageEncryptionKey
        )
        try container.encode(formationTimestamp, forKey: .formationTimestamp)
    }
}

// MARK: - GRDB Interactions

public extension ClosedGroup {
    func fetchLatestKeyPair(_ db: Database) throws -> ClosedGroupKeyPair? {
        return try keyPairs
            .order(ClosedGroupKeyPair.Columns.receivedTimestamp.desc)
            .fetchOne(db)
    }
}
