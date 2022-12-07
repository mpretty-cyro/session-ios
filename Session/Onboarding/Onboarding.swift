// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import GRDB
import Curve25519Kit
import SessionUtilitiesKit
import SessionMessagingKit

enum Onboarding {
    enum Flow {
        case register, recover, link
        
        func preregister(with seed: Data, ed25519KeyPair: Sign.KeyPair, x25519KeyPair: ECKeyPair) {
            let userDefaults = UserDefaults.standard
            let x25519PublicKey = x25519KeyPair.hexEncodedPublicKey
            
            Storage.shared.write { db in
                // Store the users identity seeds
                try Identity.store(
                    db,
                    seed: seed,
                    ed25519KeyPair: ed25519KeyPair,
                    x25519KeyPair: x25519KeyPair
                )
                
                // Create and approve a contact for the current user (so the 'Note to Self'
                // thread behaves correctly
                try Contact(id: x25519PublicKey)
                    .with(
                        isApproved: true,
                        didApproveMe: true
                    )
                    .save(db)
                
                // Create the 'Note to Self' thread (not visible by default)
                try SessionThread
                    .fetchOrCreate(db, id: x25519PublicKey, variant: .contact)
                    .save(db)
                
                // Create the initial shared util state (won't have been created on
                // launch due to lack of ed25519 key)
                SessionUtil.loadState(ed25519SecretKey: ed25519KeyPair.secretKey)
                
                // No need to show the seed again if the user is restoring or linking
                db[.hasViewedSeed] = (self == .recover || self == .link)
            }
            
            // Set hasSyncedInitialConfiguration to true so that when we hit the
            // home screen a configuration sync is triggered (yes, the logic is a
            // bit weird). This is needed so that if the user registers and
            // immediately links a device, there'll be a configuration in their swarm.
            userDefaults[.hasSyncedInitialConfiguration] = (self == .register)
            
            switch self {
                case .register, .recover:
                    // Set both lastDisplayNameUpdate and lastProfilePictureUpdate to the
                    // current date, so that we don't overwrite what the user set in the
                    // display name step with whatever we find in their swarm.
                    userDefaults[.lastDisplayNameUpdate] = Date()
                    userDefaults[.lastProfilePictureUpdate] = Date()
                    
                case .link: break
            }
        }
    }
}
