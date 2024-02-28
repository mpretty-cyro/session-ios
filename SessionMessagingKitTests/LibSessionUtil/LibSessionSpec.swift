// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionSnodeKit
@testable import SessionMessagingKit

class LibSessionSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var groupId: SessionId! = SessionId(.group, hex: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece")
        @TestState var groupSecretKey: Data! = Data(hex:
            "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210" +
            "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
        )
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
            dependencies.setMockableValue(JSONEncoder.OutputFormatting.sortedKeys)  // Deterministic ordering
        }
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
            }
        )
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self,
                SNMessagingKit.self
            ],
            using: dependencies,
            initialData: { db in
                try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            }
        )
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { $0.generate(.ed25519KeyPair()) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Data.data(
                                fromHex: "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
                            )!.bytes,
                            secretKey: Data.data(
                                fromHex: "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210" +
                                "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
                            )!.bytes
                        )
                    )
                crypto
                    .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                    .thenReturn(Authentication.Signature.standard(signature: Array("TestSignature".data(using: .utf8)!)))
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork(
            initialSetup: { network in
                network
                    .when { $0.send(.selectedNetworkRequest(.any, to: .any, timeout: .any, using: .any)) }
                    .thenReturn(MockNetwork.response(data: Data([1, 2, 3])))
            }
        )
        @TestState(singleton: .jobRunner, in: dependencies) var mockJobRunner: MockJobRunner! = MockJobRunner(
            initialSetup: { jobRunner in
                jobRunner
                    .when { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any, using: .any) }
                    .thenReturn(nil)
            }
        )
        @TestState(defaults: .standard, in: dependencies) var mockUserDefaults: MockUserDefaults! = MockUserDefaults(
            initialSetup: { userDefaults in
                userDefaults.when { $0.string(forKey: .any) }.thenReturn(nil)
            }
        )
        @TestState var mockSwarmCache: Set<Snode>! = [
            Snode(
                address: "test",
                port: 0,
                ed25519PublicKey: TestConstants.edPublicKey,
                x25519PublicKey: TestConstants.publicKey
            ),
            Snode(
                address: "test",
                port: 1,
                ed25519PublicKey: TestConstants.edPublicKey,
                x25519PublicKey: TestConstants.publicKey
            ),
            Snode(
                address: "test",
                port: 2,
                ed25519PublicKey: TestConstants.edPublicKey,
                x25519PublicKey: TestConstants.publicKey
            )
        ]
        @TestState(cache: .snodeAPI, in: dependencies) var mockSnodeAPICache: MockSnodeAPICache! = MockSnodeAPICache(
            initialSetup: { cache in
                cache.when { $0.clockOffsetMs }.thenReturn(0)
                cache.when { $0.hasLoadedSwarm(for: .any) }.thenReturn(true)
                cache.when { $0.swarmCache(publicKey: .any) }.thenReturn(mockSwarmCache)
                cache.when { $0.setSwarmCache(publicKey: .any, cache: .any) }.thenReturn(nil)
            }
        )
        @TestState var stateManager: LibSession.StateManager! = { [dependencies, mockStorage] in
            mockStorage!.read { db in
                let result = try LibSession.StateManager(db, using: dependencies!)
                MockStateManager.registerFakeResponse(for: result.state)
                return result
            }
        }()
        
        // MARK: - LibSession
        describe("LibSession") {
            // MARK: -- when parsing a community url
            context("when parsing a community url") {
                // MARK: ---- handles the example urls correctly
                it("handles the example urls correctly") {
                    let validUrls: [String] = [
                        [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ],
                        [
                            "https://sessionopengroup.co/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ],
                        [
                            "http://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ],
                        [
                            "http://sessionopengroup.co/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ],
                        [
                            "https://143.198.213.225:443/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ],
                        [
                            "https://143.198.213.225:443/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ],
                        [
                            "http://143.198.213.255:80/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ],
                        [
                            "http://143.198.213.255:80/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ]
                    ].map { $0.joined() }
                    let processedValues: [(room: String, server: String, publicKey: String)] = validUrls
                        .map { LibSession.parseCommunity(url: $0) }
                        .compactMap { $0 }
                    let processedRooms: [String] = processedValues.map { $0.room }
                    let processedServers: [String] = processedValues.map { $0.server }
                    let processedPublicKeys: [String] = processedValues.map { $0.publicKey }
                    let expectedRooms: [String] = [String](repeating: "main", count: 8)
                    let expectedServers: [String] = [
                        "https://sessionopengroup.co",
                        "https://sessionopengroup.co",
                        "http://sessionopengroup.co",
                        "http://sessionopengroup.co",
                        "https://143.198.213.225",
                        "https://143.198.213.225",
                        "http://143.198.213.255",
                        "http://143.198.213.255"
                    ]
                    let expectedPublicKeys: [String] = [String](
                        repeating: "658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c",
                        count: 8
                    )
                    
                    expect(processedValues.count).to(equal(validUrls.count))
                    expect(processedRooms).to(equal(expectedRooms))
                    expect(processedServers).to(equal(expectedServers))
                    expect(processedPublicKeys).to(equal(expectedPublicKeys))
                }

                // MARK: ---- handles the r prefix if present
                it("handles the r prefix if present") {
                    let info = LibSession.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )
                    
                    expect(info?.room).to(equal("main"))
                    expect(info?.server).to(equal("https://sessionopengroup.co"))
                    expect(info?.publicKey).to(equal("658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"))
                }

                // MARK: ---- fails if no scheme is provided
                it("fails if no scheme is provided") {
                    let info = LibSession.parseCommunity(
                        url: [
                            "sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                // MARK: ---- fails if there is no room
                it("fails if there is no room") {
                    let info = LibSession.parseCommunity(
                        url: [
                            "https://sessionopengroup.co?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                // MARK: ---- fails if there is no public key parameter
                it("fails if there is no public key parameter") {
                    let info = LibSession.parseCommunity(
                        url: "https://sessionopengroup.co/r/main"
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                // MARK: ---- fails if the public key parameter is not 64 characters
                it("fails if the public key parameter is not 64 characters") {
                    let info = LibSession.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231"
                        ].joined()
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                // MARK: ---- fails if the public key parameter is not a hex string
                it("fails if the public key parameter is not a hex string") {
                    let info = LibSession.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                        ].joined()
                    )
                    
                    expect(info?.room).to(beNil())
                    expect(info?.server).to(beNil())
                    expect(info?.publicKey).to(beNil())
                }
                
                // MARK: ---- maintains the same TLS
                it("maintains the same TLS") {
                    let server1 = LibSession.parseCommunity(
                        url: [
                            "http://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )?.server
                    let server2 = LibSession.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )?.server
                    
                    expect(server1).to(equal("http://sessionopengroup.co"))
                    expect(server2).to(equal("https://sessionopengroup.co"))
                }
                
                // MARK: ---- maintains the same port
                it("maintains the same port") {
                    let server1 = LibSession.parseCommunity(
                        url: [
                            "https://sessionopengroup.co/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )?.server
                    let server2 = LibSession.parseCommunity(
                        url: [
                            "https://sessionopengroup.co:1234/r/main?",
                            "public_key=658d29b91892a2389505596b135e76a53db6e11d613a51dbd3d0816adffb231c"
                        ].joined()
                    )?.server
                    
                    expect(server1).to(equal("https://sessionopengroup.co"))
                    expect(server2).to(equal("https://sessionopengroup.co:1234"))
                }
            }
            
            // MARK: -- when generating a url
            context("when generating a url") {
                // MARK: ---- generates the url correctly
                it("generates the url correctly") {
                    expect(LibSession.communityUrlFor(server: "server", roomToken: "room", publicKey: "f8fec9b701000000ffffffff0400008000000000000000000000000000000000"))
                        .to(equal("server/room?public_key=f8fec9b701000000ffffffff0400008000000000000000000000000000000000"))
                }
                
                // MARK: ---- maintains the casing provided
                it("maintains the casing provided") {
                    expect(LibSession.communityUrlFor(server: "SeRVer", roomToken: "RoOM", publicKey: "f8fec9b701000000ffffffff0400008000000000000000000000000000000000"))
                        .to(equal("SeRVer/RoOM?public_key=f8fec9b701000000ffffffff0400008000000000000000000000000000000000"))
                }
            }
            
            // MARK: -- when creating a group
            context("when creating a group") {
                // MARK: ---- fails when given an invalid member id
                it("fails when given an invalid member id") {
                    var resultError: Error? = nil
                    
                    stateManager.createGroup(
                        name: "Test",
                        description: "TestDesc",
                        displayPictureUrl: nil,
                        displayPictureEncryptionKey: nil,
                        members: [("123456", nil, nil, nil)]
                    ) { groupId, groupSecretKey, error in
                        resultError = error
                    }
                    
                    expect(resultError).to(matchError(
                        LibSessionError.libSessionError("Invalid session ID: expected 66 hex digits starting with 05; got 123456")
                    ))
                }
            }
            
            // MARK: -- when receiving a GROUP_INFO update
            context("when receiving a GROUP_INFO update") {
                @TestState var latestGroup: ClosedGroup?
                @TestState var initialDisappearingConfig: DisappearingMessagesConfiguration?
                @TestState var latestDisappearingConfig: DisappearingMessagesConfiguration?
                
                beforeEach {
                    stateManager.createGroup(
                        name: "Test",
                        description: "TestDesc",
                        displayPictureUrl: nil,
                        displayPictureEncryptionKey: nil,
                        members: []
                    ) { groupIdNew, groupSecretKeyNew, error in
                        groupId = SessionId(.group, hex: groupIdNew)
                        groupSecretKey = Data(groupSecretKeyNew)
                    }
                    
                    mockStorage.write(using: dependencies) { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            shouldBeVisible: true,
                            calledFromConfigHandling: false,
                            using: dependencies
                        )
                        try ClosedGroup(
                            threadId: groupId.hexString,
                            name: "Test",
                            formationTimestamp: 0,
                            shouldPoll: false,
                            groupIdentityPrivateKey: Data([5, 4, 3, 2, 1]),
                            authData: Data([1, 2, 3, 4, 5]),
                            invited: false
                        ).upsert(db)
                        
                        initialDisappearingConfig = try DisappearingMessagesConfiguration
                            .fetchOne(db, id: groupId.hexString)
                            .defaulting(
                                to: DisappearingMessagesConfiguration.defaultWith(groupId.hexString)
                            )
                    }
                }
                
                // MARK: ---- removes group data if the group is destroyed
                it("removes group data if the group is destroyed") {
                    var cGroupId: [CChar] = groupId.hexString.cArray
                    state_mutate_group(stateManager.state, &cGroupId, { mutable_state, ctx in
                        state_destroy_group(mutable_state)
                    }, nil)
                    
                    mockStorage.write(using: dependencies) { db in
                        try LibSession.handleGroupInfoUpdate(
                            db,
                            in: stateManager.state,
                            groupSessionId: SessionId(.group, hex: groupId.hexString),
                            serverTimestampMs: 1234567891000,
                            using: dependencies
                        )
                    }
                    
                    latestGroup = mockStorage.read(using: dependencies) { db in
                        try ClosedGroup.fetchOne(db, id: groupId.hexString)
                    }
                    expect(latestGroup?.authData).to(beNil())
                    expect(latestGroup?.groupIdentityPrivateKey).to(beNil())
                }
                
                // MARK: ---- updates the name if it changed
                it("updates the name if it changed") {
                    var cGroupId: [CChar] = groupId.hexString.cArray
                    state_mutate_group(stateManager.state, &cGroupId, { mutable_state, ctx in
                        var cUpdatedName: [CChar] = "UpdatedName".cArray.nullTerminated()
                        state_set_group_name(mutable_state, &cUpdatedName)
                    }, nil)
                    
                    mockStorage.write(using: dependencies) { db in
                        try LibSession.handleGroupInfoUpdate(
                            db,
                            in: stateManager.state,
                            groupSessionId: SessionId(.group, hex: groupId.hexString),
                            serverTimestampMs: 1234567891000,
                            using: dependencies
                        )
                    }
                    
                    latestGroup = mockStorage.read(using: dependencies) { db in
                        try ClosedGroup.fetchOne(db, id: groupId.hexString)
                    }
                    expect(latestGroup?.name).to(equal("UpdatedName"))
                }
                
                // MARK: ---- updates the description if it changed
                it("updates the description if it changed") {
                    var cGroupId: [CChar] = groupId.hexString.cArray
                    state_mutate_group(stateManager.state, &cGroupId, { mutable_state, ctx in
                        var cUpdatedDesc: [CChar] = "UpdatedDesc".cArray.nullTerminated()
                        state_set_group_description(mutable_state, &cUpdatedDesc)
                    }, nil)
                    
                    mockStorage.write(using: dependencies) { db in
                        try LibSession.handleGroupInfoUpdate(
                            db,
                            in: stateManager.state,
                            groupSessionId: SessionId(.group, hex: groupId.hexString),
                            serverTimestampMs: 1234567891000,
                            using: dependencies
                        )
                    }
                    
                    latestGroup = mockStorage.read(using: dependencies) { db in
                        try ClosedGroup.fetchOne(db, id: groupId.hexString)
                    }
                    expect(latestGroup?.groupDescription).to(equal("UpdatedDesc"))
                }
                
                // MARK: ---- updates the formation timestamp if it changed
                it("updates the formation timestamp if it changed") {
                    var cGroupId: [CChar] = groupId.hexString.cArray
                    state_mutate_group(stateManager.state, &cGroupId, { mutable_state, ctx in
                        state_set_group_created(mutable_state, 54321)
                    }, nil)
                    
                    mockStorage.write(using: dependencies) { db in
                        try LibSession.handleGroupInfoUpdate(
                            db,
                            in: stateManager.state,
                            groupSessionId: SessionId(.group, hex: groupId.hexString),
                            serverTimestampMs: 1234567891000,
                            using: dependencies
                        )
                    }
                    
                    latestGroup = mockStorage.read(using: dependencies) { db in
                        try ClosedGroup.fetchOne(db, id: groupId.hexString)
                    }
                    expect(latestGroup?.formationTimestamp).to(equal(54321))
                }
                
                // MARK: ---- and the display picture was changed
                context("and the display picture was changed") {
                    // MARK: ------ removes the display picture
                    it("removes the display picture") {
                        mockStorage.write(using: dependencies) { db in
                            try ClosedGroup
                                .updateAll(
                                    db,
                                    ClosedGroup.Columns.displayPictureUrl.set(to: "TestUrl"),
                                    ClosedGroup.Columns.displayPictureEncryptionKey.set(to: Data([1, 2, 3])),
                                    ClosedGroup.Columns.displayPictureFilename.set(to: "TestFilename")
                                )
                        }
                        
                        mockStorage.write(using: dependencies) { db in
                            try LibSession.handleGroupInfoUpdate(
                                db,
                                in: stateManager.state,
                                groupSessionId: SessionId(.group, hex: groupId.hexString),
                                serverTimestampMs: 1234567891000,
                                using: dependencies
                            )
                        }
                        
                        latestGroup = mockStorage.read(using: dependencies) { db in
                            try ClosedGroup.fetchOne(db, id: groupId.hexString)
                        }
                        expect(latestGroup?.displayPictureUrl).to(beNil())
                        expect(latestGroup?.displayPictureEncryptionKey).to(beNil())
                        expect(latestGroup?.displayPictureFilename).to(beNil())
                        expect(latestGroup?.lastDisplayPictureUpdate).to(equal(1234567891))
                    }
                    
                    // MARK: ------ schedules a display picture download job if there is a new one
                    it("schedules a display picture download job if there is a new one") {
                        var cGroupId: [CChar] = groupId.hexString.cArray
                        state_mutate_group(stateManager.state, &cGroupId, { mutable_state, ctx in
                            var cDisplayPic: user_profile_pic = user_profile_pic()
                            cDisplayPic.url = "https://www.oxen.io/file/1234".toLibSession()
                            cDisplayPic.key = Data(
                                repeating: 1,
                                count: DisplayPictureManager.aes256KeyByteLength
                            ).toLibSession()
                            state_set_group_pic(mutable_state, cDisplayPic)
                        }, nil)
                        
                        mockStorage.write(using: dependencies) { db in
                            try LibSession.handleGroupInfoUpdate(
                                db,
                                in: stateManager.state,
                                groupSessionId: SessionId(.group, hex: groupId.hexString),
                                serverTimestampMs: 1234567891000,
                                using: dependencies
                            )
                        }
                        
                        expect(mockJobRunner)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { jobRunner in
                                jobRunner.add(
                                    .any,
                                    job: Job(
                                        variant: .displayPictureDownload,
                                        behaviour: .runOnce,
                                        shouldBlock: false,
                                        shouldBeUnique: true,
                                        shouldSkipLaunchBecomeActive: false,
                                        details: DisplayPictureDownloadJob.Details(
                                            target: .group(
                                                id: groupId.hexString,
                                                url: "https://www.oxen.io/file/1234",
                                                encryptionKey: Data(
                                                    repeating: 1,
                                                    count: DisplayPictureManager.aes256KeyByteLength
                                                )
                                            ),
                                            timestamp: 1234567891
                                        )
                                    ),
                                    canStartJob: true,
                                    using: .any
                                )
                            })
                    }
                }
                
                // MARK: ---- updates the disappearing messages config
                it("updates the disappearing messages config") {
                    var cGroupId: [CChar] = groupId.hexString.cArray
                    state_mutate_group(stateManager.state, &cGroupId, { mutable_state, ctx in
                        state_set_group_expiry_timer(mutable_state, 10)
                    }, nil)
                    
                    mockStorage.write(using: dependencies) { db in
                        try LibSession.handleGroupInfoUpdate(
                            db,
                            in: stateManager.state,
                            groupSessionId: SessionId(.group, hex: groupId.hexString),
                            serverTimestampMs: 1234567891000,
                            using: dependencies
                        )
                    }
                    
                    latestDisappearingConfig = mockStorage.read(using: dependencies) { db in
                        try DisappearingMessagesConfiguration.fetchOne(db, id: groupId.hexString)
                    }
                    expect(initialDisappearingConfig?.isEnabled).to(beFalse())
                    expect(initialDisappearingConfig?.durationSeconds).to(equal(0))
                    expect(latestDisappearingConfig?.isEnabled).to(beTrue())
                    expect(latestDisappearingConfig?.durationSeconds).to(equal(10))
                }
                
                // MARK: ---- containing a deleteBefore timestamp
                context("containing a deleteBefore timestamp") {
                    @TestState var numInteractions: Int!
                    
                    // MARK: ------ deletes messages before the timestamp
                    it("deletes messages before the timestamp") {
                        mockStorage.write(using: dependencies) { db in
                            try SessionThread.fetchOrCreate(
                                db,
                                id: groupId.hexString,
                                variant: .contact,
                                shouldBeVisible: true,
                                calledFromConfigHandling: false,
                                using: dependencies
                            )
                            _ = try Interaction(
                                serverHash: "1234",
                                threadId: groupId.hexString,
                                authorId: "4321",
                                variant: .standardIncoming,
                                timestampMs: 100000000
                            ).inserted(db)
                        }
                        
                        var cGroupId: [CChar] = groupId.hexString.cArray
                        state_mutate_group(stateManager.state, &cGroupId, { mutable_state, ctx in
                            state_set_group_delete_before(mutable_state, 123456)
                        }, nil)
                        
                        mockStorage.write(using: dependencies) { db in
                            try LibSession.handleGroupInfoUpdate(
                                db,
                                in: stateManager.state,
                                groupSessionId: SessionId(.group, hex: groupId.hexString),
                                serverTimestampMs: 1234567891000,
                                using: dependencies
                            )
                        }
                        
                        numInteractions = mockStorage.read(using: dependencies) { db in
                            try Interaction.fetchCount(db)
                        }
                        expect(numInteractions).to(equal(0))
                    }
                    
                    // MARK: ------ does not delete messages after the timestamp
                    it("does not delete messages after the timestamp") {
                        mockStorage.write(using: dependencies) { db in
                            try SessionThread.fetchOrCreate(
                                db,
                                id: groupId.hexString,
                                variant: .contact,
                                shouldBeVisible: true,
                                calledFromConfigHandling: false,
                                using: dependencies
                            )
                            _ = try Interaction(
                                serverHash: "1234",
                                threadId: groupId.hexString,
                                authorId: "4321",
                                variant: .standardIncoming,
                                timestampMs: 100000000
                            ).inserted(db)
                            _ = try Interaction(
                                serverHash: "1235",
                                threadId: groupId.hexString,
                                authorId: "4322",
                                variant: .standardIncoming,
                                timestampMs: 200000000
                            ).inserted(db)
                        }
                        
                        var cGroupId: [CChar] = groupId.hexString.cArray
                        state_mutate_group(stateManager.state, &cGroupId, { mutable_state, ctx in
                            state_set_group_delete_before(mutable_state, 123456)
                        }, nil)
                        
                        mockStorage.write(using: dependencies) { db in
                            try LibSession.handleGroupInfoUpdate(
                                db,
                                in: stateManager.state,
                                groupSessionId: SessionId(.group, hex: groupId.hexString),
                                serverTimestampMs: 1234567891000,
                                using: dependencies
                            )
                        }
                        
                        numInteractions = mockStorage.read(using: dependencies) { db in
                            try Interaction.fetchCount(db)
                        }
                        expect(numInteractions).to(equal(1))
                    }
                }
                
                // MARK: ---- containing a deleteAttachmentsBefore timestamp
                context("containing a deleteAttachmentsBefore timestamp") {
                    @TestState var numInteractions: Int!
                    
                    // MARK: ------ deletes messages with attachments before the timestamp
                    it("deletes messages with attachments before the timestamp") {
                        mockStorage.write(using: dependencies) { db in
                            try SessionThread.fetchOrCreate(
                                db,
                                id: groupId.hexString,
                                variant: .contact,
                                shouldBeVisible: true,
                                calledFromConfigHandling: false,
                                using: dependencies
                            )
                            let interaction: Interaction = try Interaction(
                                serverHash: "1234",
                                threadId: groupId.hexString,
                                authorId: "4321",
                                variant: .standardIncoming,
                                timestampMs: 100000000
                            ).inserted(db)
                            _ = try Attachment(
                                id: "AttachmentId",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction.id!,
                                attachmentId: "AttachmentId"
                            ).inserted(db)
                        }
                        
                        var cGroupId: [CChar] = groupId.hexString.cArray
                        state_mutate_group(stateManager.state, &cGroupId, { mutable_state, ctx in
                            state_set_group_attach_delete_before(mutable_state, 123456)
                        }, nil)
                        
                        mockStorage.write(using: dependencies) { db in
                            try LibSession.handleGroupInfoUpdate(
                                db,
                                in: stateManager.state,
                                groupSessionId: SessionId(.group, hex: groupId.hexString),
                                serverTimestampMs: 1234567891000,
                                using: dependencies
                            )
                        }
                        
                        numInteractions = mockStorage.read(using: dependencies) { db in
                            try Interaction.fetchCount(db)
                        }
                        expect(numInteractions).to(equal(0))
                    }
                    
                    // MARK: ------ schedules a garbage collection job to clean up the attachments
                    it("schedules a garbage collection job to clean up the attachments") {
                        mockStorage.write(using: dependencies) { db in
                            try SessionThread.fetchOrCreate(
                                db,
                                id: groupId.hexString,
                                variant: .contact,
                                shouldBeVisible: true,
                                calledFromConfigHandling: false,
                                using: dependencies
                            )
                            let interaction: Interaction = try Interaction(
                                serverHash: "1234",
                                threadId: groupId.hexString,
                                authorId: "4321",
                                variant: .standardIncoming,
                                timestampMs: 100000000
                            ).inserted(db)
                            _ = try Attachment(
                                id: "AttachmentId",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction.id!,
                                attachmentId: "AttachmentId"
                            ).inserted(db)
                        }
                        
                        var cGroupId: [CChar] = groupId.hexString.cArray
                        state_mutate_group(stateManager.state, &cGroupId, { mutable_state, ctx in
                            state_set_group_attach_delete_before(mutable_state, 123456)
                        }, nil)
                        
                        mockStorage.write(using: dependencies) { db in
                            try LibSession.handleGroupInfoUpdate(
                                db,
                                in: stateManager.state,
                                groupSessionId: SessionId(.group, hex: groupId.hexString),
                                serverTimestampMs: 1234567891000,
                                using: dependencies
                            )
                        }
                        
                        expect(mockJobRunner)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { jobRunner in
                                jobRunner.add(
                                    .any,
                                    job: Job(
                                        variant: .garbageCollection,
                                        behaviour: .runOnce,
                                        shouldBlock: false,
                                        shouldBeUnique: false,
                                        shouldSkipLaunchBecomeActive: false,
                                        details: GarbageCollectionJob.Details(
                                            typesToCollect: [.orphanedAttachments, .orphanedAttachmentFiles]
                                        )
                                    ),
                                    canStartJob: true,
                                    using: .any
                                )
                            })
                    }
                    
                    // MARK: ------ does not delete messages with attachments after the timestamp
                    it("does not delete messages with attachments after the timestamp") {
                        mockStorage.write(using: dependencies) { db in
                            try SessionThread.fetchOrCreate(
                                db,
                                id: groupId.hexString,
                                variant: .contact,
                                shouldBeVisible: true,
                                calledFromConfigHandling: false,
                                using: dependencies
                            )
                            let interaction1: Interaction = try Interaction(
                                serverHash: "1234",
                                threadId: groupId.hexString,
                                authorId: "4321",
                                variant: .standardIncoming,
                                timestampMs: 100000000
                            ).inserted(db)
                            let interaction2: Interaction = try Interaction(
                                serverHash: "1235",
                                threadId: groupId.hexString,
                                authorId: "4321",
                                variant: .standardIncoming,
                                timestampMs: 200000000
                            ).inserted(db)
                            _ = try Attachment(
                                id: "AttachmentId",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try Attachment(
                                id: "AttachmentId2",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction1.id!,
                                attachmentId: "AttachmentId"
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction2.id!,
                                attachmentId: "AttachmentId2"
                            ).inserted(db)
                        }
                        
                        var cGroupId: [CChar] = groupId.hexString.cArray
                        state_mutate_group(stateManager.state, &cGroupId, { mutable_state, ctx in
                            state_set_group_attach_delete_before(mutable_state, 123456)
                        }, nil)
                        
                        mockStorage.write(using: dependencies) { db in
                            try LibSession.handleGroupInfoUpdate(
                                db,
                                in: stateManager.state,
                                groupSessionId: SessionId(.group, hex: groupId.hexString),
                                serverTimestampMs: 1234567891000,
                                using: dependencies
                            )
                        }
                        
                        numInteractions = mockStorage.read(using: dependencies) { db in
                            try Interaction.fetchCount(db)
                        }
                        expect(numInteractions).to(equal(1))
                    }
                    
                    // MARK: ------ does not delete messages before the timestamp that have no attachments
                    it("does not delete messages before the timestamp that have no attachments") {
                        mockStorage.write(using: dependencies) { db in
                            try SessionThread.fetchOrCreate(
                                db,
                                id: groupId.hexString,
                                variant: .contact,
                                shouldBeVisible: true,
                                calledFromConfigHandling: false,
                                using: dependencies
                            )
                            let interaction1: Interaction = try Interaction(
                                serverHash: "1234",
                                threadId: groupId.hexString,
                                authorId: "4321",
                                variant: .standardIncoming,
                                timestampMs: 100000000
                            ).inserted(db)
                            _ = try Interaction(
                                serverHash: "1235",
                                threadId: groupId.hexString,
                                authorId: "4321",
                                variant: .standardIncoming,
                                timestampMs: 200000000
                            ).inserted(db)
                            _ = try Attachment(
                                id: "AttachmentId",
                                variant: .standard,
                                contentType: "Test",
                                byteCount: 1234
                            ).inserted(db)
                            _ = try InteractionAttachment(
                                albumIndex: 1,
                                interactionId: interaction1.id!,
                                attachmentId: "AttachmentId"
                            ).inserted(db)
                        }
                        
                        var cGroupId: [CChar] = groupId.hexString.cArray
                        state_mutate_group(stateManager.state, &cGroupId, { mutable_state, ctx in
                            state_set_group_attach_delete_before(mutable_state, 123456)
                        }, nil)
                        
                        mockStorage.write(using: dependencies) { db in
                            try LibSession.handleGroupInfoUpdate(
                                db,
                                in: stateManager.state,
                                groupSessionId: SessionId(.group, hex: groupId.hexString),
                                serverTimestampMs: 1234567891000,
                                using: dependencies
                            )
                        }
                        
                        numInteractions = mockStorage.read(using: dependencies) { db in
                            try Interaction.fetchCount(db)
                        }
                        expect(numInteractions).to(equal(1))
                    }
                }
                
                // MARK: ---- deletes from the server after deleting messages before a given timestamp
                it("deletes from the server after deleting messages before a given timestamp") {
                    mockStorage.write(using: dependencies) { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .contact,
                            shouldBeVisible: true,
                            calledFromConfigHandling: false,
                            using: dependencies
                        )
                        _ = try Interaction(
                            serverHash: "1234",
                            threadId: groupId.hexString,
                            authorId: "4321",
                            variant: .standardIncoming,
                            timestampMs: 100000000
                        ).inserted(db)
                    }
                    
                    var cGroupId: [CChar] = groupId.hexString.cArray
                    state_mutate_group(stateManager.state, &cGroupId, { mutable_state, ctx in
                        state_set_group_delete_before(mutable_state, 123456)
                    }, nil)
                    
                    mockStorage.write(using: dependencies) { db in
                        try LibSession.handleGroupInfoUpdate(
                            db,
                            in: stateManager.state,
                            groupSessionId: SessionId(.group, hex: groupId.hexString),
                            serverTimestampMs: 1234567891000,
                            using: dependencies
                        )
                    }
                    
                    let expectedRequest: URLRequest = try SnodeAPI
                        .preparedDeleteMessages(
                            serverHashes: ["1234"],
                            requireSuccessfulDeletion: false,
                            authMethod: Authentication.groupAdmin(
                                groupSessionId: groupId,
                                ed25519SecretKey: Array(groupSecretKey!)
                            ),
                            using: dependencies
                        )
                        .request
                    expect(mockNetwork)
                        .to(call(.exactly(times: 1), matchingParameters: .all) { [dependencies = dependencies!] network in
                            network.send(
                                .selectedNetworkRequest(
                                    expectedRequest.httpBody!,
                                    to: dependencies.randomElement(mockSwarmCache)!,
                                    timeout: HTTP.defaultTimeout,
                                    using: .any
                                )
                            )
                        })
                }
                
                // MARK: ---- does not delete from the server if there is no server hash
                it("does not delete from the server if there is no server hash") {
                    mockStorage.write(using: dependencies) { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .contact,
                            shouldBeVisible: true,
                            calledFromConfigHandling: false,
                            using: dependencies
                        )
                        _ = try Interaction(
                            threadId: groupId.hexString,
                            authorId: "4321",
                            variant: .standardIncoming,
                            timestampMs: 100000000
                        ).inserted(db)
                    }
                    
                    var cGroupId: [CChar] = groupId.hexString.cArray
                    state_mutate_group(stateManager.state, &cGroupId, { mutable_state, ctx in
                        state_set_group_delete_before(mutable_state, 123456)
                    }, nil)
                    
                    mockStorage.write(using: dependencies) { db in
                        try LibSession.handleGroupInfoUpdate(
                            db,
                            in: stateManager.state,
                            groupSessionId: SessionId(.group, hex: groupId.hexString),
                            serverTimestampMs: 1234567891000,
                            using: dependencies
                        )
                    }
                    
                    let numInteractions: Int? = mockStorage.read(using: dependencies) { db in
                        try Interaction.fetchCount(db)
                    }
                    expect(numInteractions).to(equal(0))
                    expect(mockNetwork)
                        .toNot(call { network in
                            network.send(.selectedNetworkRequest(.any, to: .any, timeout: .any, using: .any))
                        })
                }
            }
        }
    }
}
