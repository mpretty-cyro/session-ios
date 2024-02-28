// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class LibSessionUtilSpec: QuickSpec {
    static let maxMessageSizeBytes: Int = 76800  // Storage server's limit, should match `config.hpp` in libSession
    
    static let userSeed: Data = Data(hex: "0123456789abcdef0123456789abcdef")
    static let seed: Data = Data(hex: "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210")
    static let identity: (ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair) = try! Identity.generate(from: userSeed)
    static let keyPair: KeyPair = Crypto().generate(.ed25519KeyPair(seed: Array(seed)))!
    static let userEdSK: [UInt8] = identity.ed25519KeyPair.secretKey
    static let edPK: [UInt8] = keyPair.publicKey
    static let edSK: [UInt8] = keyPair.secretKey
    
    // Since we can't test the group without encryption keys and the C API doesn't have
    // a way to manually provide encryption keys we needed to create a dump with valid
    // key data and load that in so we can test the other cases, this dump contains a
    // single admin member and a single encryption key
    static let groupKeysDump: Data = Data(hex:
        "64363a6163746976656c65343a6b6579736c65373a70656e64696e6764313a633136373a" +
        "64313a2332343ae3abc434666653cb7e913a3101b83704e86a7395ac21a026313a476930" +
        "65313a4b34383a150c55d933f0c44d1e2527590ae8efbb482f17e04e2a6a3a23f7e900ad" +
        "2f69f9442fcd4e2fc623e63d7ccaf9a79ffcac313a6b6c65313a7e36343a64d960c70ff1" +
        "2967b677a8a2ce6e624e1da4c8e372c56d8c8e212ea6b420359e4b244efcb3f5cac8a86d" +
        "4bfe9dcb6fe9bbdfc98180851decf965dc6a6d2dce0865313a67693065313a6b33323a3e" +
        "c807213e56d2e3ddcf5096ae414db1689d2f436a6e6ec8e9178b4205e65f926565"
    )
    
    override class func spec() {
        // MARK: - libSession
        describe("libSession") {
            contactsSpec()
            userProfileSpec()
            convoInfoVolatileSpec()
            userGroupsSpec()
            groupInfoSpec()
            groupMembersSpec()
            
            // MARK: -- has correct test seed data
            it("has correct test seed data") {
                expect(LibSessionUtilSpec.userEdSK.toHexString().suffix(64))
                    .to(equal("4cb76fdc6d32278e3f83dbf608360ecc6b65727934b85d2fb86862ff98c46ab7"))
                expect(LibSessionUtilSpec.identity.x25519KeyPair.publicKey.toHexString())
                    .to(equal("d2ad010eeb72d72e561d9de7bd7b6989af77dcabffa03a5111a6c859ae5c3a72"))
                expect(String(LibSessionUtilSpec.userEdSK.toHexString().prefix(32)))
                    .to(equal(LibSessionUtilSpec.userSeed.toHexString()))
                
                expect(LibSessionUtilSpec.edPK.toHexString())
                    .to(equal("cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"))
                expect(String(Data(LibSessionUtilSpec.edSK.prefix(32)).toHexString()))
                    .to(equal(LibSessionUtilSpec.seed.toHexString()))
            }
            
            // MARK: -- parses community URLs correctly
            it("parses community URLs correctly") {
                let result1 = LibSession.parseCommunity(url: [
                    "https://example.com/",
                    "SomeRoom?public_key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                ].joined())
                let result2 = LibSession.parseCommunity(url: [
                    "HTTPS://EXAMPLE.COM/",
                    "sOMErOOM?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
                ].joined())
                let result3 = LibSession.parseCommunity(url: [
                    "HTTPS://EXAMPLE.COM/r/",
                    "someroom?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
                ].joined())
                let result4 = LibSession.parseCommunity(url: [
                    "http://example.com/r/",
                    "someroom?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
                ].joined())
                let result5 = LibSession.parseCommunity(url: [
                    "HTTPS://EXAMPLE.com:443/r/",
                    "someroom?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
                ].joined())
                let result6 = LibSession.parseCommunity(url: [
                    "HTTP://EXAMPLE.com:80/r/",
                    "someroom?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
                ].joined())
                let result7 = LibSession.parseCommunity(url: [
                    "http://example.com:80/r/",
                    "someroom?public_key=ASNFZ4mrze8BI0VniavN7wEjRWeJq83vASNFZ4mrze8"
                ].joined())
                let result8 = LibSession.parseCommunity(url: [
                    "http://example.com:80/r/",
                    "someroom?public_key=yrtwk3hjixg66yjdeiuauk6p7hy1gtm8tgih55abrpnsxnpm3zzo"
                ].joined())
                
                expect(result1?.server).to(equal("https://example.com"))
                expect(result1?.server).to(equal(result2?.server))
                expect(result1?.server).to(equal(result3?.server))
                expect(result1?.server).toNot(equal(result4?.server))
                expect(result4?.server).to(equal("http://example.com"))
                expect(result1?.server).to(equal(result5?.server))
                expect(result4?.server).to(equal(result6?.server))
                expect(result4?.server).to(equal(result7?.server))
                expect(result4?.server).to(equal(result8?.server))
                expect(result1?.room).to(equal("SomeRoom"))
                expect(result2?.room).to(equal("sOMErOOM"))
                expect(result3?.room).to(equal("someroom"))
                expect(result4?.room).to(equal("someroom"))
                expect(result5?.room).to(equal("someroom"))
                expect(result6?.room).to(equal("someroom"))
                expect(result7?.room).to(equal("someroom"))
                expect(result8?.room).to(equal("someroom"))
                expect(result1?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(result2?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(result3?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(result4?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(result5?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(result6?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(result7?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(result8?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
            }
        }
    }
}

// MARK: - CONTACTS

fileprivate extension LibSessionUtilSpec {
    enum ContactProperty: CaseIterable {
        case name
        case nickname
        case approved
        case approved_me
        case blocked
        case profile_pic
        case created
        case notifications
        case mute_until
    }

    class func contactsSpec() {
        context("CONTACTS") {
            @TestState var userEdSK: [UInt8]! = LibSessionUtilSpec.userEdSK
            @TestState var error: [CChar]! = [CChar](repeating: 0, count: 256)
            @TestState var state: UnsafeMutablePointer<state_object>?
            @TestState var initResult: Bool! = {
                let initResult = state_init(&state, &userEdSK, nil, 0, &error)
                
                // Need the hooks otherwise the size exceptions won't be thrown
                let storeResult: Bool = state_set_store_callback(
                    state,
                    { namespace, pubkey, timestamp_ms, dataPtr, dataLen, context in },
                    nil
                )
                let sendResult: Bool = state_set_send_callback(
                    state,
                    { pubkey, dataPtr, dataLen, responseCallback, appCtx, callbackCtx in },
                    nil
                )
                
                return (initResult && storeResult && sendResult)
            }()
            @TestState var numRecords: Int! = 0
            @TestState var randomGenerator: ARC4RandomNumberGenerator! = ARC4RandomNumberGenerator(seed: 1000)
            
            // MARK: -- when checking error catching
            context("when checking error catching") {
                // MARK: ---- it can catch size limit errors thrown when pushing
                it("can catch size limit errors thrown when pushing") {
                    for index in (0..<2500) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: state,
                            rand: &randomGenerator,
                            maxing: .allProperties
                        )
                        guard state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                            let cContact = maybeCtx!.assumingMemoryBound(to: contacts_contact.self)
                            state_set_contact(maybe_mutable_state, cContact)
                        }, &contact) else {
                            break
                        }
                    }
                    
                    expect((state?.pointee.last_error).map { String(cString: $0) }).to(equal("Config data is too large"))
                }
            }
            
            // MARK: -- when checking size limits
            context("when checking size limits") {
                // MARK: ---- has not changed the max empty records
                it("has not changed the max empty records") {
                    for index in (0..<2500) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: state,
                            rand: &randomGenerator
                        )
                        guard state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                            let cContact = maybeCtx!.assumingMemoryBound(to: contacts_contact.self)
                            state_set_contact(maybe_mutable_state, cContact)
                        }, &contact) else {
                            break
                        }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(2212))
                }
                
                // MARK: ---- has not changed the max name only records
                it("has not changed the max name only records") {
                    for index in (0..<2500) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: state,
                            rand: &randomGenerator,
                            maxing: [.name]
                        )
                        guard state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                            let cContact = maybeCtx!.assumingMemoryBound(to: contacts_contact.self)
                            state_set_contact(maybe_mutable_state, cContact)
                        }, &contact) else {
                            break
                        }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(742))
                }
                
                // MARK: ---- has not changed the max name and profile pic only records
                it("has not changed the max name and profile pic only records") {
                    for index in (0..<2500) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: state,
                            rand: &randomGenerator,
                            maxing: [.name, .profile_pic]
                        )
                        guard state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                            let cContact = maybeCtx!.assumingMemoryBound(to: contacts_contact.self)
                            state_set_contact(maybe_mutable_state, cContact)
                        }, &contact) else {
                            break
                        }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(270))
                }
                
                // MARK: ---- has not changed the max filled records
                it("has not changed the max filled records") {
                    for index in (0..<2500) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: state,
                            rand: &randomGenerator,
                            maxing: .allProperties
                        )
                        guard state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                            let cContact = maybeCtx!.assumingMemoryBound(to: contacts_contact.self)
                            state_set_contact(maybe_mutable_state, cContact)
                        }, &contact) else {
                            break
                        }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(220))
                }
            }
            
            // MARK: -- generates config correctly
            
            it("generates config correctly") {
                let createdTs: Int64 = 1680064059
                let nowTs: Int64 = Int64(Date().timeIntervalSince1970)
                expect(initResult).to(beTrue())
                
                // Empty contacts shouldn't have an existing contact
                let definitelyRealId: String = "050000000000000000000000000000000000000000000000000000000000000000"
                var cDefinitelyRealId: [CChar] = definitelyRealId.cArray.nullTerminated()
                let contactPtr: UnsafeMutablePointer<contacts_contact>? = nil
                expect(state_get_contact(state, contactPtr, &cDefinitelyRealId, nil)).to(beFalse())
                expect(state_size_contacts(state)).to(equal(0))
                
                var contact2: contacts_contact = contacts_contact()
                expect(state_get_or_construct_contact(state, &contact2, &cDefinitelyRealId, nil)).to(beTrue())
                expect(String(libSessionVal: contact2.name)).to(beEmpty())
                expect(String(libSessionVal: contact2.nickname)).to(beEmpty())
                expect(contact2.approved).to(beFalse())
                expect(contact2.approved_me).to(beFalse())
                expect(contact2.blocked).to(beFalse())
                expect(contact2.profile_pic).toNot(beNil()) // Creates an empty instance apparently
                expect(String(libSessionVal: contact2.profile_pic.url)).to(beEmpty())
                expect(contact2.created).to(equal(0))
                expect(contact2.notifications).to(equal(CONVO_NOTIFY_DEFAULT))
                expect(contact2.mute_until).to(equal(0))
                
                // Update the contact data
                contact2.name = "Joe".toLibSession()
                contact2.nickname = "Joey".toLibSession()
                contact2.approved = true
                contact2.approved_me = true
                contact2.created = createdTs
                contact2.notifications = CONVO_NOTIFY_ALL
                contact2.mute_until = nowTs + 1800
                
                // Update the contact
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    let cContact = maybeCtx!.assumingMemoryBound(to: contacts_contact.self)
                    state_set_contact(maybe_mutable_state, cContact)
                }, &contact2)
                
                // Ensure the contact details were updated
                var contact3: contacts_contact = contacts_contact()
                expect(state_get_contact(state, &contact3, &cDefinitelyRealId, nil)).to(beTrue())
                expect(String(libSessionVal: contact3.name)).to(equal("Joe"))
                expect(String(libSessionVal: contact3.nickname)).to(equal("Joey"))
                expect(contact3.approved).to(beTrue())
                expect(contact3.approved_me).to(beTrue())
                expect(contact3.profile_pic).toNot(beNil()) // Creates an empty instance apparently
                expect(String(libSessionVal: contact3.profile_pic.url)).to(beEmpty())
                expect(contact3.blocked).to(beFalse())
                expect(String(libSessionVal: contact3.session_id)).to(equal(definitelyRealId))
                expect(contact3.created).to(equal(createdTs))
                expect(contact3.notifications).to(equal(CONVO_NOTIFY_ALL))
                expect(contact3.mute_until).to(equal(nowTs + 1800))
                
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    let cContact = maybeCtx!.assumingMemoryBound(to: contacts_contact.self)
                    state_set_contact(maybe_mutable_state, cContact)
                }, &contact3)
                
                // Add another contact
                let anotherId: String = "051111111111111111111111111111111111111111111111111111111111111111"
                var cAnotherId: [CChar] = anotherId.cArray.nullTerminated()
                var contact4: contacts_contact = contacts_contact()
                expect(state_get_or_construct_contact(state, &contact4, &cAnotherId, nil)).to(beTrue())
                expect(String(libSessionVal: contact4.name)).to(beEmpty())
                expect(String(libSessionVal: contact4.nickname)).to(beEmpty())
                expect(contact4.approved).to(beFalse())
                expect(contact4.approved_me).to(beFalse())
                expect(contact4.profile_pic).toNot(beNil()) // Creates an empty instance apparently
                expect(String(libSessionVal: contact4.profile_pic.url)).to(beEmpty())
                expect(contact4.blocked).to(beFalse())
                
                // We're not setting any fields, but we should still keep a record of the session id
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    let cContact = maybeCtx!.assumingMemoryBound(to: contacts_contact.self)
                    state_set_contact(maybe_mutable_state, cContact)
                }, &contact4)
                
                // Iterate through and make sure we got everything we expected
                var sessionIds: [String] = []
                var nicknames: [String] = []
                expect(state_size_contacts(state)).to(equal(2))
                
                var contact5: contacts_contact = contacts_contact()
                let contactIterator: UnsafeMutablePointer<contacts_iterator> = contacts_iterator_new(state)
                while !contacts_iterator_done(contactIterator, &contact5) {
                    sessionIds.append(String(libSessionVal: contact5.session_id))
                    nicknames.append(String(libSessionVal: contact5.nickname, nullIfEmpty: true) ?? "(N/A)")
                    contacts_iterator_advance(contactIterator)
                }
                contacts_iterator_free(contactIterator) // Need to free the iterator
                
                expect(sessionIds.count).to(equal(2))
                expect(sessionIds.count).to(equal(state_size_contacts(state)))
                expect(sessionIds.first).to(equal(definitelyRealId))
                expect(sessionIds.last).to(equal(anotherId))
                expect(nicknames.first).to(equal("Joey"))
                expect(nicknames.last).to(equal("(N/A)"))
                
                // Delete a contact
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    let cDefinitelyRealId = maybeCtx!.assumingMemoryBound(to: [CChar].self)
                    state_erase_contact(maybe_mutable_state, cDefinitelyRealId)
                }, &cDefinitelyRealId)
                
                // Validate the changes
                var sessionIds2: [String] = []
                var nicknames2: [String] = []
                expect(state_size_contacts(state)).to(equal(1))
                
                var contact6: contacts_contact = contacts_contact()
                let contactIterator2: UnsafeMutablePointer<contacts_iterator> = contacts_iterator_new(state)
                while !contacts_iterator_done(contactIterator2, &contact6) {
                    sessionIds2.append(String(libSessionVal: contact6.session_id))
                    nicknames2.append(String(libSessionVal: contact6.nickname, nullIfEmpty: true) ?? "(N/A)")
                    contacts_iterator_advance(contactIterator2)
                }
                contacts_iterator_free(contactIterator2) // Need to free the iterator
                
                expect(sessionIds2.count).to(equal(1))
                expect(sessionIds2.first).to(equal(anotherId))
                expect(nicknames2.first).to(equal("(N/A)"))
            }
        }
    }
    
    // MARK: - Convenience
    
    private static func createContact(
        for index: Int,
        in state: UnsafeMutablePointer<state_object>?,
        rand: inout ARC4RandomNumberGenerator,
        maxing properties: [ContactProperty] = []
    ) throws -> contacts_contact {
        let postPrefixId: String = "05\(rand.nextBytes(count: 32).toHexString())"
        let sessionId: String = ("05\(index)a" + postPrefixId.suffix(postPrefixId.count - "05\(index)a".count))
        var cSessionId: [CChar] = sessionId.cArray.nullTerminated()
        var contact: contacts_contact = contacts_contact()
        
        guard state_get_or_construct_contact(state, &contact, &cSessionId, nil) else {
            throw LibSessionError.getOrConstructFailedUnexpectedly
        }
        
        // Set the values to the maximum data that can fit
        properties.forEach { property in
            switch property {
                case .approved: contact.approved = true
                case .approved_me: contact.approved_me = true
                case .blocked: contact.blocked = true
                case .created: contact.created = Int64.max
                case .notifications: contact.notifications = CONVO_NOTIFY_MENTIONS_ONLY
                case .mute_until: contact.mute_until = Int64.max
                
                case .name:
                    contact.name = rand.nextBytes(count: LibSession.sizeMaxNameBytes)
                        .toHexString()
                        .toLibSession()
                
                case .nickname:
                    contact.nickname = rand.nextBytes(count: LibSession.sizeMaxNicknameBytes)
                        .toHexString()
                        .toLibSession()
                    
                case .profile_pic:
                    contact.profile_pic = user_profile_pic(
                        url: rand.nextBytes(count: LibSession.sizeMaxProfileUrlBytes)
                            .toHexString()
                            .toLibSession(),
                        key: Data(rand.nextBytes(count: 32))
                            .toLibSession()
                    )
            }
        }
        
        return contact
    }
}

fileprivate extension Array where Element == LibSessionUtilSpec.ContactProperty {
    static var allProperties: [LibSessionUtilSpec.ContactProperty] = LibSessionUtilSpec.ContactProperty.allCases
}

// MARK: - USER_PROFILE

fileprivate extension LibSessionUtilSpec {
    class func userProfileSpec() {
        context("USER_PROFILE") {
            @TestState var userEdSK: [UInt8]! = LibSessionUtilSpec.userEdSK
            @TestState var error: [CChar]! = [CChar](repeating: 0, count: 256)
            @TestState var state: UnsafeMutablePointer<state_object>?
            @TestState var initResult: Bool! = { state_init(&state, &userEdSK, nil, 0, &error) }()
            
            // MARK: -- generates config correctly
            it("generates config correctly") {
                expect(initResult).to(beTrue())
                
                // Since it's empty there shouldn't be a name.
                let namePtr: UnsafePointer<CChar>? = state_get_profile_name(state)
                expect(namePtr).to(beNil())
                
                // This should also be unset:
                let pic: user_profile_pic = state_get_profile_pic(state)
                expect(String(libSessionVal: pic.url)).to(beEmpty())
                expect(state_get_profile_blinded_msgreqs(state)).to(equal(-1))
                
                // Now let's go set a profile name and picture:
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    //let mutable_state: UnsafeMutablePointer<mutable_user_state_object> = maybe_mutable_state,
                    let p: user_profile_pic = user_profile_pic(
                        url: "http://example.org/omg-pic-123.bmp".toLibSession(),
                        key: "secret78901234567890123456789012".data(using: .utf8)!.toLibSession()
                    )
                    state_set_profile_name(maybe_mutable_state, "Kallie")
                    state_set_profile_pic(maybe_mutable_state, p)
                    state_set_profile_nts_expiry(maybe_mutable_state, 9)
                    state_set_profile_blinded_msgreqs(maybe_mutable_state, 1)
                }, nil)
                
                // Retrieve them just to make sure they set properly:
                let namePtr2: UnsafePointer<CChar>? = state_get_profile_name(state)
                expect(namePtr2).toNot(beNil())
                expect(String(cString: namePtr2!)).to(equal("Kallie"))
                
                let pic2: user_profile_pic = state_get_profile_pic(state);
                expect(String(libSessionVal: pic2.url)).to(equal("http://example.org/omg-pic-123.bmp"))
                expect(Data(libSessionVal: pic2.key, count: DisplayPictureManager.aes256KeyByteLength))
                    .to(equal("secret78901234567890123456789012".data(using: .utf8)))
                expect(state_get_profile_nts_expiry(state)).to(equal(9))
                expect(state_get_profile_blinded_msgreqs(state)).to(equal(1))
                
                // Wouldn't do this in a normal session but doing it here to properly clean up
                // after the test
                state?.deallocate()
            }
        }
    }
}

// MARK: - CONVO_INFO_VOLATILE

fileprivate extension LibSessionUtilSpec {
    class func convoInfoVolatileSpec() {
        context("CONVO_INFO_VOLATILE") {
            @TestState var userEdSK: [UInt8]! = LibSessionUtilSpec.userEdSK
            @TestState var error: [CChar]! = [CChar](repeating: 0, count: 256)
            @TestState var state: UnsafeMutablePointer<state_object>?
            @TestState var initResult: Bool! = { state_init(&state, &userEdSK, nil, 0, &error) }()
            
            // MARK: -- generates config correctly
            it("generates config correctly") {
                expect(initResult).to(beTrue())
                
                // Empty contacts shouldn't have an existing contact
                let definitelyRealId: String = "055000000000000000000000000000000000000000000000000000000000000000"
                var cDefinitelyRealId: [CChar] = definitelyRealId.cArray.nullTerminated()
                var oneToOne1: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(state_get_convo_info_volatile_1to1(state, &oneToOne1, &cDefinitelyRealId, nil)).to(beFalse())
                expect(state_size_convo_info_volatile(state)).to(equal(0))
                
                var oneToOne2: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(state_get_or_construct_convo_info_volatile_1to1(state, &oneToOne2, &cDefinitelyRealId, nil))
                    .to(beTrue())
                expect(String(libSessionVal: oneToOne2.session_id)).to(equal(definitelyRealId))
                expect(oneToOne2.last_read).to(equal(0))
                expect(oneToOne2.unread).to(beFalse())
                
                // Update the last read
                let nowTimestampMs: Int64 = Int64(floor(Date().timeIntervalSince1970 * 1000))
                oneToOne2.last_read = nowTimestampMs
                
                // The new data doesn't get stored until we call this:
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    let cConvo = maybeCtx!.assumingMemoryBound(to: convo_info_volatile_1to1.self)
                    state_set_convo_info_volatile_1to1(maybe_mutable_state, cConvo)
                }, &oneToOne2)
                
                var legacyGroup1: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                var oneToOne3: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(state_get_convo_info_volatile_legacy_group(state, &legacyGroup1, &cDefinitelyRealId, nil))
                    .to(beFalse())
                expect(state_get_convo_info_volatile_1to1(state, &oneToOne3, &cDefinitelyRealId, nil)).to(beTrue())
                expect(oneToOne3.last_read).to(equal(nowTimestampMs))
                
                let openGroupBaseUrl: String = "http://Example.ORG:5678"
                var cOpenGroupBaseUrl: [CChar] = openGroupBaseUrl.cArray.nullTerminated()
                let openGroupBaseUrlResult: String = openGroupBaseUrl.lowercased()
                let openGroupRoom: String = "SudokuRoom"
                var cOpenGroupRoom: [CChar] = openGroupRoom.cArray.nullTerminated()
                let openGroupRoomResult: String = openGroupRoom.lowercased()
                var cOpenGroupPubkey: [UInt8] = Data(hex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
                    .bytes
                var community1: convo_info_volatile_community = convo_info_volatile_community()
                expect(state_get_or_construct_convo_info_volatile_community(state, &community1, &cOpenGroupBaseUrl, &cOpenGroupRoom, &cOpenGroupPubkey, nil)).to(beTrue())
                expect(String(libSessionVal: community1.base_url)).to(equal(openGroupBaseUrlResult))
                expect(String(libSessionVal: community1.room)).to(equal(openGroupRoomResult))
                expect(Data(libSessionVal: community1.pubkey, count: 32).toHexString())
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                community1.unread = true
                
                // The new data doesn't get stored until we call this:
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    let cConvo = maybeCtx!.assumingMemoryBound(to: convo_info_volatile_community.self)
                    state_set_convo_info_volatile_community(maybe_mutable_state, cConvo)
                }, &community1)
                
                var oneToOne4: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(state_get_convo_info_volatile_1to1(state, &oneToOne4, &cDefinitelyRealId, nil)).to(equal(true))
                expect(oneToOne4.last_read).to(equal(nowTimestampMs))
                expect(String(libSessionVal: oneToOne4.session_id)).to(equal(definitelyRealId))
                expect(oneToOne4.unread).to(beFalse())
                
                var community2: convo_info_volatile_community = convo_info_volatile_community()
                expect(state_get_convo_info_volatile_community(state, &community2, &cOpenGroupBaseUrl, &cOpenGroupRoom, nil)).to(beTrue())
                expect(String(libSessionVal: community2.base_url)).to(equal(openGroupBaseUrlResult))
                expect(String(libSessionVal: community2.room)).to(equal(openGroupRoomResult))
                expect(Data(libSessionVal: community2.pubkey, count: 32).toHexString())
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                community2.unread = true
                
                let anotherId: String = "051111111111111111111111111111111111111111111111111111111111111111"
                var cAnotherId: [CChar] = anotherId.cArray.nullTerminated()
                var oneToOne5: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(state_get_or_construct_convo_info_volatile_1to1(state, &oneToOne5, &cAnotherId, nil)).to(beTrue())
                oneToOne5.unread = true
                
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    let cConvo = maybeCtx!.assumingMemoryBound(to: convo_info_volatile_1to1.self)
                    state_set_convo_info_volatile_1to1(maybe_mutable_state, cConvo)
                }, &oneToOne5)
                
                let thirdId: String = "05cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                var cThirdId: [CChar] = thirdId.cArray.nullTerminated()
                var legacyGroup2: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                expect(state_get_or_construct_convo_info_volatile_legacy_group(state, &legacyGroup2, &cThirdId, nil)).to(beTrue())
                legacyGroup2.last_read = (nowTimestampMs - 50)
                
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    let cConvo = maybeCtx!.assumingMemoryBound(to: convo_info_volatile_legacy_group.self)
                    state_set_convo_info_volatile_legacy_group(maybe_mutable_state, cConvo)
                }, &legacyGroup2)
                
                // Iterate through and make sure we got everything we expected
                var seen: [String] = []
                expect(state_size_convo_info_volatile(state)).to(equal(4))
                expect(state_size_convo_info_volatile_1to1(state)).to(equal(2))
                expect(state_size_convo_info_volatile_communities(state)).to(equal(1))
                expect(state_size_convo_info_volatile_legacy_groups(state)).to(equal(1))
                
                var c1: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                var c2: convo_info_volatile_community = convo_info_volatile_community()
                var c3: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                let it: OpaquePointer = convo_info_volatile_iterator_new(state)
                
                while !convo_info_volatile_iterator_done(it) {
                    if convo_info_volatile_it_is_1to1(it, &c1) {
                        seen.append("1-to-1: \(String(libSessionVal: c1.session_id))")
                    }
                    else if convo_info_volatile_it_is_community(it, &c2) {
                        seen.append("og: \(String(libSessionVal: c2.base_url))/r/\(String(libSessionVal: c2.room))")
                    }
                    else if convo_info_volatile_it_is_legacy_group(it, &c3) {
                        seen.append("cl: \(String(libSessionVal: c3.group_id))")
                    }
                    
                    convo_info_volatile_iterator_advance(it)
                }
                convo_info_volatile_iterator_free(it)
                
                expect(seen).to(equal([
                    "1-to-1: 051111111111111111111111111111111111111111111111111111111111111111",
                    "1-to-1: 055000000000000000000000000000000000000000000000000000000000000000",
                    "og: http://example.org:5678/r/sudokuroom",
                    "cl: 05cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                ]))
                
                let fourthId: String = "052000000000000000000000000000000000000000000000000000000000000000"
                var cFourthId: [CChar] = fourthId.cArray.nullTerminated()
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    let cConvoId = maybeCtx!.assumingMemoryBound(to: [CChar].self)
                    state_erase_convo_info_volatile_1to1(maybe_mutable_state, cConvoId)
                }, &cFourthId)
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    let cConvoId = maybeCtx!.assumingMemoryBound(to: [CChar].self)
                    state_erase_convo_info_volatile_1to1(maybe_mutable_state, cConvoId)
                }, &cDefinitelyRealId)
                expect(state_size_convo_info_volatile(state)).to(equal(3))
                expect(state_size_convo_info_volatile_1to1(state)).to(equal(1))
                
                // Check the single-type iterators:
                var seen1: [String?] = []
                var c4: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                let it1: OpaquePointer = convo_info_volatile_iterator_new_1to1(state)
                
                while !convo_info_volatile_iterator_done(it1) {
                    expect(convo_info_volatile_it_is_1to1(it1, &c4)).to(beTrue())
                    
                    seen1.append(String(libSessionVal: c4.session_id))
                    convo_info_volatile_iterator_advance(it1)
                }
                
                convo_info_volatile_iterator_free(it1)
                expect(seen1).to(equal([
                    "051111111111111111111111111111111111111111111111111111111111111111"
                ]))
                
                var seen2: [String?] = []
                var c5: convo_info_volatile_community = convo_info_volatile_community()
                let it2: OpaquePointer = convo_info_volatile_iterator_new_communities(state)
                
                while !convo_info_volatile_iterator_done(it2) {
                    expect(convo_info_volatile_it_is_community(it2, &c5)).to(beTrue())
                    
                    seen2.append(String(libSessionVal: c5.base_url))
                    convo_info_volatile_iterator_advance(it2)
                }
                
                convo_info_volatile_iterator_free(it2)
                expect(seen2).to(equal([
                    "http://example.org:5678"
                ]))
                
                var seen3: [String?] = []
                var c6: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                let it3: OpaquePointer = convo_info_volatile_iterator_new_legacy_groups(state)
                
                while !convo_info_volatile_iterator_done(it3) {
                    expect(convo_info_volatile_it_is_legacy_group(it3, &c6)).to(beTrue())
                    
                    seen3.append(String(libSessionVal: c6.group_id))
                    convo_info_volatile_iterator_advance(it3)
                }
                
                convo_info_volatile_iterator_free(it3)
                expect(seen3).to(equal([
                    "05cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                ]))
            }
        }
    }
}

// MARK: - USER_GROUPS

fileprivate extension LibSessionUtilSpec {
    class func userGroupsSpec() {
        context("USER_GROUPS") {
            @TestState var userEdSK: [UInt8]! = LibSessionUtilSpec.userEdSK
            @TestState var error: [CChar]! = [CChar](repeating: 0, count: 256)
            @TestState var state: UnsafeMutablePointer<state_object>?
            @TestState var initResult: Bool! = { state_init(&state, &userEdSK, nil, 0, &error) }()
            
            // MARK: -- generates config correctly
            it("generates config correctly") {
                let createdTs: Int64 = 1680064059
                let nowTs: Int64 = Int64(Date().timeIntervalSince1970)
                expect(initResult).to(beTrue())
                
                // Empty contacts shouldn't have an existing contact
                let definitelyRealId: String = "055000000000000000000000000000000000000000000000000000000000000000"
                var cDefinitelyRealId: [CChar] = definitelyRealId.cArray.nullTerminated()
                var legacyGroup1: UnsafeMutablePointer<ugroups_legacy_group_info>?
                expect(state_get_ugroups_legacy_group(state, &legacyGroup1, &cDefinitelyRealId, nil)).to(beFalse())
                expect(legacyGroup1?.pointee).to(beNil())
                expect(state_size_ugroups(state)).to(equal(0))
                
                var legacyGroup2: UnsafeMutablePointer<ugroups_legacy_group_info>?
                expect(state_get_or_construct_ugroups_legacy_group(state, &legacyGroup2, &cDefinitelyRealId, nil)).to(beTrue())
                expect(legacyGroup2?.pointee).toNot(beNil())
                expect(String(libSessionVal: legacyGroup2?.pointee.session_id)).to(equal(definitelyRealId))
                expect(legacyGroup2?.pointee.disappearing_timer).to(equal(0))
                expect(String(libSessionVal: legacyGroup2?.pointee.enc_pubkey, fixedLength: 32)).to(equal(""))
                expect(String(libSessionVal: legacyGroup2?.pointee.enc_seckey, fixedLength: 32)).to(equal(""))
                expect(legacyGroup2?.pointee.priority).to(equal(0))
                expect(String(libSessionVal: legacyGroup2?.pointee.name)).to(equal(""))
                expect(legacyGroup2?.pointee.joined_at).to(equal(0))
                expect(legacyGroup2?.pointee.notifications).to(equal(CONVO_NOTIFY_DEFAULT))
                expect(legacyGroup2?.pointee.mute_until).to(equal(0))
                expect(legacyGroup2?.pointee.invited).to(beFalse())
                
                // Iterate through and make sure we got everything we expected
                var membersSeen1: [String: Bool] = [:]
                var memberSessionId1: UnsafePointer<CChar>? = nil
                var memberAdmin1: Bool = false
                let membersIt1: OpaquePointer = ugroups_legacy_members_begin(legacyGroup2)
                
                while ugroups_legacy_members_next(membersIt1, &memberSessionId1, &memberAdmin1) {
                    membersSeen1[String(cString: memberSessionId1!)] = memberAdmin1
                }
                
                ugroups_legacy_members_free(membersIt1)
                
                expect(membersSeen1).to(beEmpty())
                
                let users: [String] = [
                    "050000000000000000000000000000000000000000000000000000000000000000",
                    "051111111111111111111111111111111111111111111111111111111111111111",
                    "052222222222222222222222222222222222222222222222222222222222222222",
                    "053333333333333333333333333333333333333333333333333333333333333333",
                    "054444444444444444444444444444444444444444444444444444444444444444",
                    "055555555555555555555555555555555555555555555555555555555555555555",
                    "056666666666666666666666666666666666666666666666666666666666666666"
                ]
                var cUsers: [[CChar]] = users.map { $0.cArray.nullTerminated() }
                legacyGroup2?.pointee.name = "Englishmen".toLibSession()
                legacyGroup2?.pointee.disappearing_timer = 60
                legacyGroup2?.pointee.joined_at = createdTs
                legacyGroup2?.pointee.notifications = CONVO_NOTIFY_ALL
                legacyGroup2?.pointee.mute_until = (nowTs + 3600)
                legacyGroup2?.pointee.invited = true
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[0], false)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[1], true)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[2], false)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[4], true)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[5], false)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[2], false)).to(beFalse())
                
                // Flip to and from admin
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[2], true)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[1], false)).to(beTrue())
                
                expect(ugroups_legacy_member_remove(legacyGroup2, &cUsers[5])).to(beTrue())
                expect(ugroups_legacy_member_remove(legacyGroup2, &cUsers[4])).to(beTrue())
                
                var membersSeen2: [String: Bool] = [:]
                var memberSessionId2: UnsafePointer<CChar>? = nil
                var memberAdmin2: Bool = false
                let membersIt2: OpaquePointer = ugroups_legacy_members_begin(legacyGroup2)
                
                while ugroups_legacy_members_next(membersIt2, &memberSessionId2, &memberAdmin2) {
                    membersSeen2[String(cString: memberSessionId2!)] = memberAdmin2
                }
                
                ugroups_legacy_members_free(membersIt2)
                
                expect(membersSeen2).to(equal([
                    "050000000000000000000000000000000000000000000000000000000000000000": false,
                    "051111111111111111111111111111111111111111111111111111111111111111": false,
                    "052222222222222222222222222222222222222222222222222222222222222222": true
                ]))
                
                let groupSeed: Data = Data(hex: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
                let groupEd25519KeyPair: KeyPair = Crypto().generate(.ed25519KeyPair(seed: Array(groupSeed)))!
                let groupX25519PublicKey: [UInt8] = Crypto().generate(.x25519(ed25519Pubkey: groupEd25519KeyPair.publicKey))!
                
                // Note: this isn't exactly what Session actually does here for legacy closed
                // groups (rather it uses X25519 keys) but for this test the distinction doesn't matter.
                legacyGroup2?.pointee.enc_pubkey = Data(groupX25519PublicKey).toLibSession()
                legacyGroup2?.pointee.enc_seckey = Data(groupEd25519KeyPair.secretKey).toLibSession()
                legacyGroup2?.pointee.priority = 3
                
                expect(Data(libSessionVal: legacyGroup2?.pointee.enc_pubkey, count: 32).toHexString())
                    .to(equal("c5ba413c336f2fe1fb9a2c525f8a86a412a1db128a7841b4e0e217fa9eb7fd5e"))
                expect(Data(libSessionVal: legacyGroup2?.pointee.enc_seckey, count: 32).toHexString())
                    .to(equal("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"))
                
                // The new data doesn't get stored until we call this:
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    let cConvo = maybeCtx!.assumingMemoryBound(to: ugroups_legacy_group_info.self)
                    state_set_free_ugroups_legacy_group(maybe_mutable_state, cConvo)
                }, legacyGroup2)
                
                var legacyGroup3: UnsafeMutablePointer<ugroups_legacy_group_info>?
                expect(state_get_ugroups_legacy_group(state, &legacyGroup3, &cDefinitelyRealId, nil)).to(beTrue())
                expect(legacyGroup3?.pointee).toNot(beNil())
                ugroups_legacy_group_free(legacyGroup3)
                
                let communityPubkey: String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                var cCommunityPubkey: [UInt8] = Data(hex: communityPubkey).cArray
                var cCommunityBaseUrl: [CChar] = "http://Example.ORG:5678".cArray.nullTerminated()
                var cCommunityRoom: [CChar] = "SudokuRoom".cArray.nullTerminated()
                var community1: ugroups_community_info = ugroups_community_info()
                expect(state_get_or_construct_ugroups_community(state, &community1, &cCommunityBaseUrl, &cCommunityRoom, &cCommunityPubkey, nil))
                    .to(beTrue())
                
                expect(String(libSessionVal: community1.base_url)).to(equal("http://example.org:5678")) // Note: lower-case
                expect(String(libSessionVal: community1.room)).to(equal("SudokuRoom")) // Note: case-preserving
                expect(Data(libSessionVal: community1.pubkey, count: 32).toHexString())
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                community1.priority = 14
                
                // The new data doesn't get stored until we call this:
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    let cConvo = maybeCtx!.assumingMemoryBound(to: ugroups_community_info.self)
                    state_set_ugroups_community(maybe_mutable_state, cConvo)
                }, &community1)
                
                expect(state_size_ugroups(state)).to(equal(2))
                expect(state_size_ugroups_communities(state)).to(equal(1))
                expect(state_size_ugroups_legacy_groups(state)).to(equal(1))
                
                var legacyGroup4: UnsafeMutablePointer<ugroups_legacy_group_info>?
                expect(state_get_ugroups_legacy_group(state, &legacyGroup4, &cDefinitelyRealId, nil)).to(beTrue())
                expect(legacyGroup4?.pointee).toNot(beNil())
                expect(String(libSessionVal: legacyGroup4?.pointee.enc_pubkey, fixedLength: 32)).to(equal(""))
                expect(String(libSessionVal: legacyGroup4?.pointee.enc_seckey, fixedLength: 32)).to(equal(""))
                expect(legacyGroup4?.pointee.disappearing_timer).to(equal(60))
                expect(String(libSessionVal: legacyGroup4?.pointee.session_id)).to(equal(definitelyRealId))
                expect(legacyGroup4?.pointee.priority).to(equal(3))
                expect(String(libSessionVal: legacyGroup4?.pointee.name)).to(equal("Englishmen"))
                expect(legacyGroup4?.pointee.joined_at).to(equal(createdTs))
                expect(legacyGroup4?.pointee.notifications).to(equal(CONVO_NOTIFY_ALL))
                expect(legacyGroup4?.pointee.mute_until).to(equal(nowTs + 3600))
                expect(legacyGroup4?.pointee.invited).to(beTrue())
                
                var membersSeen3: [String: Bool] = [:]
                var memberSessionId3: UnsafePointer<CChar>? = nil
                var memberAdmin3: Bool = false
                let membersIt3: OpaquePointer = ugroups_legacy_members_begin(legacyGroup4)
                
                while ugroups_legacy_members_next(membersIt3, &memberSessionId3, &memberAdmin3) {
                    membersSeen3[String(cString: memberSessionId3!)] = memberAdmin3
                }
                
                ugroups_legacy_members_free(membersIt3)
                ugroups_legacy_group_free(legacyGroup4)
                
                expect(membersSeen3).to(equal([
                    "050000000000000000000000000000000000000000000000000000000000000000": false,
                    "051111111111111111111111111111111111111111111111111111111111111111": false,
                    "052222222222222222222222222222222222222222222222222222222222222222": true
                ]))
                
                
                // Iterate through and make sure we got everything we expected
                var seen: [String] = []
                
                var c1: ugroups_legacy_group_info = ugroups_legacy_group_info()
                var c2: ugroups_community_info = ugroups_community_info()
                let it: OpaquePointer = user_groups_iterator_new(state)
                
                while !user_groups_iterator_done(it) {
                    if user_groups_it_is_legacy_group(it, &c1) {
                        var memberCount: Int = 0
                        var adminCount: Int = 0
                        ugroups_legacy_members_count(&c1, &memberCount, &adminCount)
                        seen.append("legacy: \(String(libSessionVal: c1.name)), \(adminCount) admins, \(memberCount) members")
                    }
                    else if user_groups_it_is_community(it, &c2) {
                        seen.append("community: \(String(libSessionVal: c2.base_url))/r/\(String(libSessionVal: c2.room))")
                    }
                    else {
                        seen.append("unknown")
                    }
                    
                    user_groups_iterator_advance(it)
                }
                
                user_groups_iterator_free(it)
                
                expect(seen).to(equal([
                    "community: http://example.org:5678/r/SudokuRoom",
                    "legacy: Englishmen, 1 admins, 2 members"
                ]))
                
                var cCommunity2BaseUrl: [CChar] = "http://example.org:5678".cArray.nullTerminated()
                var cCommunity2Room: [CChar] = "sudokuRoom".cArray.nullTerminated()
                var community2: ugroups_community_info = ugroups_community_info()
                expect(state_get_ugroups_community(state, &community2, &cCommunity2BaseUrl, &cCommunity2Room, nil))
                    .to(beTrue())
                expect(String(libSessionVal: community2.base_url)).to(equal("http://example.org:5678"))
                expect(String(libSessionVal: community2.room)).to(equal("SudokuRoom")) // Case preserved from the stored value, not the input value
                expect(Data(libSessionVal: community2.pubkey, count: 32).toHexString())
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(community2.priority).to(equal(14))
                
                community2.room = "sudokuRoom".toLibSession()  // Change capitalization
                
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    let cConvo = maybeCtx!.assumingMemoryBound(to: ugroups_community_info.self)
                    state_set_ugroups_community(maybe_mutable_state, cConvo)
                }, &community2)
                
                var cCommunity3BaseUrl: [CChar] = "http://example.org:5678".cArray.nullTerminated()
                var cCommunity3Room: [CChar] = "SudokuRoom".cArray.nullTerminated()
                var community3: ugroups_community_info = ugroups_community_info()
                expect(state_get_ugroups_community(state, &community3, &cCommunity3BaseUrl, &cCommunity3Room, nil))
                    .to(beTrue())
                expect(String(libSessionVal: community3.room)).to(equal("sudokuRoom")) // We picked up the capitalization change
                
                expect(state_size_ugroups(state)).to(equal(2))
                expect(state_size_ugroups_communities(state)).to(equal(1))
                expect(state_size_ugroups_legacy_groups(state)).to(equal(1))
                
                var legacyGroup5: UnsafeMutablePointer<ugroups_legacy_group_info>?
                expect(state_get_ugroups_legacy_group(state, &legacyGroup5, &cDefinitelyRealId, nil)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup5, &cUsers[4], false)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup5, &cUsers[5], true)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup5, &cUsers[6], true)).to(beTrue())
                expect(ugroups_legacy_member_remove(legacyGroup5, &cUsers[1])).to(beTrue())
                
                state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                    let cConvo = maybeCtx!.assumingMemoryBound(to: ugroups_legacy_group_info.self)
                    var cCommunity4BaseUrl: [CChar] = "http://exAMple.ORG:5678".cArray.nullTerminated()
                    var cCommunity4Room: [CChar] = "sudokuROOM".cArray.nullTerminated()
                    state_set_free_ugroups_legacy_group(maybe_mutable_state, cConvo)
                    state_erase_ugroups_community(maybe_mutable_state, &cCommunity4BaseUrl, &cCommunity4Room)
                }, legacyGroup5)
                
                expect(state_size_ugroups(state)).to(equal(1))
                expect(state_size_ugroups_communities(state)).to(equal(0))
                expect(state_size_ugroups_legacy_groups(state)).to(equal(1))
                
                var prio: Int32 = 0
                var cBeanstalkBaseUrl: [CChar] = "http://jacksbeanstalk.org".cArray.nullTerminated()
                var cBeanstalkPubkey: [UInt8] = Data(
                    hex: "0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff"
                ).cArray
                
                ["fee", "fi", "fo", "fum"].forEach { room in
                    var cRoom: [CChar] = room.cArray.nullTerminated()
                    prio += 1
                    
                    var community4: ugroups_community_info = ugroups_community_info()
                    expect(state_get_or_construct_ugroups_community(state, &community4, &cBeanstalkBaseUrl, &cRoom, &cBeanstalkPubkey, nil))
                        .to(beTrue())
                    community4.priority = prio
                    
                    state_mutate_user(state, { maybe_mutable_state, maybeCtx in
                        let cConvo = maybeCtx!.assumingMemoryBound(to: ugroups_community_info.self)
                        state_set_ugroups_community(maybe_mutable_state, cConvo)
                    }, &community4)
                }
                
                expect(state_size_ugroups(state)).to(equal(5))
                expect(state_size_ugroups_communities(state)).to(equal(4))
                expect(state_size_ugroups_legacy_groups(state)).to(equal(1))
                
                
                // Iterate through and make sure we got everything we expected
                var seen2: [String] = []
                
                var c3: ugroups_legacy_group_info = ugroups_legacy_group_info()
                var c4: ugroups_community_info = ugroups_community_info()
                let it2: OpaquePointer = user_groups_iterator_new(state)
                
                while !user_groups_iterator_done(it2) {
                    if user_groups_it_is_legacy_group(it2, &c3) {
                        var memberCount: Int = 0
                        var adminCount: Int = 0
                        ugroups_legacy_members_count(&c3, &memberCount, &adminCount)
                        
                        seen2.append("legacy: \(String(libSessionVal: c1.name)), \(adminCount) admins, \(memberCount) members")
                    }
                    else if user_groups_it_is_community(it2, &c4) {
                        seen2.append("community: \(String(libSessionVal: c4.base_url))/r/\(String(libSessionVal: c4.room))")
                    }
                    else {
                        seen2.append("unknown")
                    }
                    
                    user_groups_iterator_advance(it2)
                }
                
                user_groups_iterator_free(it2)
                
                expect(seen2).to(equal([
                    "community: http://jacksbeanstalk.org/r/fee",
                    "community: http://jacksbeanstalk.org/r/fi",
                    "community: http://jacksbeanstalk.org/r/fo",
                    "community: http://jacksbeanstalk.org/r/fum",
                    "legacy: Englishmen, 3 admins, 2 members"
                ]))
            }
        }
    }
}

// MARK: - GROUP_INFO

fileprivate extension LibSessionUtilSpec {
    class func groupInfoSpec() {
        context("GROUP_INFO") {
            @TestState var userEdSK: [UInt8]! = LibSessionUtilSpec.userEdSK
            @TestState var error: [CChar]! = [CChar](repeating: 0, count: 256)
            @TestState var state: UnsafeMutablePointer<state_object>?
            @TestState var initResult: Bool! = { state_init(&state, &userEdSK, nil, 0, &error) }()
            @TestState var groupInfo: GroupInfo! = GroupInfo()
            
            // MARK: -- generates config correctly
            it("generates config correctly") {
                expect(initResult).to(beTrue())
                
                let cGroupInfoPtr: UnsafeMutableRawPointer = Unmanaged.passUnretained(groupInfo).toOpaque()
                MockStateManager.registerFakeResponse(for: state)
                
                state_create_group(
                    state,
                    "",
                    0,
                    "",
                    0,
                    user_profile_pic(),
                    [],
                    0,
                    { groupIdPtr, groupIdentityPrivateKeyPtr, errorPtr, errorLen, maybeCtx in
                        let groupInfo: GroupInfo = Unmanaged<GroupInfo>.fromOpaque(maybeCtx!).takeUnretainedValue()
                        groupInfo.groupId = SessionId(.group, hex: String(cString: groupIdPtr!))
                        groupInfo.groupSecretKey = Data(Array(Data(bytes: groupIdentityPrivateKeyPtr!, count: 64)))
                    },
                    cGroupInfoPtr
                )
                
                var cGroupId: [CChar] = groupInfo.groupId.hexString.cArray
                state_mutate_group(state, &cGroupId, { mutable_state, _ in
                    var cGroupName: [CChar] = "GROUP Name".cArray
                    var cGroupDesc: [CChar] = "this is where you go to play in the tomato sauce, I guess".cArray
                    state_set_group_name(mutable_state, &cGroupName)
                    state_set_group_description(mutable_state, &cGroupDesc)
                }, nil)
                
                var cName: [CChar] = [CChar](repeating: 0, count: LibSession.sizeMaxGroupNameBytes)
                var cDesc: [CChar] = [CChar](repeating: 0, count: LibSession.sizeMaxGroupDescriptionBytes)
                expect(state_get_group_name(state, &cGroupId, &cName)).to(beTrue())
                expect(state_get_group_description(state, &cGroupId, &cDesc)).to(beTrue())
                expect(String(cString: cName)).to(equal("GROUP Name"))
                expect(String(cString: cDesc)).to(equal("this is where you go to play in the tomato sauce, I guess"))
                
                let createTime: Int64 = 1682529839
                state_mutate_group(state, &cGroupId, { mutable_state, _ in
                    var cGroupName: [CChar] = "GROUP Name2".cArray
                    let createTime: Int64 = 1682529839
                    let pic: user_profile_pic = user_profile_pic(
                        url: "http://example.com/12345".toLibSession(),
                        key: Data(hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd")
                            .toLibSession()
                    )
                    state_set_group_pic(mutable_state, pic)
                    state_set_group_name(mutable_state, &cGroupName)
                    state_set_group_expiry_timer(mutable_state, 60 * 60)
                    state_set_group_created(mutable_state, createTime)
                    state_set_group_delete_before(mutable_state, createTime + (50 * 86400))
                    state_set_group_attach_delete_before(mutable_state, createTime + (70 * 86400))
                    state_set_group_created(mutable_state, createTime)
                    state_destroy_group(mutable_state)
                }, nil)
                
                var cName2: [CChar] = [CChar](repeating: 0, count: LibSession.sizeMaxGroupNameBytes)
                var pic2: user_profile_pic = user_profile_pic()
                var cExpiry: Int32 = -1
                var cCreated: Int64 = -1
                var cDeleteBefore: Int64 = -1
                var cAttachDeleteBefore: Int64 = -1
                expect(state_get_group_name(state, &cGroupId, &cName2)).to(beTrue())
                expect(state_get_group_pic(state, &cGroupId, &pic2)).to(beTrue())
                expect(state_get_group_expiry_timer(state, &cGroupId, &cExpiry)).to(beTrue())
                expect(state_get_group_created(state, &cGroupId, &cCreated)).to(beTrue())
                expect(state_get_group_delete_before(state, &cGroupId, &cDeleteBefore)).to(beTrue())
                expect(state_get_group_attach_delete_before(state, &cGroupId, &cAttachDeleteBefore)).to(beTrue())
                expect(String(cString: cName2)).to(equal("GROUP Name2"))
                expect(String(libSessionVal: pic2.url)).to(equal("http://example.com/12345"))
                expect(Data(libSessionVal: pic2.key, count: DisplayPictureManager.aes256KeyByteLength))
                    .to(equal(Data(
                        hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"
                    )))
                expect(cExpiry).to(equal(60 * 60))
                expect(cCreated).to(equal(createTime))
                expect(cDeleteBefore).to(equal(createTime + (50 * 86400)))
                expect(cAttachDeleteBefore).to(equal(createTime + (70 * 86400)))
                expect(state_group_is_destroyed(state, &cGroupId)).to(beTrue())
            }
        }
    }
}

// MARK: - GROUP_MEMBERS

fileprivate extension LibSessionUtilSpec {
    enum GroupMemberProperty: CaseIterable {
        case name
        case profile_pic
        case admin
        case invited
        case promoted
    }
    class GroupInfo {
        var groupId: SessionId!
        var groupSecretKey: Data!
    }
    
    class func groupMembersSpec() {
        context("GROUP_MEMBERS") {
            @TestState var userEdSK: [UInt8]! = LibSessionUtilSpec.userEdSK
            @TestState var error: [CChar]! = [CChar](repeating: 0, count: 256)
            @TestState var state: UnsafeMutablePointer<state_object>?
            @TestState var initResult: Bool! = { state_init(&state, &userEdSK, nil, 0, &error) }()
            @TestState var groupInfo: GroupInfo! = GroupInfo()
            @TestState var numRecords: Int! = 0
            
            beforeEach {
                let cGroupInfoPtr: UnsafeMutableRawPointer = Unmanaged.passUnretained(groupInfo).toOpaque()
                MockStateManager.registerFakeResponse(for: state)
                
                state_create_group(
                    state,
                    "",
                    0,
                    "",
                    0,
                    user_profile_pic(),
                    [],
                    0,
                    { groupIdPtr, groupIdentityPrivateKeyPtr, errorPtr, errorLen, maybeCtx in
                        let groupInfo: GroupInfo = Unmanaged<GroupInfo>.fromOpaque(maybeCtx!).takeUnretainedValue()
                        groupInfo.groupId = SessionId(.group, hex: String(cString: groupIdPtr!))
                        groupInfo.groupSecretKey = Data(Array(Data(bytes: groupIdentityPrivateKeyPtr!, count: 64)))
                    },
                    cGroupInfoPtr
                )
            }
            
            // MARK: -- when checking error catching
            context("when checking error catching") {
                // MARK: ---- it can catch size limit errors thrown when pushing
                it("can catch size limit errors thrown when pushing") {
                    expect(initResult).to(beTrue())
                    
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    var cGroupId: [CChar] = groupInfo.groupId.hexString.cArray

                    for index in (0..<2500) {
                        var member: state_group_member = try createMember(
                            for: index,
                            in: state,
                            groupId: groupInfo.groupId.hexString,
                            rand: &randomGenerator,
                            maxing: .allProperties
                        )
                        guard state_mutate_group(state, &cGroupId, { maybe_mutable_state, maybeCtx in
                            let cMember = maybeCtx!.assumingMemoryBound(to: state_group_member.self)
                            state_set_group_member(maybe_mutable_state, cMember)
                        }, &member) else {
                            break
                        }
                    }
                    
                    expect((state?.pointee.last_error).map { String(cString: $0) }).to(equal("Config data is too large"))
                }
            }

            // MARK: -- when checking size limits
            context("when checking size limits") {
                // MARK: ---- has not changed the max empty records
                it("has not changed the max empty records") {
                    expect(initResult).to(beTrue())
                    
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    var cGroupId: [CChar] = groupInfo.groupId.hexString.cArray

                    for index in (0..<2500) {
                        var member: state_group_member = try createMember(
                            for: index,
                            in: state,
                            groupId: groupInfo.groupId.hexString,
                            rand: &randomGenerator
                        )
                        guard state_mutate_group(state, &cGroupId, { maybe_mutable_state, maybeCtx in
                            let cMember = maybeCtx!.assumingMemoryBound(to: state_group_member.self)
                            state_set_group_member(maybe_mutable_state, cMember)
                        }, &member) else {
                            break
                        }

                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }

                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(2366))
                }

                // MARK: ---- has not changed the max name only records
                it("has not changed the max name only records") {
                    expect(initResult).to(beTrue())
                    
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    var cGroupId: [CChar] = groupInfo.groupId.hexString.cArray

                    for index in (0..<2500) {
                        var member: state_group_member = try createMember(
                            for: index,
                            in: state,
                            groupId: groupInfo.groupId.hexString,
                            rand: &randomGenerator,
                            maxing: [.name]
                        )
                        guard state_mutate_group(state, &cGroupId, { maybe_mutable_state, maybeCtx in
                            let cMember = maybeCtx!.assumingMemoryBound(to: state_group_member.self)
                            state_set_group_member(maybe_mutable_state, cMember)
                        }, &member) else {
                            break
                        }

                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }

                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(794))
                }

                // MARK: ---- has not changed the max name and profile pic only records
                it("has not changed the max name and profile pic only records") {
                    expect(initResult).to(beTrue())
                    
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    var cGroupId: [CChar] = groupInfo.groupId.hexString.cArray

                    for index in (0..<2500) {
                        var member: state_group_member = try createMember(
                            for: index,
                            in: state,
                            groupId: groupInfo.groupId.hexString,
                            rand: &randomGenerator,
                            maxing: [.name, .profile_pic]
                        )
                        guard state_mutate_group(state, &cGroupId, { maybe_mutable_state, maybeCtx in
                            let cMember = maybeCtx!.assumingMemoryBound(to: state_group_member.self)
                            state_set_group_member(maybe_mutable_state, cMember)
                        }, &member) else {
                            break
                        }

                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }

                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(289))
                }

                // MARK: ---- has not changed the max filled records
                it("has not changed the max filled records") {
                    expect(initResult).to(beTrue())
                    
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    var cGroupId: [CChar] = groupInfo.groupId.hexString.cArray

                    for index in (0..<2500) {
                        var member: state_group_member = try createMember(
                            for: index,
                            in: state,
                            groupId: groupInfo.groupId.hexString,
                            rand: &randomGenerator,
                            maxing: .allProperties
                        )
                        guard state_mutate_group(state, &cGroupId, { maybe_mutable_state, maybeCtx in
                            let cMember = maybeCtx!.assumingMemoryBound(to: state_group_member.self)
                            state_set_group_member(maybe_mutable_state, cMember)
                        }, &member) else {
                            break
                        }

                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }

                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(288))
                }
            }
            
            // MARK: -- generates config correctly
            it("generates config correctly") {
                expect(initResult).to(beTrue())
                
                var cGroupId: [CChar] = groupInfo.groupId.hexString.cArray
                let postPrefixId: String = ("05aa" + (0..<31).map { _ in "00" }.joined())
                let sids: [String] = (0..<256).map {
                    (postPrefixId.prefix(postPrefixId.count - "\($0)".count) + "\($0)")
                }
                class MemberWrapper {
                    var members: [state_group_member] = []
                }
                let memberWrapper: MemberWrapper = MemberWrapper()
                
                // 10 admins:
                (0..<10).forEach { index in
                    memberWrapper.members.append(
                        state_group_member(
                            session_id: sids[index].toLibSession(),
                            name: "Admin \(index)".toLibSession(),
                            profile_pic: user_profile_pic(
                                url: "http://example.com/".toLibSession(),
                                key: Data(hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd")
                                    .toLibSession()
                            ),
                            admin: true,
                            invited: 0,
                            promoted: 0,
                            removed: 0,
                            supplement: false
                        )
                    )
                }
                
                // 10 members:
                (10..<20).forEach { index in
                    memberWrapper.members.append(
                        state_group_member(
                            session_id: sids[index].toLibSession(),
                            name: "Member \(index)".toLibSession(),
                            profile_pic: user_profile_pic(
                                url: "http://example.com/".toLibSession(),
                                key: Data(hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd")
                                    .toLibSession()
                            ),
                            admin: false,
                            invited: 0,
                            promoted: 0,
                            removed: 0,
                            supplement: false
                        )
                    )
                }
                
                // 5 members with no attributes (not even a name):
                (20..<25).forEach { index in
                    var cMember: state_group_member = state_group_member()
                    cMember.session_id = sids[index].toLibSession()
                    memberWrapper.members.append(cMember)
                }
                
                let cMemberWrapperPtr: UnsafeMutableRawPointer = Unmanaged.passUnretained(memberWrapper).toOpaque()
                state_mutate_group(state, &cGroupId, { maybe_mutable_state, ctx in
                    let memberWrapper: MemberWrapper = Unmanaged<MemberWrapper>.fromOpaque(ctx!).takeUnretainedValue()
                    memberWrapper.members.forEach {
                        var cMember: state_group_member = $0
                        state_set_group_member(maybe_mutable_state, &cMember)
                    }
                }, cMemberWrapperPtr)
                
                // Current user is automatically added as an admin
                expect(state_size_group_members(state, &cGroupId)).to(equal(26))
                
                (0..<25).forEach { index in
                    var cSessionId: [CChar] = sids[index].cArray
                    var member: state_group_member = state_group_member()
                    expect(state_get_group_member(state, &cGroupId, &member, &cSessionId, nil)).to(beTrue())
                    expect(String(libSessionVal: member.session_id)).to(equal(sids[index]))
                    expect(member.invited).to(equal(0))
                    expect(member.promoted).to(equal(0))
                    expect(member.removed).to(equal(0))
                    
                    switch index {
                        case 0..<10:
                            expect(String(libSessionVal: member.name)).to(equal("Admin \(index)"))
                            expect(member.admin).to(beTrue())
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).toNot(beEmpty())
                            expect(Data(libSessionVal: member.profile_pic.key, count: DisplayPictureManager.aes256KeyByteLength))
                                .to(equal(Data(
                                    hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"
                                )))
                            
                        case 10..<20:
                            expect(String(libSessionVal: member.name)).to(equal("Member \(index)"))
                            expect(member.admin).to(beFalse())
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).toNot(beEmpty())
                            expect(Data(libSessionVal: member.profile_pic.key, count: DisplayPictureManager.aes256KeyByteLength))
                                .to(equal(Data(
                                    hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"
                                )))
                            
                        case 20..<25:
                            expect(String(libSessionVal: member.name)).to(beEmpty())
                            expect(member.admin).to(beFalse())
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).to(beEmpty())
                            expect(String(libSessionVal: member.profile_pic.key)).to(beEmpty())
                            
                        default: expect(true).to(beFalse())  // All cases covered
                    }
                }
            }
        }
    }
    
    // MARK: - Convenience
    
    private static func createMember(
        for index: Int,
        in state: UnsafeMutablePointer<state_object>?,
        groupId: String,
        rand: inout ARC4RandomNumberGenerator,
        maxing properties: [GroupMemberProperty] = []
    ) throws -> state_group_member {
        let postPrefixId: String = "05\(rand.nextBytes(count: 32).toHexString())"
        let sessionId: String = ("05\(index)a" + postPrefixId.suffix(postPrefixId.count - "05\(index)a".count))
        var cGroupId: [CChar] = groupId.cArray
        var cSessionId: [CChar] = sessionId.cArray.nullTerminated()
        var member: state_group_member = state_group_member()
        
        guard state_get_or_construct_group_member(state, &cGroupId, &member, &cSessionId, nil) else {
            throw LibSessionError.getOrConstructFailedUnexpectedly
        }
        
        // Set the values to the maximum data that can fit
        properties.forEach { property in
            switch property {
                case .admin: member.admin = true
                case .invited: member.invited = true
                case .promoted: member.promoted = true
                
                case .name:
                    member.name = rand.nextBytes(count: LibSession.sizeMaxNameBytes)
                        .toHexString()
                        .toLibSession()
                
                case .profile_pic:
                    member.profile_pic = user_profile_pic(
                        url: rand.nextBytes(count: LibSession.sizeMaxProfileUrlBytes)
                            .toHexString()
                            .toLibSession(),
                        key: Data(rand.nextBytes(count: 32))
                            .toLibSession()
                    )
            }
        }
        
        return member
    }
}

fileprivate extension Array where Element == LibSessionUtilSpec.GroupMemberProperty {
    static var allProperties: [LibSessionUtilSpec.GroupMemberProperty] = LibSessionUtilSpec.GroupMemberProperty.allCases
}
