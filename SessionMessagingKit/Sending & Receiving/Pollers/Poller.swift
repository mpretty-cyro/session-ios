// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import PromiseKit
import Sodium
import SessionSnodeKit
import SessionUtilitiesKit

public final class Poller {
    private var isPolling: Atomic<Bool> = Atomic(false)
    private var usedSnodes = Set<Snode>()
    private var pollCount = 0

    // MARK: - Settings
    
    private static let pollInterval: TimeInterval = 1.5
    private static let retryInterval: TimeInterval = 0.25
    private static let maxRetryInterval: TimeInterval = 15
    
    /// After polling a given snode this many times we always switch to a new one.
    ///
    /// The reason for doing this is that sometimes a snode will be giving us successful responses while
    /// it isn't actually getting messages from other snodes.
    private static let maxPollCount: UInt = 6

    // MARK: - Error
    
    private enum Error: LocalizedError {
        case pollLimitReached

        var localizedDescription: String {
            switch self {
                case .pollLimitReached: return "Poll limit reached for current snode."
            }
        }
    }

    // MARK: - Public API
    
    public init() {}
    
    public func startIfNeeded() {
        guard !isPolling.wrappedValue else { return }
        
        SNLog("Started polling.")
        isPolling.mutate { $0 = true }
        setUpPolling()
    }

    public func stop() {
        SNLog("Stopped polling.")
        isPolling.mutate { $0 = false }
        usedSnodes.removeAll()
    }

    // MARK: - Private API
    
    private func setUpPolling(delay: TimeInterval = Poller.retryInterval) {
        guard isPolling.wrappedValue else { return }
        
        Threading.pollerQueue.async {
            let _ = SnodeAPI.getSwarm(for: getUserHexEncodedPublicKey())
                .then(on: Threading.pollerQueue) { [weak self] _ -> Promise<Void> in
                    let (promise, seal) = Promise<Void>.pending()
                    
                    self?.usedSnodes.removeAll()
                    self?.pollNextSnode(seal: seal)
                    
                    return promise
                }
                .done(on: Threading.pollerQueue) { [weak self] in
                    guard self?.isPolling.wrappedValue == true else { return }
                    
                    Timer.scheduledTimerOnMainThread(withTimeInterval: Poller.retryInterval, repeats: false) { _ in
                        self?.setUpPolling()
                    }
                }
                .catch(on: Threading.pollerQueue) { [weak self] _ in
                    guard self?.isPolling.wrappedValue == true else { return }
                    
                    let nextDelay: TimeInterval = min(Poller.maxRetryInterval, (delay * 1.2))
                    Timer.scheduledTimerOnMainThread(withTimeInterval: nextDelay, repeats: false) { _ in
                        self?.setUpPolling()
                    }
                }
        }
    }

    private func pollNextSnode(seal: Resolver<Void>) {
        let userPublicKey = getUserHexEncodedPublicKey()
        let swarm = SnodeAPI.swarmCache.wrappedValue[userPublicKey] ?? []
        let unusedSnodes = swarm.subtracting(usedSnodes)
        
        guard !unusedSnodes.isEmpty else {
            seal.fulfill(())
            return
        }
        
        // randomElement() uses the system's default random generator, which is cryptographically secure
        let nextSnode = unusedSnodes.randomElement()!
        usedSnodes.insert(nextSnode)
        
        Poller.pollRecursively(nextSnode, poller: self)
            .done2 {
                seal.fulfill(())
            }
            .catch2 { [weak self] error in
                if let error = error as? Error, error == .pollLimitReached {
                    self?.pollCount = 0
                }
                else if UserDefaults.sharedLokiProject?[.isMainAppActive] != true {
                    // Do nothing when an error gets throws right after returning from the background (happens frequently)
                }
                else {
                    SNLog("Polling \(nextSnode) failed; dropping it and switching to next snode.")
                    SnodeAPI.dropSnodeFromSwarmIfNeeded(nextSnode, publicKey: userPublicKey)
                }
                
                Threading.pollerQueue.async {
                    self?.pollNextSnode(seal: seal)
                }
            }
    }
    
    private static func pollRecursively(_ snode: Snode, poller: Poller? = nil) -> Promise<Void> {
        guard poller?.isPolling.wrappedValue == true else { return Promise { $0.fulfill(()) } }
        
        return Poller.poll(snode, poller: poller)
            .then(on: Threading.pollerQueue) { _ in
                poller?.pollCount += 1
                
                guard (poller?.pollCount ?? 0) < Poller.maxPollCount else {
                    throw Error.pollLimitReached
                }
                
                return withDelay(Poller.pollInterval, completionQueue: Threading.pollerQueue) {
                    guard poller?.isPolling.wrappedValue == true else {
                        return Promise { $0.fulfill(()) }
                    }

                    return Poller.pollRecursively(snode, poller: poller)
                }
            }
    }

    public static func poll(
        _ snode: Snode,
        on queue: DispatchQueue? = nil,
        calledFromBackgroundPoller: Bool = false,
        isBackgroundPollValid: @escaping (() -> Bool) = { true },
        poller: Poller? = nil
    ) -> Promise<Void> {
        guard poller?.isPolling.wrappedValue == true else { return Promise { $0.fulfill(()) } }
        
        let userPublicKey: String = getUserHexEncodedPublicKey()
        
        return SnodeAPI.getMessages(from: snode, associatedWith: userPublicKey)
            .then(on: (queue ?? Threading.pollerQueue)) { namespacedResults -> Promise<Void> in
                guard
                    (calledFromBackgroundPoller && isBackgroundPollValid()) ||
                    poller?.isPolling.wrappedValue == true
                else { return Promise.value(()) }
                
                let allMessagesCount: Int = namespacedResults
                    .map { $0.value.data?.messages.count ?? 0 }
                    .reduce(0, +)
                
                // No need to do anything if there are no messages
                guard allMessagesCount > 0 else {
                    if !calledFromBackgroundPoller {
                        SNLog("Received no new messages")
                    }
                    return Promise.value(())
                }
                
                // Otherwise process the messages and add them to the queue for handling
                let lastHashes: [String] = namespacedResults
                    .compactMap { $0.value.data?.lastHash }
                var messageCount: Int = 0
                var hadValidHashUpdate: Bool = false
                var jobsToRun: [Job] = []
                
                Storage.shared.write { db in
                    namespacedResults.forEach { namespace, result in
                        result.data?.messages
                            .compactMap { message -> ProcessedMessage? in
                                do {
                                    return try Message.processRawReceivedMessage(db, rawMessage: message)
                                }
                                catch {
                                    switch error {
                                            // Ignore duplicate & selfSend message errors (and don't bother logging
                                            // them as there will be a lot since we each service node duplicates messages)
                                        case DatabaseError.SQLITE_CONSTRAINT_UNIQUE,
                                            MessageReceiverError.duplicateMessage,
                                            MessageReceiverError.duplicateControlMessage,
                                            MessageReceiverError.selfSend:
                                            break
                                            
                                        case MessageReceiverError.duplicateMessageNewSnode:
                                            hadValidHashUpdate = true
                                            break
                                            
                                        case DatabaseError.SQLITE_ABORT:
                                            // In the background ignore 'SQLITE_ABORT' (it generally means
                                            // the BackgroundPoller has timed out
                                            if !calledFromBackgroundPoller {
                                                SNLog("Failed to the database being suspended (running in background with no background task).")
                                            }
                                            break
                                            
                                        default: SNLog("Failed to deserialize envelope due to error: \(error).")
                                    }
                                    
                                    return nil
                                }
                            }
                            .grouped { threadId, _, _ in (threadId ?? Message.nonThreadMessageId) }
                            .forEach { threadId, threadMessages in
                                messageCount += threadMessages.count
                                
                                let jobToRun: Job? = Job(
                                    variant: .messageReceive,
                                    behaviour: .runOnce,
                                    threadId: threadId,
                                    details: MessageReceiveJob.Details(
                                        messages: threadMessages.map { $0.messageInfo },
                                        calledFromBackgroundPoller: calledFromBackgroundPoller
                                    )
                                )
                                jobsToRun = jobsToRun.appending(jobToRun)
                                
                                // If we are force-polling then add to the JobRunner so they are
                                // persistent and will retry on the next app run if they fail but
                                // don't let them auto-start
                                JobRunner.add(db, job: jobToRun, canStartJob: !calledFromBackgroundPoller)
                            }
                    }
                    
                    // Clean up message hashes and add some logs about the poll results
                    if allMessagesCount == 0 && !hadValidHashUpdate {
                        if !calledFromBackgroundPoller {
                            SNLog("Received \(allMessagesCount) new message\(allMessagesCount == 1 ? "" : "s"), all duplicates - marking the hash we polled with as invalid")
                        }
                        
                        // Update the cached validity of the messages
                        try SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                            db,
                            potentiallyInvalidHashes: lastHashes,
                            otherKnownValidHashes: namespacedResults
                                .compactMap { $0.value.data?.messages.map { $0.info.hash } }
                                .reduce([], +)
                        )
                    }
                    else if !calledFromBackgroundPoller {
                        SNLog("Received \(messageCount) new message\(messageCount == 1 ? "" : "s") (duplicates: \(allMessagesCount - messageCount))")
                    }
                }
                
                // If we aren't runing in a background poller then just finish immediately
                guard calledFromBackgroundPoller else { return Promise.value(()) }
                
                // We want to try to handle the receive jobs immediately in the background
                let promises: [Promise<Void>] = jobsToRun.map { job -> Promise<Void> in
                    let (promise, seal) = Promise<Void>.pending()
                    
                    // Note: In the background we just want jobs to fail silently
                    MessageReceiveJob.run(
                        job,
                        queue: (queue ?? Threading.pollerQueue),
                        success: { _, _ in seal.fulfill(()) },
                        failure: { _, _, _ in seal.fulfill(()) },
                        deferred: { _ in seal.fulfill(()) }
                    )

                    return promise
                }
                
                return when(fulfilled: promises)
            }
    }
}
