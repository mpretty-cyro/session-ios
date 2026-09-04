// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("ConfigForceRekey", defaultLevel: .info)
}

// MARK: - ConfigForceRekey

/// **B2 — rekey a group whose keys nobody can restore.**
///
/// ## What an unnecessary rekey actually costs
///
/// **Not exclusion by itself.** `Keys::rekey` encrypts the new key for every member in the `Members` config it is handed, so
/// a plain rekey locks nobody out - a dormant member who returns fetches the keys message and gets the key, and that message
/// is still on the swarm because every other member's poll renews its TTL. The cost of a needless rekey is that every member
/// processes a new generation, and content encrypted under superseded keys may be unreadable to anyone who never held them.
///
/// 🔴 **The real exclusion risk is the members view, not the rekey.** The new key is encrypted to *this device's* view of the
/// membership, and B2 fires precisely on devices whose config state is known to be degraded. A member added while we were
/// away and not yet merged locally is silently excluded by a rekey issued from that stale view. That is why the caller must
/// establish levelness **as of the current poll** - not the session-sticky predicate, which still reads true when our last
/// complete poll was yesterday.
///
/// ⚠️ **This whole file is meant to be deletable.** It is the one part of config recovery that writes new state visible to
/// every member on every version, and it exists to be evaluated and possibly withdrawn. So:
///
/// - **one entry point**, called from exactly one place
/// - **the precondition is the caller's**, checked before the call rather than inside it, so the rule is readable at the call
///   site rather than buried here
/// - **no state shared with B1.** B1's attempt record lives on `ConfigRecovery.Store` because it is B1's output; the only
///   state owned here is the storm guard, so deleting this file deletes it
///
/// Removing B2 is: delete this file, delete its call site, delete nothing else.
public enum ConfigForceRekey {
    /// The shortest gap between rekeys of the same group
    ///
    /// A rekey is irreversible and every member sees it, so the failure mode of doing it too often is materially worse than
    /// the failure mode of doing it late. Several admins can reach the precondition in the same window - they are all polling
    /// the same swarm and seeing the same missing keys - and without a bound each of them rekeys on each poll
    private static let rekeyInterval: TimeInterval = (60 * 60)

    /// Rekey the group so its members get usable keys again
    ///
    /// **The caller must already have established** that a keys backfill ran and found nothing, that the bytes are still
    /// absent, and that detection says the swarm has lost them - i.e. *nobody has it and it is gone*. This checks only what is
    /// its own: that we are an admin, and that we have not just done this.
    ///
    /// **Admin-only, and a member must not appear to try.** A member cannot produce a keys message at all, so a member
    /// reaching here would generate auth failures rather than a repair
    /// - Parameter localStateIsLevelWithSwarmThisPoll: whether the poll that is calling this established levelness **in that
    /// same cycle**. The caller computes it; this refuses when it is `false`.
    ///
    /// It is a parameter rather than something read from here on purpose. The signal exists only inside one `poll()`
    /// invocation, so a version that read it internally could not be tested through this entry point at all - the refusal
    /// would live entirely at the call site, which is the half-a-rule-at-the-caller shape. Taking it as an argument keeps the
    /// caller responsible for computing it while making the refusal assertable here, and it still deletes with this file
    public static func rekeyIfPossible(
        swarmPublicKey: String,
        localStateIsLevelWithSwarmThisPoll: Bool,
        using dependencies: Dependencies
    ) async {
        /// A device that was not level with the swarm **as of this poll** holds a `GroupMembers` view that may be missing
        /// members added while it was away, and `rekey` encrypts the new key to exactly the view it is handed - so rekeying
        /// from a stale view silently excludes them
        guard localStateIsLevelWithSwarmThisPoll else { return }

        guard let sessionId: SessionId = try? SessionId(from: swarmPublicKey), sessionId.prefix == .group else { return }

        /// Bounded rather than unbounded: this is the storm guard, and it lives here because it is B2's problem
        guard await dependencies[singleton: .configForceRekey].beginRekey(
            swarmPublicKey: swarmPublicKey,
            now: dependencies.dateNow,
            interval: ConfigForceRekey.rekeyInterval
        ) else { return }

        let isAdmin: Bool = dependencies.mutate(cache: .libSession) { cache in
            cache.isAdmin(groupSessionId: sessionId)
        }

        guard isAdmin else {
            Log.info(.cat, "Not rekeying \(swarmPublicKey) - this device is not an admin, so it cannot produce a keys message.")
            return
        }

        do {
            /// The existing rekey path, not a new one - it performs the rekey and leaves the result for
            /// `ConfigurationSyncJob` to push, which is what keeps B2 a trigger rather than a second implementation
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
        createInstance: { _, _ in ConfigForceRekey.Store() }
    )
}

public extension ConfigForceRekey {
    /// The storm guard's state, and the only state this feature owns
    actor Store: ConfigForceRekeyStoreType {
        private var rekeyedUntil: [String: Date] = [:]

        public func beginRekey(swarmPublicKey: String, now: Date, interval: TimeInterval) -> Bool {
            if let until: Date = rekeyedUntil[swarmPublicKey], now < until { return false }

            /// Claimed before the rekey rather than after, for the same reason B1's bar is: a rekey that fails must still
            /// bound the next attempt, or a persistently failing group rekeys on every poll
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
