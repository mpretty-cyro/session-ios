// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import PromiseKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit

public final class BackgroundPoller {
    private static var promises: [Promise<Void>] = []
    public static var isValid: Bool = false

    public static func poll(completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        promises = []
            .appending(pollForMessages())
            .appending(contentsOf: pollForClosedGroupMessages())
            .appending(
                contentsOf: Storage.shared
                    .read { db in
                        // The default room promise creates an OpenGroup with an empty `roomToken` value,
                        // we don't want to start a poller for this as the user hasn't actually joined a room
                        try OpenGroup
                            .select(.server)
                            .filter(OpenGroup.Columns.roomToken != "")
                            .filter(OpenGroup.Columns.isActive)
                            .distinct()
                            .asRequest(of: String.self)
                            .fetchSet(db)
                    }
                    .defaulting(to: [])
                    .map { server in
                        let poller: OpenGroupAPI.Poller = OpenGroupAPI.Poller(for: server)
                        poller.stop()
                        
                        return poller.poll(
                            calledFromBackgroundPoller: true,
                            isBackgroundPollerValid: { BackgroundPoller.isValid },
                            isPostCapabilitiesRetry: false
                        )
                    }
            )
        
        when(resolved: promises)
            .done { _ in
                // If we have already invalidated the timer then do nothing (we essentially timed out)
                guard BackgroundPoller.isValid else { return }
                
                completionHandler(.newData)
            }
            .catch { error in
                // If we have already invalidated the timer then do nothing (we essentially timed out)
                guard BackgroundPoller.isValid else { return }
                
                SNLog("Background poll failed due to error: \(error)")
                completionHandler(.failed)
            }
    }
    
    private static func pollForMessages() -> Promise<Void> {
        let userPublicKey: String = getUserHexEncodedPublicKey()
        
        return SnodeAPI.getSwarm(for: userPublicKey)
            .then(on: DispatchQueue.main) { swarm -> Promise<Void> in
                guard let snode = swarm.randomElement() else { throw SnodeAPIError.generic }
                
                return CurrentUserPoller.poll(
                    namespaces: CurrentUserPoller.namespaces,
                    from: snode,
                    for: userPublicKey,
                    on: DispatchQueue.main,
                    calledFromBackgroundPoller: true,
                    isBackgroundPollValid: { BackgroundPoller.isValid }
                )
            }
    }
    
    private static func pollForClosedGroupMessages() -> [Promise<Void>] {
        // Fetch all closed groups (excluding any don't contain the current user as a
        // GroupMemeber as the user is no longer a member of those)
        return Storage.shared
            .read { db in
                try ClosedGroup
                    .select(.threadId)
                    .joining(
                        required: ClosedGroup.members
                            .filter(GroupMember.Columns.profileId == getUserHexEncodedPublicKey(db))
                    )
                    .asRequest(of: String.self)
                    .fetchAll(db)
            }
            .defaulting(to: [])
            .map { groupPublicKey in
                SnodeAPI.getSwarm(for: groupPublicKey)
                    .then(on: DispatchQueue.main) { swarm -> Promise<Void> in
                        guard let snode: Snode = swarm.randomElement() else {
                            return Promise(error: OnionRequestAPIError.insufficientSnodes)
                        }
                        
                        return ClosedGroupPoller.poll(
                            namespaces: ClosedGroupPoller.namespaces,
                            from: snode,
                            for: groupPublicKey,
                            on: DispatchQueue.main,
                            calledFromBackgroundPoller: true,
                            isBackgroundPollValid: { BackgroundPoller.isValid }
                        )
                    }
            }
    }
}
