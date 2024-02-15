// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Size Restrictions

public extension LibSession {
    static var sizeMaxGroupMemberCount: Int { 100 }
}

// MARK: - GroupMembers Wrapper

public extension LibSession.StateManager {
    func groupMember(groupSessionId: SessionId, sessionId: String) -> CGroupMember? {
        var cGroupId: [CChar] = groupSessionId.hexString.cArray.nullTerminated()
        var cSessionId: [CChar] = sessionId.cArray.nullTerminated()
        var result: CGroupMember = CGroupMember()
        
        guard state_get_group_member(state, &cGroupId, &result, &cSessionId, nil) else { return nil }
        
        return result
    }
    
    func groupMembers(groupSessionId: SessionId) -> [CGroupMember] {
        return ((try? LibSession.extractMembers(from: state, groupSessionId: groupSessionId)) ?? [])
    }
    
    func groupMemberOrConstruct(groupSessionId: SessionId, sessionId: String) throws -> CGroupMember {
        var cGroupId: [CChar] = groupSessionId.hexString.cArray.nullTerminated()
        var cSessionId: [CChar] = sessionId.cArray.nullTerminated()
        var result: CGroupMember = CGroupMember()
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        
        guard state_get_or_construct_group_member(state, &cGroupId, &result, &cSessionId, &error) else {
            /// It looks like there are some situations where this object might not get created correctly (and
            /// will throw due to the implicit unwrapping) as a result we put it in a guard and throw instead
            SNLog("[LibSession] Unable to getOrConstruct group conversation: \(LibSessionError(error))")
            throw LibSessionError.getOrConstructFailedUnexpectedly
        }
        
        return result
    }
}

// MARK: - Group Members Handling

internal extension LibSession {
    static let columnsRelatedToGroupMembers: [ColumnExpression] = [
        GroupMember.Columns.role,
        GroupMember.Columns.roleStatus
    ]
    
    // MARK: - Incoming Changes
    
    static func handleGroupMembersUpdate(
        _ db: Database,
        in state: UnsafeMutablePointer<state_object>,
        groupSessionId: SessionId,
        serverTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws {
        // Get the two member sets
        let allMembers: [CGroupMember] = try extractMembers(from: state, groupSessionId: groupSessionId)
        let updatedMembers: Set<GroupMember> = allMembers
            .filter { $0.removed == 0 } // Exclude members flagged for removal
            .map { GroupMember($0, groupSessionId: groupSessionId) }
            .asSet()
        let existingMembers: Set<GroupMember> = (try? GroupMember
            .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
            .fetchSet(db))
            .defaulting(to: [])
        let updatedStandardMemberIds: Set<String> = updatedMembers
            .filter { $0.role == .standard }
            .map { $0.profileId }
            .asSet()
        let updatedAdminMemberIds: Set<String> = updatedMembers
            .filter { $0.role == .admin }
            .map { $0.profileId }
            .asSet()

        // Add in any new members and remove any removed members
        try updatedMembers
            .subtracting(existingMembers)
            .forEach { try $0.upsert(db) }
        
        try GroupMember
            .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
            .filter(
                (
                    GroupMember.Columns.role == GroupMember.Role.standard &&
                    !updatedStandardMemberIds.contains(GroupMember.Columns.profileId)
                ) || (
                    GroupMember.Columns.role == GroupMember.Role.admin &&
                    !updatedAdminMemberIds.contains(GroupMember.Columns.profileId)
                )
            )
            .deleteAll(db)
        
        // Schedule a job to process the removals if there are any
        if !allMembers.filter({ $0.removed > 0 }).isEmpty {
            dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .processPendingGroupMemberRemovals,
                    threadId: groupSessionId.hexString,
                    details: ProcessPendingGroupMemberRemovalsJob.Details(
                        changeTimestampMs: serverTimestampMs
                    )
                ),
                canStartJob: true,
                using: dependencies
            )
        }
        
        // If there were members then also extract and update the profile information for the members
        // if we don't have newer data locally
        guard !updatedMembers.isEmpty else { return }
        
        allMembers
            .map { Profile($0, serverTimestampMs: serverTimestampMs) }
            .asSet()
            .forEach { profile in
                try? Profile.updateIfNeeded(
                    db,
                    publicKey: profile.id,
                    name: profile.name,
                    displayPictureUpdate: {
                        guard
                            let profilePictureUrl: String = profile.profilePictureUrl,
                            let profileKey: Data = profile.profileEncryptionKey
                        else { return .none }
                        
                        return .updateTo(
                            url: profilePictureUrl,
                            key: profileKey,
                            fileName: nil
                        )
                    }(),
                    sentTimestamp: TimeInterval(Double(serverTimestampMs) * 1000),
                    using: dependencies
                )
            }
    }
}

// MARK: - Outgoing Changes

internal extension LibSession {
    static func getMembers(
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) -> Set<GroupMember> {
        return dependencies[singleton: .libSession]
            .groupMembers(groupSessionId: groupSessionId)
            .filter { $0.removed == 0 } // Exclude members flagged for removal
            .map { GroupMember($0, groupSessionId: groupSessionId) }
            .asSet()
    }
    
    static func getPendingMemberRemovals(
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) -> [String: Bool] {
        return dependencies[singleton: .libSession]
            .groupMembers(groupSessionId: groupSessionId)
            .filter { $0.removed > 0 } // Exclude members not flagged for removal
            .reduce(into: [:]) { result, next in
                let memberId: String = String(cString: withUnsafeBytes(of: next.session_id) { [UInt8]($0) }
                    .map { CChar($0) }
                    .nullTerminated()
                )
                result[memberId] = (next.removed == 2)
            }
    }
    
    static func addMembers(
        groupSessionId: SessionId,
        members: [(id: String, profile: Profile?)],
        allowAccessToHistoricMessages: Bool,
        using dependencies: Dependencies
    ) throws {
        try dependencies[singleton: .libSession].mutate(groupId: groupSessionId) { state in
            try members.forEach { memberId, profile in
                var member: CGroupMember = try dependencies[singleton: .libSession].groupMemberOrConstruct(
                    groupSessionId: groupSessionId,
                    sessionId: memberId
                )
                
                var profilePic: user_profile_pic = user_profile_pic()
                
                if
                    let picUrl: String = profile?.profilePictureUrl,
                    let picKey: Data = profile?.profileEncryptionKey,
                    !picUrl.isEmpty,
                    picKey.count == DisplayPictureManager.aes256KeyByteLength
                {
                    profilePic.url = picUrl.toLibSession()
                    profilePic.key = picKey.toLibSession()
                }
                
                // Don't override the existing name with an empty one
                if let memberName: String = profile?.name, !memberName.isEmpty {
                    member.name = memberName.toLibSession()
                }
                member.profile_pic = profilePic
                member.invited = 1
                member.supplement = allowAccessToHistoricMessages
                state_set_group_member(state, &member)
            }
        }
    }
    
    static func updateMemberStatus(
        groupSessionId: SessionId,
        memberId: String,
        role: GroupMember.Role,
        status: GroupMember.RoleStatus,
        using dependencies: Dependencies
    ) {
        // If the member doesn't exist or the role status is already "accepted" then do nothing
        guard
            var member: CGroupMember = dependencies[singleton: .libSession]
                .groupMember(groupSessionId: groupSessionId, sessionId: memberId),
            (
                (role == .standard && member.invited != Int32(GroupMember.RoleStatus.accepted.rawValue)) ||
                (role == .admin && (
                    !member.admin ||
                    member.promoted != Int32(GroupMember.RoleStatus.accepted.rawValue)
                ))
            )
        else { return }
        
        switch role {
            case .standard: member.invited = Int32(status.rawValue)
            case .admin:
                member.admin = (status == .accepted)
                member.promoted = Int32(status.rawValue)
                
            default: break
        }
        
        dependencies[singleton: .libSession].mutate(groupId: groupSessionId) { state in
            state_set_group_member(state, &member)
        }
    }
    
    static func flagMembersForRemoval(
        groupSessionId: SessionId,
        memberIds: Set<String>,
        removeMessages: Bool,
        using dependencies: Dependencies
    ) {
        dependencies[singleton: .libSession].mutate(groupId: groupSessionId) { state in
            memberIds.forEach { memberId in
                guard
                    var member: CGroupMember = dependencies[singleton: .libSession]
                        .groupMember(groupSessionId: groupSessionId, sessionId: memberId)
                else { return }
                
                member.removed = (removeMessages ? 2 : 1)
                state_set_group_member(state, &member)
            }
        }
    }
    
    static func removeMembers(
        groupSessionId: SessionId,
        memberIds: Set<String>,
        using dependencies: Dependencies
    ) {
        dependencies[singleton: .libSession].mutate(groupId: groupSessionId) { state in
            memberIds.forEach { memberId in
                var cMemberId: [CChar] = memberId.cArray
                state_erase_group_member(state, &cMemberId)
            }
        }
    }
    
    static func updatingGroupMembers<T>(
        _ db: Database,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedMembers: [GroupMember] = updated as? [GroupMember] else { throw StorageError.generic }
        
        // Exclude legacy groups as they aren't managed via LibSession
        let targetMembers: [GroupMember] = updatedMembers
            .filter { (try? SessionId(from: $0.groupId))?.prefix == .group }
        
        // If we only updated the current user contact then no need to continue
        //
        // Note: We assume that changes only occur to one group at a time
        guard
            !targetMembers.isEmpty,
            let groupId: SessionId = targetMembers.first.map({ try? SessionId(from: $0.groupId) }),
            groupId.prefix == .group
        else { return updated }
        
        dependencies[singleton: .libSession].mutate(groupId: groupId) { state in
            // Loop through each of the groups and update their settings
            targetMembers.forEach { updatedMember in
                guard
                    var member: CGroupMember = dependencies[singleton: .libSession]
                        .groupMember(groupSessionId: groupId, sessionId: updatedMember.profileId)
                else { return }
                
                // Update the role and status to match
                switch updatedMember.role {
                    case .admin:
                        member.admin = true
                        member.invited = 0
                        member.promoted = updatedMember.roleStatus.libSessionValue
                        
                    default:
                        member.admin = false
                        member.invited = updatedMember.roleStatus.libSessionValue
                        member.promoted = 0
                }
                
                state_set_group_member(state, &member)
            }
        }
        
        return updated
    }
}

// MARK: - MemberData

private struct MemberData {
    let memberId: String
    let profile: Profile?
    let admin: Bool
    let invited: Int32
    let promoted: Int32
}

// MARK: - Convenience

internal extension LibSession {
    static func extractMembers(
        from state: UnsafeMutablePointer<state_object>,
        groupSessionId: SessionId
    ) throws -> [CGroupMember] {
        var infiniteLoopGuard: Int = 0
        var result: [CGroupMember] = []
        var member: CGroupMember = CGroupMember()
        var cGroupId: [CChar] = groupSessionId.hexString.cArray.nullTerminated()
        let membersIterator: UnsafeMutablePointer<groups_members_iterator> = groups_members_iterator_new(state, &cGroupId)
        
        while !groups_members_iterator_done(membersIterator, &member) {
            try LibSession.checkLoopLimitReached(&infiniteLoopGuard, for: .groupMembers)
            result.append(member)
            groups_members_iterator_advance(membersIterator)
        }
        groups_members_iterator_free(membersIterator) // Need to free the iterator
        
        return result
    }
}

private extension GroupMember {
    init(_ member: CGroupMember, groupSessionId: SessionId) {
        let memberId: String = String(cString: withUnsafeBytes(of: member.session_id) { [UInt8]($0) }
            .map { CChar($0) }
            .nullTerminated()
        )
        
        self = GroupMember(
            groupId: groupSessionId.hexString,
            profileId: memberId,
            role: (member.admin || (member.promoted > 0) ? .admin : .standard),
            roleStatus: {
                switch (member.invited, member.promoted, member.admin) {
                    case (2, _, _), (_, 2, false): return .failed           // Explicitly failed
                    case (1..., _, _), (_, 1..., false): return .pending    // Pending if not accepted
                    default: return .accepted                               // Otherwise it's accepted
                }
            }(),
            isHidden: false
        )
    }
}

private extension Profile {
    init(_ member: CGroupMember, serverTimestampMs: Int64) {
        let memberId: String = String(cString: withUnsafeBytes(of: member.session_id) { [UInt8]($0) }
            .map { CChar($0) }
            .nullTerminated()
        )
        let profilePictureUrl: String? = String(libSessionVal: member.profile_pic.url, nullIfEmpty: true)
        
        self = Profile(
            id: memberId,
            name: String(libSessionVal: member.name),
            lastNameUpdate: TimeInterval(Double(serverTimestampMs) / 1000),
            nickname: nil,
            profilePictureUrl: profilePictureUrl,
            profileEncryptionKey: (profilePictureUrl == nil ? nil :
                Data(
                    libSessionVal: member.profile_pic.key,
                    count: DisplayPictureManager.aes256KeyByteLength
                )
            ),
            lastProfilePictureUpdate: TimeInterval(Double(serverTimestampMs) / 1000),
            lastBlocksCommunityMessageRequests: nil
        )
    }
}
