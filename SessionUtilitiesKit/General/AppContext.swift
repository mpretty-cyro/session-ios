// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit

// MARK: - Singleton

public extension Singleton {
    static let appContext: SingletonConfig<AppContext> = Dependencies.create(
        identifier: "appContext",
        createInstance: { _ in NoopAppContext() }
    )
}

// MARK: - AppContext

public protocol AppContext: AnyObject {
    var isValid: Bool { get }
    var appLaunchTime: Date { get async }
    var isMainApp: Bool { get async }
    var isShareExtension: Bool { get async }
    var mainWindow: UIWindow? { get async }
    var isMainAppAndActive: Bool { get async }
    var reportedApplicationState: UIApplication.State { get async }
    @MainActor var frontMostViewController: UIViewController? { get }
    @MainActor var backgroundTimeRemaining: TimeInterval { get }
    
    func setMainWindow(_ mainWindow: UIWindow) async
    func setReportedApplicationState(_ state: UIApplication.State) async
    @MainActor func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any])
    @MainActor func beginBackgroundTask(expirationHandler: @escaping @Sendable () -> ()) -> UIBackgroundTaskIdentifier
    @MainActor func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier)
}

// MARK: - Defaults

public extension AppContext {
    var isValid: Bool { true }
    var isMainApp: Bool { false }
    var isMainAppAndActive: Bool { false }
    var isShareExtension: Bool { false }
    var mainWindow: UIWindow? { nil }
    var frontMostViewController: UIViewController? { nil }
    var backgroundTimeRemaining: TimeInterval { 0 }
    
    // Note: CallKit will make the app state as .inactive
    var isInBackground: Bool { get async { await reportedApplicationState == .background } }
    var isNotInForeground: Bool { get async { await reportedApplicationState != .active } }
    var isAppForegroundAndActive: Bool { get async { await reportedApplicationState == .active } }
    
    // MARK: - Functions
    
    func setMainWindow(_ mainWindow: UIWindow) {}
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any]) {}
    func beginBackgroundTask(expirationHandler: @escaping () -> ()) -> UIBackgroundTaskIdentifier { return .invalid }
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier) {}
}

private final class NoopAppContext: AppContext {
    let mainWindow: UIWindow? = nil
    let frontMostViewController: UIViewController? = nil
    
    var isValid: Bool { false }
    var appLaunchTime: Date { Date(timeIntervalSince1970: 0) }
    var isMainApp: Bool { false }
    var isMainAppAndActive: Bool { false }
    var isShareExtension: Bool { false }
    var reportedApplicationState: UIApplication.State { .inactive }
    var backgroundTimeRemaining: TimeInterval { 0 }
    
    // Override the extension functions
    var isInBackground: Bool { false }
    var isAppForegroundAndActive: Bool { false }
    
    func setMainWindow(_ mainWindow: UIWindow) {}
    func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any]) {}
    func beginBackgroundTask(expirationHandler: @escaping () -> ()) -> UIBackgroundTaskIdentifier { return .invalid }
    func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier) {}
}
