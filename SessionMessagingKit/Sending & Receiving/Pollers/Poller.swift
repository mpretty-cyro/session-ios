// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import PromiseKit
import SessionSnodeKit
import SessionUtilitiesKit

public class Poller {
    private var timers: Atomic<[String: Timer]> = Atomic([:])
    internal var isPolling: Atomic<[String: Bool]> = Atomic([:])
    internal var pollCount: Atomic<[String: Int]> = Atomic([:])
    internal var failureCount: Atomic<[String: Int]> = Atomic([:])

    // MARK: - Settings
    
    /// The namespaces which this poller queries
    internal var namespaces: [SnodeAPI.Namespace] {
        preconditionFailure("abstract class - override in subclass")
    }
    
    /// The number of times the poller can poll before swapping to a new snode
    internal var maxNodePollCount: UInt {
        preconditionFailure("abstract class - override in subclass")
    }
    
    // MARK: - Public API
    
    public init() {}
    
    public func stopAllPollers() {
        let pollers: [String] = Array(isPolling.wrappedValue.keys)
        
        pollers.forEach { groupPublicKey in
            self.stopPolling(for: groupPublicKey)
        }
    }
    
    public func stopPolling(for publicKey: String) {
        isPolling.mutate { $0[publicKey] = false }
        timers.mutate { $0[publicKey]?.invalidate() }
    }
    
    // MARK: - Abstract Methods
    
    /// The name for this poller to appear in the logs
    internal func pollerName(for publicKey: String) -> String {
        preconditionFailure("abstract class - override in subclass")
    }
    
    internal func nextPollDelay(for publicKey: String) -> TimeInterval {
        preconditionFailure("abstract class - override in subclass")
    }
    
    internal func getSnodeForPolling(
        for publicKey: String,
        on queue: DispatchQueue
    ) -> Promise<Snode> {
        preconditionFailure("abstract class - override in subclass")
    }
    
    internal func handlePollError(_ error: Error, for publicKey: String) {
        preconditionFailure("abstract class - override in subclass")
    }

    // MARK: - Private API
    
    internal func startIfNeeded(for publicKey: String) {
        guard isPolling.wrappedValue[publicKey] != true else { return }
        
        // Might be a race condition that the setUpPolling finishes too soon,
        // and the timer is not created, if we mark the group as is polling
        // after setUpPolling. So the poller may not work, thus misses messages
        isPolling.mutate { $0[publicKey] = true }
        setUpPolling(for: publicKey)
    }
    
    /// We want to initially trigger a poll against the target service node and then run the recursive polling,
    /// if an error is thrown during the poll then this should automatically restart the polling
    internal func setUpPolling(for publicKey: String) {
        guard isPolling.wrappedValue[publicKey] == true else { return }
        
        let namespaces: [SnodeAPI.Namespace] = self.namespaces
        
        Threading.pollerQueue.async { [weak self] in
            self?.getSnodeForPolling(for: publicKey, on: Threading.pollerQueue)
                .then(on: Threading.pollerQueue) { snode in
                    Poller.poll(
                        namespaces: namespaces,
                        from: snode,
                        for: publicKey,
                        on: Threading.pollerQueue,
                        poller: self
                    )
                }
                .done(on: Threading.pollerQueue) { _ in
                    self?.pollRecursively(for: publicKey)
                }
                .catch(on: Threading.pollerQueue) { error in
                    guard self?.isPolling.wrappedValue[publicKey] == true else { return }
                    
                    self?.handlePollError(error, for: publicKey)
                }
        }
    }
    
    private func pollRecursively(for publicKey: String) {
        guard isPolling.wrappedValue[publicKey] == true else { return }
        
        let namespaces: [SnodeAPI.Namespace] = self.namespaces
        let nextPollInterval: TimeInterval = nextPollDelay(for: publicKey)
        
        timers.mutate {
            $0[publicKey] = Timer.scheduledTimerOnMainThread(
                withTimeInterval: nextPollInterval,
                repeats: false
            ) { [weak self] timer in
                timer.invalidate()
                
                Threading.pollerQueue.async {
                    self?.getSnodeForPolling(for: publicKey, on: Threading.pollerQueue)
                        .then(on: Threading.pollerQueue) { snode in
                            Poller.poll(
                                namespaces: namespaces,
                                from: snode,
                                for: publicKey,
                                on: Threading.pollerQueue,
                                poller: self
                            )
                        }
                        .done(on: Threading.pollerQueue) { [weak self] _ in
                            let maxNodePollCount: UInt = (self?.maxNodePollCount ?? 0)
                            
                            // If we have polled this service node more than the
                            // maximum allowed then throw an error so the parent
                            // loop can restart the polling
                            if maxNodePollCount > 0 {
                                let pollCount: Int = (self?.pollCount.wrappedValue[publicKey] ?? 0)
                                self?.pollCount.mutate { $0[publicKey] = (pollCount + 1) }
                                
                                guard pollCount < maxNodePollCount else {
                                    let newSnodeNextPollInterval: TimeInterval = (self?.nextPollDelay(for: publicKey) ?? nextPollInterval)
                                    
                                    self?.timers.mutate {
                                        $0[publicKey] = Timer.scheduledTimerOnMainThread(
                                            withTimeInterval: newSnodeNextPollInterval,
                                            repeats: false
                                        ) { [weak self] timer in
                                            timer.invalidate()
                                            
                                            self?.pollCount.mutate { $0[publicKey] = 0 }
                                            self?.setUpPolling(for: publicKey)
                                        }
                                    }
                                    return
                                }
                            }
                            
                            // Otherwise just loop
                            self?.pollRecursively(for: publicKey)
                        }
                        .catch(on: Threading.pollerQueue) { [weak self] error in
                            self?.handlePollError(error, for: publicKey)
                        }
                }
            }
        }
    }
    
    public static func poll(
        namespaces: [SnodeAPI.Namespace],
        from snode: Snode,
        for publicKey: String,
        on queue: DispatchQueue,
        calledFromBackgroundPoller: Bool = false,
        isBackgroundPollValid: @escaping (() -> Bool) = { true },
        poller: Poller? = nil
    ) -> Promise<Void> {
        // If the polling has been cancelled then don't continue
        guard
            (calledFromBackgroundPoller && isBackgroundPollValid()) ||
            poller?.isPolling.wrappedValue[publicKey] == true
        else { return Promise.value(()) }
        
        let pollerName: String = (
            poller?.pollerName(for: publicKey) ??
            "poller with public key \(publicKey)"
        )
        
        // Fetch the messages
        return SnodeAPI.getMessages(in: namespaces, from: snode, associatedWith: publicKey)
            .then(on: queue) { namespacedResults -> Promise<Void> in
                guard
                    (calledFromBackgroundPoller && isBackgroundPollValid()) ||
                        poller?.isPolling.wrappedValue[publicKey] == true
                else { return Promise.value(()) }
                
                let allMessagesCount: Int = namespacedResults
                    .map { $0.value.data?.messages.count ?? 0 }
                    .reduce(0, +)
                
                // No need to do anything if there are no messages
                guard allMessagesCount > 0 else {
                    if !calledFromBackgroundPoller {
                        SNLog("Received no new messages in \(pollerName)")
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
                        SNLog("Received \(messageCount) new message\(messageCount == 1 ? "" : "s") in \(pollerName) (duplicates: \(allMessagesCount - messageCount))")
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
                        queue: queue,
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
