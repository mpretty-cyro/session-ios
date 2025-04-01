// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit

// MARK: - Cache

public extension Cache {
    static let appVersion: CacheConfig<AppVersionCacheType, AppVersionImmutableCacheType> = Dependencies.create(
        identifier: "appVersion",
        createInstance: { dependencies in AppVersion(using: dependencies) },
        mutableInstance: { $0 },
        erasedInstance: { $0 },
        immutableInstance: { $0.immutable }
    )
}

// MARK: - AppVersion

public actor AppVersion: AppVersionCacheType {
    public struct Immutable: AppVersionImmutableCacheType {
        public let isValid: Bool
        public let appVersion: String
        public let buildNumber: String
        public let commitHash: String
        public let libSessionVersion: String
        public let firstAppVersion: String?
        public let lastAppVersion: String?
        public let lastCompletedLaunchAppVersion: String?
        public let lastCompletedLaunchMainAppVersion: String?
        public let lastCompletedLaunchSAEAppVersion: String?
        public let isFirstLaunch: Bool
        public let didJustUpdate: Bool
        
        @MainActor public var versionInfo: String {
            return [
                "iOS \(UIDevice.current.systemVersion)",
                [
                    "App: \(appVersion)",
                    [buildNumber.nullIfEmpty, commitHash.nullIfEmpty]
                        .compactMap { $0 }
                        .joined(separator: " - ")
                        .nullIfEmpty
                        .map { "(\($0))" }
                ].compactMap { $0 }.joined(separator: " "),
                "libSession: \(LibSession.version)"
            ].joined(separator: ", ")
        }
        
        public func with(
            isValid: Bool? = nil,
            appVersion: String? = nil,
            buildNumber: String? = nil,
            commitHash: String? = nil,
            libSessionVersion: String? = nil,
            firstAppVersion: String? = nil,
            lastAppVersion: String? = nil,
            lastCompletedLaunchAppVersion: String? = nil,
            lastCompletedLaunchMainAppVersion: String? = nil,
            lastCompletedLaunchSAEAppVersion: String? = nil,
            isFirstLaunch: Bool? = nil,
            didJustUpdate: Bool? = nil
        ) -> Immutable {
            return Immutable(
                isValid: (isValid ?? self.isValid),
                appVersion: (appVersion ?? self.appVersion),
                buildNumber: (buildNumber ?? self.buildNumber),
                commitHash: (commitHash ?? self.commitHash),
                libSessionVersion: (libSessionVersion ?? self.libSessionVersion),
                firstAppVersion: (firstAppVersion ?? self.firstAppVersion),
                lastAppVersion: (lastAppVersion ?? self.lastAppVersion),
                lastCompletedLaunchAppVersion: (lastCompletedLaunchAppVersion ?? self.lastCompletedLaunchAppVersion),
                lastCompletedLaunchMainAppVersion: (lastCompletedLaunchMainAppVersion ?? self.lastCompletedLaunchMainAppVersion),
                lastCompletedLaunchSAEAppVersion: (lastCompletedLaunchSAEAppVersion ?? self.lastCompletedLaunchSAEAppVersion),
                isFirstLaunch: (isFirstLaunch ?? self.isFirstLaunch),
                didJustUpdate: (didJustUpdate ?? self.didJustUpdate)
            )
        }
    }
    
    private let dependencies: Dependencies
    @MainActor fileprivate var immutable: Immutable
    @MainActor public var isValid: Bool { immutable.isValid }
    @MainActor public var appVersion: String { immutable.appVersion }
    @MainActor public var buildNumber: String { immutable.buildNumber }
    @MainActor public var commitHash: String { immutable.commitHash }
    @MainActor public var libSessionVersion: String { immutable.libSessionVersion }
    
    @MainActor public var firstAppVersion: String? { immutable.firstAppVersion }
    @MainActor public var lastAppVersion: String? { immutable.lastAppVersion }
    @MainActor public var lastCompletedLaunchAppVersion: String? { immutable.lastCompletedLaunchAppVersion }
    @MainActor public var lastCompletedLaunchMainAppVersion: String? { immutable.lastCompletedLaunchMainAppVersion }
    @MainActor public var lastCompletedLaunchSAEAppVersion: String? { immutable.lastCompletedLaunchSAEAppVersion }
    
    @MainActor public var isFirstLaunch: Bool { immutable.isFirstLaunch }
    @MainActor public var didJustUpdate: Bool { immutable.didJustUpdate  }
    @MainActor public var versionInfo: String { immutable.versionInfo }
    
    // MARK: - Initialization
    
    fileprivate init(using dependencies: Dependencies) {
        let appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let oldFirstAppVersion: String? = dependencies[defaults: .appGroup, key: .firstAppVersion]
        let lastAppVersion: String? = dependencies[defaults: .appGroup, key: .lastAppVersion]
        
        self.dependencies = dependencies
        self.immutable = Immutable(
            isValid: (appVersion != nil),
            appVersion: (appVersion ?? ""),
            buildNumber: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).defaulting(to: ""),
            commitHash: (Bundle.main.infoDictionary?["GitCommitHash"] as? String).defaulting(to: ""),
            libSessionVersion: LibSession.version,
            firstAppVersion: (oldFirstAppVersion ?? (appVersion ?? "")),
            lastAppVersion: lastAppVersion,
            lastCompletedLaunchAppVersion: dependencies[defaults: .appGroup, key: .lastCompletedLaunchAppVersion],
            lastCompletedLaunchMainAppVersion: dependencies[defaults: .appGroup, key: .lastCompletedLaunchMainAppVersion],
            lastCompletedLaunchSAEAppVersion: dependencies[defaults: .appGroup, key: .lastCompletedLaunchSAEAppVersion],
            isFirstLaunch: (oldFirstAppVersion == nil),
            didJustUpdate: (lastAppVersion?.isEmpty == false && lastAppVersion != appVersion)
        )

        // Ensure the value for the "first launched version".
        if oldFirstAppVersion == nil {
            dependencies[defaults: .appGroup, key: .firstAppVersion] = appVersion
        }

        // Update the value for the "most recently launched version".
        dependencies[defaults: .appGroup, key: .lastAppVersion] = appVersion
    }
    
    // MARK: - Functions
    
    private func anyLaunchDidComplete() async {
        await MainActor.run { [dependencies] in
            immutable = immutable.with(lastCompletedLaunchAppVersion: immutable.appVersion)
            
            // Update the value for the "most recently launch-completed version".
            dependencies[defaults: .appGroup, key: .lastCompletedLaunchAppVersion] = immutable.appVersion
        }
    }

    public func mainAppLaunchDidComplete() async {
        await MainActor.run { [dependencies] in
            immutable = immutable.with(lastCompletedLaunchMainAppVersion: immutable.appVersion)
            
            dependencies[defaults: .appGroup, key: .lastCompletedLaunchMainAppVersion] = appVersion
        }
        await anyLaunchDidComplete()
    }

    public func saeLaunchDidComplete() async {
        await MainActor.run { [dependencies] in
            immutable = immutable.with(lastCompletedLaunchSAEAppVersion: immutable.appVersion)
            
            dependencies[defaults: .appGroup, key: .lastCompletedLaunchSAEAppVersion] = appVersion
        }
        await anyLaunchDidComplete()
    }
}

// MARK: - AppVersionCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol AppVersionImmutableCacheType: ImmutableCacheType {
    /// Flag indicating whether the version information is valid
    var isValid: Bool { get }
    
    /// The current app version
    var appVersion: String { get }
    
    /// The current build number
    var buildNumber: String { get }
    
    /// The commit hash for the current build
    var commitHash: String { get }
    
    /// The current `libSession` version
    var libSessionVersion: String { get }
    
    /// The version of the app when it was first launched (`nil` if the app has never been launched before)
    var firstAppVersion: String? { get }
    
    /// The version of the app the last time it was launched (`nil` if the app has never been launched before)
    var lastAppVersion: String? { get }
    
    /// The last app version where is successfully launched the main app
    var lastCompletedLaunchAppVersion: String? { get }
    
    /// The last app version where is successfully launched the main app
    var lastCompletedLaunchMainAppVersion: String? { get }
    
    /// The last app version where is successfully launched the main app
    var lastCompletedLaunchSAEAppVersion: String? { get }
    
    /// Flag indicating whether this is the first app launch
    var isFirstLaunch: Bool { get }
    
    /// Flag indicating whether the app was just updated
    var didJustUpdate: Bool { get }
    
    /// The full version information for the current version
    @MainActor var versionInfo: String { get }
}

public protocol AppVersionCacheType: MutableCacheType {
    /// Function to call when the main app successfully completed a launch
    func mainAppLaunchDidComplete() async
    
    /// Function to call when the share extension successfully completed a launch
    func saeLaunchDidComplete() async
    
    // MARK: - AppVersionImmutableCacheType Access
    
    var isValid: Bool { get async }
    var appVersion: String { get async }
    var buildNumber: String { get async }
    var commitHash: String { get async }
    var libSessionVersion: String { get async }
    var firstAppVersion: String? { get async }
    var lastAppVersion: String? { get async }
    var lastCompletedLaunchAppVersion: String? { get async }
    var lastCompletedLaunchMainAppVersion: String? { get async }
    var lastCompletedLaunchSAEAppVersion: String? { get async }
    var isFirstLaunch: Bool { get async }
    var didJustUpdate: Bool { get async }
    @MainActor var versionInfo: String { get async }
}

// MARK: - UserDefaults Keys

private extension UserDefaults.StringKey {
    /// The version of the app when it was first launched
    static let firstAppVersion: UserDefaults.StringKey = "kNSUserDefaults_FirstAppVersion"
    
    /// The version of the app when it was last launched
    static let lastAppVersion: UserDefaults.StringKey = "kNSUserDefaults_LastVersion"
    
    static let lastCompletedLaunchAppVersion: UserDefaults.StringKey = "kNSUserDefaults_LastCompletedLaunchAppVersion"
    static let lastCompletedLaunchMainAppVersion: UserDefaults.StringKey = "kNSUserDefaults_LastCompletedLaunchAppVersion_MainApp"
    static let lastCompletedLaunchSAEAppVersion: UserDefaults.StringKey = "kNSUserDefaults_LastCompletedLaunchAppVersion_SAE"
}
