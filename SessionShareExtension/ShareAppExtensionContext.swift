// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import SessionMessagingKit

/// This is _NOT_ a singleton and will be instantiated each time that the SAE is used.
final class ShareAppExtensionContext: AppContext {
    private let dependencies: Dependencies
    var rootViewController: UIViewController
    var reportedApplicationState: UIApplication.State
    
    let appLaunchTime: Date = Date()
    let isShareExtension: Bool = true
    var frontMostViewController: UIViewController? { rootViewController.findFrontMostViewController(ignoringAlerts: true) }
    
    var mainWindow: UIWindow?
    
    var statusBarHeight: CGFloat { return 20 }
    var openSystemSettingsAction: UIAlertAction?
    
    static func determineDeviceRTL() -> Bool {
        // Borrowed from PureLayout's AppExtension compatible RTL support.
        // App Extensions may not access -[UIApplication sharedApplication]; fall back
        // to checking the bundle's preferred localization character direction
        return (
            Locale.characterDirection(
                forLanguage: (Bundle.main.preferredLocalizations.first ?? "")
            ) == Locale.LanguageDirection.rightToLeft
        )
    }
    
    @MainActor private var observers: [NSObjectProtocol] = []
    
    // MARK: - Initialization

    @MainActor init(rootViewController: UIViewController, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.rootViewController = rootViewController
        self.reportedApplicationState = .active
        
        setupObservers()
    }
    
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    
    // MARK: - Functions
    
    @MainActor private func setupObservers() {
        self.reportedApplicationState = .active
        
        self.observers = [
            NotificationCenter.default.addObserver(
                forName: .NSExtensionHostDidBecomeActive,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.reportedApplicationState = .active }
                NotificationCenter.default.post(name: .sessionDidBecomeActive, object: nil)
            },
            NotificationCenter.default.addObserver(
                forName: .NSExtensionHostWillResignActive,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.reportedApplicationState = .inactive }
                NotificationCenter.default.post(name: .sessionWillResignActive, object: nil)
            },
            NotificationCenter.default.addObserver(
                forName: .NSExtensionHostDidEnterBackground,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.reportedApplicationState = .background }
                NotificationCenter.default.post(name: .sessionDidEnterBackground, object: nil)
            },
            NotificationCenter.default.addObserver(
                forName: .NSExtensionHostWillEnterForeground,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.reportedApplicationState = .inactive }
                NotificationCenter.default.post(name: .sessionWillEnterForeground, object: nil)
            }
        ]
    }
}
