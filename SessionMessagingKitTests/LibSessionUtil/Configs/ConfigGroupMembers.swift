// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

extension LibSessionSpec {
    class ConfigGroupMembers {
        static func tests() {
            context("GROUP_MEMBERS") {
                // MARK: - generates config correctly
                
                it("generates config correctly") {
                    let seed: Data = Data(
                        hex: "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210"
                    )
                    
                    // FIXME: Would be good to move these into the libSession-util instead of using Sodium separately
                    let keyPair: KeyPair = Crypto().generate(.ed25519KeyPair(seed: seed))!
                    var edPK: [UInt8] = keyPair.publicKey
                    var edSK: [UInt8] = keyPair.secretKey
                    
                    expect(edPK.toHexString())
                        .to(equal("cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"))
                    expect(String(Data(edSK.prefix(32)).toHexString())).to(equal(seed.toHexString()))
                    
                    // Initialize a brand new, empty config because we have no dump data to deal with.
                    var error: [CChar] = [CChar](repeating: 0, count: 256)
                    var conf: UnsafeMutablePointer<config_object>? = nil
                    
                    expect(groups_members_init(&conf, &edPK, &edSK, nil, 0, &error)).to(equal(0))
                }
            }
        }
    }
}
