// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

/// This migration goes through the current state of the database and generates config dumps for the user config types
enum _014_GenerateInitialUserConfigDumps: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "GenerateInitialUserConfigDumps" // stringlint:disable
    static let minExpectedRunDuration: TimeInterval = 4.0
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [
        Identity.self, SessionThread.self, Contact.self, Profile.self, ClosedGroup.self,
        OpenGroup.self, DisappearingMessagesConfiguration.self, GroupMember.self, ConfigDump.self
    ]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        // If we have no ed25519 key then there is no need to create cached dump data
        guard Identity.fetchUserEd25519KeyPair(db) != nil else {
            Storage.update(progress: 1, for: self, in: target, using: dependencies)
            return
        }
        
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        
        // MARK: - Retrieve Current Database Data
        
        // Retrieve all threads (we are going to base the config dump data on the active
        // threads rather than anything else in the database)
        let allThreads: [String: SessionThread] = try SessionThread
            .fetchAll(db)
            .reduce(into: [:]) { result, next in result[next.id] = next }
        
        // Exclude Note to Self, community, group and outgoing blinded message requests fro the contacts data
        let validContactIds: [String] = allThreads
            .values
            .filter { thread in
                thread.variant == .contact &&
                thread.id != userSessionId.hexString &&
                (try? SessionId(from: thread.id))?.prefix == .standard
            }
            .map { $0.id }
        let contactsData: [ContactInfo] = try Contact
            .filter(
                Contact.Columns.isBlocked == true ||
                validContactIds.contains(Contact.Columns.id)
            )
            .including(optional: Contact.profile)
            .asRequest(of: ContactInfo.self)
            .fetchAll(db)
        let threadIdsNeedingContacts: [String] = validContactIds
            .filter { contactId in !contactsData.contains(where: { $0.contact.id == contactId }) }
        let volatileThreadInfo: [LibSession.VolatileThreadInfo] = LibSession.VolatileThreadInfo
            .fetchAll(db, ids: Array(allThreads.keys))
        let legacyGroupData: [LibSession.LegacyGroupInfo] = try LibSession.LegacyGroupInfo.fetchAll(db)
        let communityData: [LibSession.OpenGroupUrlInfo] = try LibSession.OpenGroupUrlInfo.fetchAll(db, ids: Array(allThreads.keys))
        
        // MARK: - Update the LibSession state
        
        LibSession.loadState(db, using: dependencies)
        
        try dependencies[singleton: .libSession].mutate { state in
            // MARK: - UserProfile Config Settings
            
            LibSession.update(
                profile: Profile.fetchOrCreateCurrentUser(db),
                in: state
            )
            
            LibSession.updateNoteToSelf(
                priority: {
                    guard allThreads[userSessionId.hexString]?.shouldBeVisible == true else { return LibSession.hiddenPriority }
                    
                    return Int32(allThreads[userSessionId.hexString]?.pinnedPriority ?? 0)
                }(),
                in: state
            )
            
            try LibSession.upsert(
                contactData: contactsData
                    .appending(
                        contentsOf: threadIdsNeedingContacts
                            .map { contactId in
                                ContactInfo(
                                    contact: Contact.fetchOrCreate(db, id: contactId),
                                    profile: nil
                                )
                            }
                    )
                    .map { data in
                        LibSession.SyncedContactInfo(
                            id: data.contact.id,
                            contact: data.contact,
                            profile: data.profile,
                            priority: {
                                guard allThreads[data.contact.id]?.shouldBeVisible == true else {
                                    return LibSession.hiddenPriority
                                }
                                
                                return Int32(allThreads[data.contact.id]?.pinnedPriority ?? 0)
                            }(),
                            created: allThreads[data.contact.id]?.creationDateTimestamp
                        )
                    },
                in: state,
                using: dependencies
            )
            
            // MARK: - ConvoInfoVolatile Config Dump
                
            try LibSession.upsert(
                convoInfoVolatileChanges: volatileThreadInfo,
                in: state,
                using: dependencies
            )
        
            // MARK: - UserGroups Config Dump
        
            try LibSession.upsert(
                legacyGroups: legacyGroupData,
                in: state,
                using: dependencies
            )
            try LibSession.upsert(
                communities: communityData
                    .map { urlInfo in
                        LibSession.CommunityInfo(
                            urlInfo: urlInfo,
                            priority: Int32(allThreads[urlInfo.threadId]?.pinnedPriority ?? 0)
                        )
                    },
                in: state,
                using: dependencies
            )
            
            // MARK: - Threads
            
            try LibSession.upsert(
                threads: Array(allThreads.values),
                openGroupUrlInfo: communityData.reduce(into: [:]) { result, next in result[next.threadId] = next },
                in: state,
                using: dependencies
            )
        }
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
    
    struct ContactInfo: FetchableRecord, Decodable, ColumnExpressible {
        typealias Columns = CodingKeys
        enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case contact
            case profile
        }
        
        let contact: Contact
        let profile: Profile?
    }

    struct GroupInfo: FetchableRecord, Decodable, ColumnExpressible {
        typealias Columns = CodingKeys
        enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case closedGroup
            case disappearingMessagesConfiguration
            case groupMembers
        }
        
        let closedGroup: ClosedGroup
        let disappearingMessagesConfiguration: DisappearingMessagesConfiguration?
        let groupMembers: [GroupMember]
    }
}
