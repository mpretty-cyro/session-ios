// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SignalCoreKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalCoreKit

public enum SyncPushTokensJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    private static let maxFrequency: TimeInterval = (12 * 60 * 60)
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> (),
        failure: @escaping (Job, Error?, Bool) -> (),
        deferred: @escaping (Job) -> ()
    ) {
        // Don't run when inactive or not in main app or if the user doesn't exist yet
        guard
            (UserDefaults.sharedLokiProject?[.isMainAppActive]).defaulting(to: false),
            Identity.userExists(),
            // If we have no display name then the user will be asked to enter one (this
            // can happen if the app crashed during onboarding which would leave the user
            // in an invalid state with no display name - the user is likely going to be
            // taken to the PN registration screen next which will re-trigger this job)
            !Profile.fetchOrCreateCurrentUser().name.isEmpty
        else {
            deferred(job) // Don't need to do anything if it's not the main app
            return
        }
        
        // We need to check a UIApplication setting which needs to run on the main thread so if we aren't on
        // the main thread then swap to it
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                run(job, queue: queue, success: success, failure: failure, deferred: deferred)
            }
            return
        }
        
        // Push tokens don't normally change while the app is launched, so you would assume checking once
        // during launch is sufficient, but e.g. on iOS11, users who have disabled "Allow Notifications"
        // and disabled "Background App Refresh" will not be able to obtain an APN token. Enabling those
        // settings does not restart the app, so we check every activation for users who haven't yet
        // registered.
        //
        // It's also possible for a device to successfully register for push notifications but fail to
        // register with Session
        //
        // Due to the above we want to re-register at least once every ~12 hours to ensure users will
        // continue to receive push notifications
        //
        // In addition to this if we are custom running the job (eg. by toggling the push notification
        // setting) then we should run regardless of the other settings so users have a mechanism to force
        // the registration to run
        let lastPushNotificationSync: Date = UserDefaults.standard[.lastPushNotificationSync]
            .defaulting(to: Date.distantPast)
        
        guard
            job.behaviour == .runOnce ||
            !UIApplication.shared.isRegisteredForRemoteNotifications ||
            Date().timeIntervalSince(lastPushNotificationSync) >= SyncPushTokensJob.maxFrequency
        else {
            deferred(job) // Don't need to do anything if push notifications are already registered
            return
        }
        
        Logger.info("Re-registering for remote notifications.")
        
        // Perform device registration
        PushRegistrationManager.shared.requestPushTokens()
            .subscribe(on: queue)
            .flatMap { (pushToken: String, voipToken: String) -> AnyPublisher<Void, Error> in
                Deferred {
                    Future<Void, Error> { resolver in
                        SyncPushTokensJob.registerForPushNotifications(
                            pushToken: pushToken,
                            voipToken: voipToken,
                            isForcedUpdate: true,
                            success: { resolver(Result.success(())) },
                            failure: { resolver(Result.failure($0)) }
                        )
                    }
                }
                .handleEvents(
                    receiveCompletion: { result in
                        switch result {
                            case .failure: break
                            case .finished:
                                Logger.warn("Recording push tokens locally. pushToken: \(redact(pushToken)), voipToken: \(redact(voipToken))")

                                Storage.shared.write { db in
                                    db[.lastRecordedPushToken] = pushToken
                                    db[.lastRecordedVoipToken] = voipToken
                                }
                        }
                    }
                )
                .eraseToAnyPublisher()
            }
            .sinkUntilComplete(
                // We want to complete this job regardless of success or failure
                receiveCompletion: { _ in success(job, false) },
                receiveValue: { _ in }
            )
    }
    
    public static func run(uploadOnlyIfStale: Bool) {
        guard let job: Job = Job(
            variant: .syncPushTokens,
            behaviour: .runOnce,
            details: SyncPushTokensJob.Details(
                uploadOnlyIfStale: uploadOnlyIfStale
            )
        )
        else { return }
                                 
        SyncPushTokensJob.run(
            job,
            queue: DispatchQueue.global(qos: .default),
            success: { _, _ in },
            failure: { _, _, _ in },
            deferred: { _ in }
        )
    }
}

// MARK: - SyncPushTokensJob.Details

extension SyncPushTokensJob {
    public struct Details: Codable {
        public let uploadOnlyIfStale: Bool
    }
}

// MARK: - Convenience

private func redact(_ string: String) -> String {
    return OWSIsDebugBuild() ? string : "[ READACTED \(string.prefix(2))...\(string.suffix(2)) ]"
}

extension SyncPushTokensJob {
    fileprivate static func registerForPushNotifications(
        pushToken: String,
        voipToken: String,
        isForcedUpdate: Bool,
        success: @escaping () -> (),
        failure: @escaping (Error) -> (),
        remainingRetries: Int = 3
    ) {
        let isUsingFullAPNs: Bool = UserDefaults.standard[.isUsingFullAPNs]
        
        Just(Data(hex: pushToken))
            .setFailureType(to: Error.self)
            .flatMap { pushTokenAsData -> AnyPublisher<Bool, Error> in
                guard isUsingFullAPNs else {
                    return PushNotificationAPI.unregister(pushTokenAsData)
                        .map { _ in true }
                        .eraseToAnyPublisher()
                }
                
                return PushNotificationAPI
                    .register(
                        with: pushTokenAsData,
                        publicKey: getUserHexEncodedPublicKey(),
                        isForcedUpdate: isForcedUpdate
                    )
                    .map { _ in true }
                    .eraseToAnyPublisher()
            }
            .catch { error -> AnyPublisher<Bool, Error> in
                guard remainingRetries == 0 else {
                    SyncPushTokensJob.registerForPushNotifications(
                        pushToken: pushToken,
                        voipToken: voipToken,
                        isForcedUpdate: isForcedUpdate,
                        success: success,
                        failure: failure,
                        remainingRetries: (remainingRetries - 1)
                    )
                    
                    return Just(false)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                return Fail(error: error)
                    .eraseToAnyPublisher()
            }
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error): failure(error)
                    }
                },
                receiveValue: { didComplete in
                    guard didComplete else { return }
                    
                    success()
                }
            )
    }
}
