// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

actor MainAppContext: AppContext {
    @MainActor private let dependencies: Dependencies
    let isMainApp: Bool = true
    var appLaunchTime: Date = Date()
    var reportedApplicationState: UIApplication.State
    var isMainAppAndActive: Bool { reportedApplicationState == .active }
    @MainActor var frontMostViewController: UIViewController? {
        UIApplication.shared.frontMostViewController(ignoringAlerts: true, using: dependencies)
    }
    @MainActor var backgroundTimeRemaining: TimeInterval { UIApplication.shared.backgroundTimeRemaining }
    
    public var mainWindow: UIWindow?
    
    @MainActor var statusBarHeight: CGFloat { UIApplication.shared.statusBarFrame.size.height }
    @MainActor var openSystemSettingsAction: UIAlertAction? {
        let result = UIAlertAction(
            title: "sessionSettings".localized(),
            style: .default
        ) { _ in UIApplication.shared.openSystemSettings() }
        result.accessibilityIdentifier = "\(type(of: self)).system_settings"
        
        return result
    }
    
    @MainActor static func determineDeviceRTL() -> Bool {
        return (UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft)
    }
    @MainActor private var observers: [NSObjectProtocol] = []
    
    // MARK: - Initialization

    @MainActor init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.reportedApplicationState = .inactive
        
        setupObservers()
    }
    
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    
    // MARK: - Functions
    
    @MainActor private func setupObservers() {
        self.observers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { await self?.setReportedApplicationState(.inactive) }
                NotificationCenter.default.post(name: .sessionWillEnterForeground, object: nil)
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { await self?.setReportedApplicationState(.background) }
                NotificationCenter.default.post(name: .sessionDidEnterBackground, object: nil)
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { await self?.setReportedApplicationState(.inactive) }
                NotificationCenter.default.post(name: .sessionWillResignActive, object: nil)
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { await self?.setReportedApplicationState(.active) }
                NotificationCenter.default.post(name: .sessionDidBecomeActive, object: nil)
            }
        ]
    }
    
    // MARK: - AppContext Functions
    
    func setMainWindow(_ mainWindow: UIWindow) {
        self.mainWindow = mainWindow
        
        // Store in SessionUIKit to avoid needing the SessionUtilitiesKit dependency
        SNUIKit.setMainWindow(mainWindow)
    }
    
    func setReportedApplicationState(_ state: UIApplication.State) async {
        self.reportedApplicationState = state
    }
    
    @MainActor func beginBackgroundTask(expirationHandler: @escaping @Sendable () -> ()) -> UIBackgroundTaskIdentifier {
        return UIApplication.shared.beginBackgroundTask(expirationHandler: expirationHandler)
    }
    
    @MainActor func endBackgroundTask(_ backgroundTaskIdentifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
    }
    
    // stringlint:ignore_contents
    @MainActor func ensureSleepBlocking(_ shouldBeBlocking: Bool, blockingObjects: [Any]) {
        if UIApplication.shared.isIdleTimerDisabled != shouldBeBlocking {
            if shouldBeBlocking {
                var logString: String = "Blocking sleep because of: \(String(describing: blockingObjects.first))"
                
                if blockingObjects.count > 1 {
                    logString = "\(logString) (and \(blockingObjects.count - 1) others)"
                }
                Log.info(logString)
            }
            else {
                Log.info("Unblocking Sleep.")
            }
        }
        UIApplication.shared.isIdleTimerDisabled = shouldBeBlocking
    }
}
