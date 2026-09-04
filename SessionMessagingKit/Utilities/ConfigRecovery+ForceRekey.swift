// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("ConfigForceRekey", defaultLevel: .info)
}

// MARK: - ConfigRecovery.forceRekeyIfPossible

public extension ConfigRecovery {
    /// The shortest gap between rekeys of the same group
    ///
    /// A rekey is irreversible and every member sees it, so doing it too often is materially worse than doing it late. Several
    /// admins can reach the precondition in the same window - they poll the same swarm and see the same missing keys - and
    /// without a bound each of them rekeys on every poll
    private static var rekeyInterval: TimeInterval { 60 * 60 }

    /// Rekey the group so its members get usable keys again
    ///
    /// **The caller must already have established** that a backfill ran and left the bytes absent, and that detection says the
    /// swarm has lost them - i.e. *nobody has it and it is gone*. This checks only what is its own: that we are an admin, and
    /// that we have not just done this.
    ///
    /// **Admin-only, and a member must not appear to try.** A member cannot produce a keys message at all, so a member reaching
    /// the rekey would generate auth failures rather than a repair.
    ///
    /// ## What an unnecessary rekey costs
    ///
    /// Not exclusion by itself. `Keys::rekey` encrypts the new key for every member in the `Members` config it is handed, so a
    /// plain rekey locks nobody out - a dormant member who returns fetches the keys message and gets the key, and that message
    /// is still on the swarm because every other member's poll renews its TTL. The cost is that every member processes a new
    /// generation, and content encrypted under superseded keys may be unreadable to anyone who never held them.
    ///
    /// 🔴 **The exclusion risk is the members view, not the rekey.** The new key is encrypted to *this device's* view of the
    /// membership, and this fires precisely on devices whose config state is known to be degraded. A member added while we were
    /// away and not yet merged locally is silently excluded by a rekey issued from that stale view.
    ///
    /// - Parameter localStateIsLevelWithSwarmThisPoll: whether the calling poll established levelness **in that same cycle**.
    /// Passed in rather than read here because the signal exists only inside one `poll()` invocation - reading it internally
    /// would put the refusal wholly at the call site, where this entry point cannot assert it
    static func forceRekeyIfPossible(
        swarmPublicKey: String,
        localStateIsLevelWithSwarmThisPoll: Bool,
        using dependencies: Dependencies
    ) async {
        guard localStateIsLevelWithSwarmThisPoll else { return }

        guard let sessionId: SessionId = try? SessionId(from: swarmPublicKey), sessionId.prefix == .group else { return }

        guard await dependencies[singleton: .configForceRekey].beginRekey(
            swarmPublicKey: swarmPublicKey,
            now: dependencies.dateNow,
            interval: ConfigRecovery.rekeyInterval
        ) else { return }

        let isAdmin: Bool = dependencies.mutate(cache: .libSession) { cache in
            cache.isAdmin(groupSessionId: sessionId)
        }

        guard isAdmin else {
            Log.info(.cat, "Not rekeying \(swarmPublicKey) - this device is not an admin, so it cannot produce a keys message.")
            return
        }

        do {
            /// The existing rekey path rather than a new one - it performs the rekey and leaves the result for
            /// `ConfigurationSyncJob` to push, so this stays a trigger rather than a second implementation
            try await dependencies[singleton: .storage].write { db in
                try LibSession.rekey(db, groupSessionId: sessionId, using: dependencies)
            }
            Log.warn(.cat, "Rekeyed \(swarmPublicKey) - its keys messages were unrecoverable by any device that has polled it.")
        }
        catch {
            Log.error(.cat, "Failed to rekey \(swarmPublicKey) due to error: \(error).")
        }
    }
}

// MARK: - Singleton

public extension Singleton {
    static let configForceRekey: SingletonConfig<ConfigForceRekeyStoreType> = Dependencies.create(
        identifier: "configForceRekey",
        createInstance: { _, _ in ConfigRecovery.ForceRekeyStore() }
    )
}

public extension ConfigRecovery {
    actor ForceRekeyStore: ConfigForceRekeyStoreType {
        private var rekeyedUntil: [String: Date] = [:]

        public func beginRekey(swarmPublicKey: String, now: Date, interval: TimeInterval) -> Bool {
            if let until: Date = rekeyedUntil[swarmPublicKey], now < until { return false }

            /// Claimed before the rekey rather than after: a rekey that fails must still bound the next attempt, or a
            /// persistently failing group rekeys on every poll
            rekeyedUntil[swarmPublicKey] = now.addingTimeInterval(interval)
            rekeyedUntil = rekeyedUntil.filter { _, expiry in expiry > now }

            return true
        }
    }
}

// MARK: - ConfigForceRekeyStoreType

public protocol ConfigForceRekeyStoreType: Actor {
    /// Claim a rekey for this group, returning `false` if one was performed within `interval`
    func beginRekey(swarmPublicKey: String, now: Date, interval: TimeInterval) -> Bool
}
