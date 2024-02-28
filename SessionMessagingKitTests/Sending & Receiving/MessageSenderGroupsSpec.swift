// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit
@testable import SessionSnodeKit

class MessageSenderGroupsSpec: QuickSpec {
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
                
                try Profile(
                    id: "05\(TestConstants.publicKey)",
                    name: "TestCurrentUser"
                ).insert(db)
            }
        )
        @TestState(defaults: .standard, in: dependencies) var mockUserDefaults: MockUserDefaults! = MockUserDefaults(
            initialSetup: { userDefaults in
                userDefaults.when { $0.string(forKey: .any) }.thenReturn(nil)
            }
        )
        @TestState(singleton: .jobRunner, in: dependencies) var mockJobRunner: MockJobRunner! = MockJobRunner(
            initialSetup: { jobRunner in
                jobRunner
                    .when { $0.jobInfoFor(jobs: .any, state: .any, variant: .any) }
                    .thenReturn([:])
                jobRunner
                    .when { $0.add(.any, job: .any, dependantJob: .any, canStartJob: .any, using: .any) }
                    .thenReturn(nil)
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork(
            initialSetup: { network in
                network
                    .when { $0.send(.selectedNetworkRequest(.any, to: .any, timeout: .any, using: .any)) }
                    .thenReturn(HTTP.BatchResponse.mockConfigSyncResponse)
                network
                    .when { $0.send(.selectedNetworkRequest(.any, to: .any, with: .any, timeout: .any, using: .any)) }
                    .thenReturn(MockNetwork.response(with: FileUploadResponse(id: "1")))
            }
        )
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto
                    .when { $0.generate(.ed25519KeyPair()) }
                    .thenReturn(
                        KeyPair(
                            publicKey: Data(hex: groupId.hexString).bytes,
                            secretKey: groupSecretKey.bytes
                        )
                    )
                crypto
                    .when { $0.generate(.signature(message: .any, ed25519SecretKey: .any)) }
                    .thenReturn(Authentication.Signature.standard(signature: "TestSignature".bytes))
                crypto
                    .when { $0.generate(.memberAuthData(groupSessionId: .any, memberId: .any, using: .any)) }
                    .thenReturn(Authentication.Info.groupMember(
                        groupSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                        authData: "TestAuthData".data(using: .utf8)!
                    ))
                crypto
                    .when { $0.generate(.tokenSubaccount(groupSessionId: .any, memberId: .any, using: .any)) }
                    .thenReturn(Array("TestSubAccountToken".data(using: .utf8)!))
                crypto
                    .when { $0.generate(.randomBytes(.any)) }
                    .thenReturn(Data((0..<DisplayPictureManager.aes256KeyByteLength).map { _ in 1 }))
                crypto
                    .when { $0.generate(.uuid()) }
                    .thenReturn(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
                crypto
                    .when { $0.generate(.encryptedDataDisplayPicture(data: .any, key: .any, using: .any)) }
                    .thenReturn(TestConstants.validImageData)
            }
        )
        @TestState(singleton: .keychain, in: dependencies) var mockKeychain: MockKeychain! = MockKeychain(
            initialSetup: { keychain in
                keychain
                    .when { try $0.data(forService: .pushNotificationAPI, key: .pushNotificationEncryptionKey) }
                    .thenReturn(Data((0..<PushNotificationAPI.encryptionKeyLength).map { _ in 1 }))
            }
        )
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
            }
        )
        @TestState(singleton: .libSession, in: dependencies) var mockStateManager: MockStateManager! = MockStateManager(
            initialSetup: { stateManager in
                stateManager
                    .when { stateManager in
                        stateManager.createGroup(
                            name: .any,
                            description: .any,
                            displayPictureUrl: .any,
                            displayPictureEncryptionKey: .any,
                            members: .any,
                            callback: { _, _, _ in }
                        )
                    }
                    .then { _, untrackedArgs in
                        let callback = untrackedArgs[0] as! ((String, [UInt8], LibSessionError?) -> Void)
                        callback(groupId.hexString, Array(groupSecretKey), nil)
                    }
                    .thenReturn(nil)
                stateManager
                    .when { stateManager in
                        stateManager.addGroupMembers(
                            groupSessionId: .any,
                            allowAccessToHistoricMessages: .any,
                            members: .any,
                            callback: { _ in }
                        )
                    }
                    .then { _, untrackedArgs in
                        let callback = untrackedArgs[0] as! ((LibSessionError?) -> Void)
                        callback(nil)
                    }
                    .thenReturn(nil)
            }
        )
        @TestState var stateManager: LibSession.StateManager! = { [dependencies, mockStorage] in
            mockStorage!.read { db in
                let result = try LibSession.StateManager(db, using: dependencies!)
                MockStateManager.registerFakeResponse(for: result.state)
                return result
            }
        }()
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
        @TestState(singleton: .groupsPoller, in: dependencies) var mockGroupsPoller: MockPoller! = MockPoller(
            initialSetup: { poller in
                poller
                    .when { $0.startIfNeeded(for: .any, using: .any) }
                    .thenReturn(())
            }
        )
        @TestState var disposables: [AnyCancellable]! = []
        @TestState var error: Error?
        @TestState var thread: SessionThread?
        
        // MARK: - a MessageSender dealing with Groups
        describe("a MessageSender dealing with Groups") {
            // MARK: -- when creating a group
            context("when creating a group") {
                // MARK: ---- creates the group via the state manager
                it("creates the group via the state manager") {
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .sinkAndStore(in: &disposables)
                    
                    expect(mockStateManager)
                        .to(call(.exactly(times: 1), matchingParameters: .all) { state in
                            state.createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureUrl: nil,
                                displayPictureEncryptionKey: nil,
                                members: [(
                                    "051111111111111111111111111111111111111111111111111111111111111111",
                                    name: nil,
                                    picUrl: nil,
                                    picEncKey: nil
                                )],
                                callback: { _, _, _ in }
                            )
                        })
                }
                
                // MARK: ---- returns the created thread
                it("returns the created thread") {
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .handleEvents(receiveOutput: { result in thread = result })
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(error).to(beNil())
                    expect(thread).toNot(beNil())
                    expect(thread?.id).to(equal(groupId.hexString))
                    expect(thread?.variant).to(equal(.group))
                    expect(thread?.creationDateTimestamp).to(equal(1234567890))
                    expect(thread?.shouldBeVisible).to(beTrue())
                    expect(thread?.messageDraft).to(beNil())
                    expect(thread?.markedAsUnread).to(beFalse())
                    expect(thread?.pinnedPriority).to(equal(0))
                }
                
                // MARK: ---- stores the thread in the db
                it("stores the thread in the db") {
                    MessageSender
                        .createGroup(
                            name: "Test",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .handleEvents(receiveOutput: { result in thread = result })
                        .sinkAndStore(in: &disposables)
                    
                    let dbValue: SessionThread? = mockStorage.read { db in try SessionThread.fetchOne(db) }
                    expect(dbValue).to(equal(thread))
                    expect(dbValue?.id).to(equal(groupId.hexString))
                    expect(dbValue?.variant).to(equal(.group))
                    expect(dbValue?.creationDateTimestamp).to(equal(1234567890))
                    expect(dbValue?.shouldBeVisible).to(beTrue())
                    expect(dbValue?.notificationSound).to(beNil())
                    expect(dbValue?.mutedUntilTimestamp).to(beNil())
                    expect(dbValue?.onlyNotifyForMentions).to(beFalse())
                    expect(dbValue?.pinnedPriority).to(equal(0))
                }
                
                // MARK: ---- starts the group poller
                it("starts the group poller") {
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .sinkAndStore(in: &disposables)
                    
                    expect(mockGroupsPoller)
                        .to(call(.exactly(times: 1), matchingParameters: .all) { poller in
                            poller.startIfNeeded(for: groupId.hexString, using: .any)
                        })
                }
                
                // MARK: ---- sends the group configuration messages
                it("sends the group configuration messages") {
                    expect { try stateManager.registerHooks() }.toNot(throwError())
                    dependencies.set(singleton: .libSession, to: stateManager)
                    
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .sinkAndStore(in: &disposables)
                    
                    expect(mockNetwork)
                        .to(call(.exactly(times: 1)) { network in
                            network.send(
                                .selectedNetworkRequest(
                                    .any,
                                    to: dependencies.randomElement(mockSwarmCache)!,
                                    timeout: HTTP.defaultTimeout,
                                    using: .any
                                )
                            )
                        })
                }
                
                // MARK: ---- and the group configuration send fails
                context("and the group configuration send fails") {
                    beforeEach {
                        expect { try stateManager.registerHooks() }.toNot(throwError())
                        dependencies.set(singleton: .libSession, to: stateManager)
                        
                        mockNetwork
                            .when { $0.send(.selectedNetworkRequest(.any, to: .any, timeout: .any, using: .any)) }
                            .thenReturn(MockNetwork.errorResponse())
                    }
                    
                    // MARK: ------ throws an error
                    it("throws an error") {
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error).to(matchError(LibSessionError.libSessionError("Failed with status code: 65535.")))
                    }
                    
                    // MARK: ------ does not add anything to the database
                    it("does not add anything to the database") {
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        let threads: [SessionThread]? = mockStorage.read { db in try SessionThread.fetchAll(db) }
                        let groups: [ClosedGroup]? = mockStorage.read { db in try ClosedGroup.fetchAll(db) }
                        let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                        
                        expect(threads).to(beEmpty())
                        expect(groups).to(beEmpty())
                        expect(members).to(beEmpty())
                    }
                }
                
                // MARK: ------ does not upload an image if none is provided
                it("does not upload an image if none is provided") {
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)
                    
                    let expectedRequest: URLRequest = try FileServerAPI
                        .preparedUpload(TestConstants.validImageData, using: dependencies)
                        .request
                    
                    expect(mockNetwork)
                        .toNot(call { network in
                            network.send(
                                .selectedNetworkRequest(
                                    expectedRequest,
                                    to: FileServerAPI.server,
                                    with: FileServerAPI.serverPublicKey,
                                    timeout: FileServerAPI.fileUploadTimeout,
                                    using: .any
                                )
                            )
                        })
                }
                
                // MARK: ------ with an image
                context("with an image") {
                    // MARK: ------ uploads the image
                    it("uploads the image") {
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: TestConstants.validImageData,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        let expectedRequest: URLRequest = try FileServerAPI
                            .preparedUpload(TestConstants.validImageData, using: dependencies)
                            .request
                        
                        expect(mockNetwork)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { network in
                                network.send(
                                    .selectedNetworkRequest(
                                        expectedRequest,
                                        to: FileServerAPI.server,
                                        with: FileServerAPI.serverPublicKey,
                                        timeout: FileServerAPI.fileUploadTimeout,
                                        using: .any
                                    )
                                )
                            })
                    }
                    
                    // MARK: ------ saves the image info to the group
                    it("saves the image info to the group") {
                        MockStateManager.registerFakeResponse(for: stateManager.state)
                        dependencies.set(singleton: .libSession, to: stateManager)
                        
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: TestConstants.validImageData,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        let threads: [SessionThread] = (mockStorage.read { db in try SessionThread.fetchAll(db) } ?? [])
                        var cGroupId: [CChar] = threads[0].id.cArray
                        var cPic: user_profile_pic = user_profile_pic()
                        expect(state_get_group_pic(stateManager.state, &cGroupId, &cPic)).to(beTrue())
                        expect(String(libSessionVal: cPic.url)).to(equal("http://filev2.getsession.org/file/1"))
                    }
                    
                    // MARK: ------ fails if the image fails to upload
                    it("fails if the image fails to upload") {
                        mockNetwork
                            .when { $0.send(.selectedNetworkRequest(.any, to: .any, with: .any, timeout: .any, using: .any)) }
                            .thenReturn(Fail(error: HTTPError.generic).eraseToAnyPublisher())
                        
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: TestConstants.validImageData,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error).to(matchError(DisplayPictureError.uploadFailed))
                    }
                }
                
                // MARK: ---- schedules member invite jobs
                it("schedules member invite jobs") {
                    // Since we don't have proper 'stateManager' hooks setup the data from 'createGroup' won't be
                    // properly created in the database so we need to force create it
                    mockStorage.write { db in
                        try SessionThread.fetchOrCreate(
                            db,
                            id: groupId.hexString,
                            variant: .group,
                            shouldBeVisible: true,
                            calledFromConfigHandling: false,
                            using: dependencies
                        )
                        
                        try GroupMember(
                            groupId: groupId.hexString,
                            profileId: "051111111111111111111111111111111111111111111111111111111111111111",
                            role: .standard,
                            roleStatus: .pending,
                            isHidden: false
                        ).upsert(db)
                    }
                    
                    MessageSender
                        .createGroup(
                            name: "TestGroupName",
                            description: nil,
                            displayPictureData: nil,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                            ],
                            using: dependencies
                        )
                        .sinkAndStore(in: &disposables)
                    
                    expect(mockJobRunner)
                        .to(call(.exactly(times: 1), matchingParameters: .all) { jobRunner in
                            jobRunner.add(
                                .any,
                                job: Job(
                                    variant: .groupInviteMember,
                                    threadId: groupId.hexString,
                                    details: try? GroupInviteMemberJob.Details(
                                        memberSessionIdHexString: "051111111111111111111111111111111111111111111111111111111111111111",
                                        authInfo: .groupMember(
                                            groupSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                            authData: "TestAuthData".data(using: .utf8)!
                                        )
                                    )
                                ),
                                dependantJob: nil,
                                canStartJob: true,
                                using: .any
                            )
                        })
                }
                
                // MARK: ------ and trying to subscribe for push notifications
                context("and trying to subscribe for push notifications") {
                    // MARK: ---- subscribes when they are enabled
                    it("subscribes when they are enabled") {
                        // Since we don't have proper 'stateManager' hooks setup the data from 'createGroup' won't be
                        // properly created in the database so we need to force create it
                        mockStorage.write { db in
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
                                name: "TestGroup",
                                formationTimestamp: 1234567890,
                                shouldPoll: true,
                                groupIdentityPrivateKey: groupSecretKey,
                                authData: nil,
                                invited: false
                            ).upsert(db)
                        }
                        mockUserDefaults
                            .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                            .thenReturn(Data([5, 4, 3, 2, 1]).toHexString())
                        mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                            .thenReturn(true)
                        
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .sinkAndStore(in: &disposables)
                        
                        let expectedRequest: URLRequest? = mockStorage.read(using: dependencies) { db in
                            try PushNotificationAPI
                                .preparedSubscribe(
                                    db,
                                    token: Data([5, 4, 3, 2, 1]),
                                    sessionIds: [groupId],
                                    using: dependencies
                                )
                                .request
                        }
                        
                        expect(expectedRequest).toNot(beNil())
                        expect(mockNetwork)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { network in
                                expectedRequest.map {
                                    network.send(
                                        .selectedNetworkRequest(
                                            $0,
                                            to: PushNotificationAPI.server.value(using: dependencies),
                                            with: PushNotificationAPI.serverPublicKey,
                                            timeout: HTTP.defaultTimeout,
                                            using: .any
                                        )
                                    )
                                }
                            })
                    }
                    
                    // MARK: ---- does not subscribe if push notifications are disabled
                    it("does not subscribe if push notifications are disabled") {
                        mockUserDefaults
                            .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                            .thenReturn(Data([5, 4, 3, 2, 1]).toHexString())
                        mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                            .thenReturn(false)
                        
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .sinkAndStore(in: &disposables)
                        
                        expect(mockNetwork)
                            .toNot(call { network in
                                network.send(
                                    .selectedNetworkRequest(
                                        .any,
                                        to: PushNotificationAPI.server.value(using: dependencies),
                                        with: PushNotificationAPI.serverPublicKey,
                                        timeout: HTTP.defaultTimeout,
                                        using: .any
                                    )
                                )
                            })
                    }
                    
                    // MARK: ---- does not subscribe if there is no push token
                    it("does not subscribe if there is no push token") {
                        mockUserDefaults
                            .when { $0.string(forKey: UserDefaults.StringKey.deviceToken.rawValue) }
                            .thenReturn(nil)
                        mockUserDefaults
                            .when { $0.bool(forKey: UserDefaults.BoolKey.isUsingFullAPNs.rawValue) }
                            .thenReturn(true)
                        
                        MessageSender
                            .createGroup(
                                name: "TestGroupName",
                                description: nil,
                                displayPictureData: nil,
                                members: [
                                    ("051111111111111111111111111111111111111111111111111111111111111111", nil)
                                ],
                                using: dependencies
                            )
                            .sinkAndStore(in: &disposables)
                        
                        expect(mockNetwork)
                            .toNot(call { network in
                                network.send(
                                    .selectedNetworkRequest(
                                        .any,
                                        to: PushNotificationAPI.server.value(using: dependencies),
                                        with: PushNotificationAPI.serverPublicKey,
                                        timeout: HTTP.defaultTimeout,
                                        using: .any
                                    )
                                )
                            })
                    }
                }
                
                // MARK: -- when adding members to a group
                context("when adding members to a group") {
                    beforeEach {
                        mockStorage.write { db in
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
                                name: "TestGroup",
                                formationTimestamp: 1234567890,
                                shouldPoll: true,
                                groupIdentityPrivateKey: groupSecretKey,
                                authData: nil,
                                invited: false
                            ).upsert(db)
                        }
                    }
                    
                    // MARK: ---- does nothing if the current user is not an admin
                    it("does nothing if the current user is not an admin") {
                        mockStorage.write { db in
                            try ClosedGroup
                                .updateAll(
                                    db,
                                    ClosedGroup.Columns.groupIdentityPrivateKey.set(to: nil)
                                )
                        }
                        
                        MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: false,
                            using: dependencies
                        ).sinkUntilComplete()
                        
                        let cGroupId: [CChar] = groupId.hexString.cArray
                        let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                        expect(state_size_group_members(stateManager.state, cGroupId)).to(equal(0))
                        expect(members?.count).to(equal(0))
                    }
                    
                    // MARK: ---- adds the member to the database in the sending state
                    it("adds the member to the database in the sending state") {
                        MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: false,
                            using: dependencies
                        ).sinkUntilComplete()
                        
                        let members: [GroupMember]? = mockStorage.read { db in try GroupMember.fetchAll(db) }
                        expect(members?.count).to(equal(1))
                        expect(members?.first?.profileId)
                            .to(equal("051111111111111111111111111111111111111111111111111111111111111112"))
                        expect(members?.first?.role).to(equal(.standard))
                        expect(members?.first?.roleStatus).to(equal(.sending))
                    }
                    
                    // MARK: ---- calls the unrevoke subaccounts endpoint
                    it("calls the unrevoke subaccounts endpoint") {
                        let expectedRequest: URLRequest = try SnodeAPI
                            .preparedUnrevokeSubaccounts(
                                subaccountsToUnrevoke: [Array("TestSubAccountToken".data(using: .utf8)!)],
                                authMethod: Authentication.groupAdmin(
                                    groupSessionId: groupId,
                                    ed25519SecretKey: Array(groupSecretKey)
                                ),
                                using: dependencies
                            )
                            .request
                        
                        MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: true,
                            using: dependencies
                        ).sinkUntilComplete()
                        
                        expect(mockNetwork)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { network in
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
                    
                    // MARK: ---- schedules member invite jobs
                    it("schedules member invite jobs") {
                        MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: true,
                            using: dependencies
                        ).sinkUntilComplete()
                        
                        expect(mockJobRunner)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { jobRunner in
                                jobRunner.add(
                                    .any,
                                    job: Job(
                                        variant: .groupInviteMember,
                                        threadId: groupId.hexString,
                                        details: try? GroupInviteMemberJob.Details(
                                            memberSessionIdHexString: "051111111111111111111111111111111111111111111111111111111111111112",
                                            authInfo: .groupMember(
                                                groupSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                                authData: "TestAuthData".data(using: .utf8)!
                                            )
                                        )
                                    ),
                                    dependantJob: nil,
                                    canStartJob: true,
                                    using: .any
                                )
                            })
                    }
                    
                    // MARK: ---- adds a member change control message
                    it("adds a member change control message") {
                        MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: true,
                            using: dependencies
                        ).sinkUntilComplete()
                        
                        let interactions: [Interaction]? = mockStorage.read { db in try Interaction.fetchAll(db) }
                        expect(interactions?.count).to(equal(1))
                        expect(interactions?.first?.variant).to(equal(.infoGroupMembersUpdated))
                        expect(interactions?.first?.body).to(equal(
                            ClosedGroup.MessageInfo
                                .addedUsers(names: ["0511...1112"])
                                .infoString(using: dependencies)
                        ))
                    }
                    
                    // MARK: ---- schedules sending of the member change message
                    it("schedules sending of the member change message") {
                        MessageSender.addGroupMembers(
                            groupSessionId: groupId.hexString,
                            members: [
                                ("051111111111111111111111111111111111111111111111111111111111111112", nil)
                            ],
                            allowAccessToHistoricMessages: true,
                            using: dependencies
                        ).sinkUntilComplete()
                        
                        expect(mockJobRunner)
                            .to(call(.exactly(times: 1), matchingParameters: .all) { jobRunner in
                                jobRunner.add(
                                    .any,
                                    job: Job(
                                        variant: .messageSend,
                                        threadId: groupId.hexString,
                                        interactionId: nil,
                                        details: MessageSendJob.Details(
                                            destination: .closedGroup(groupPublicKey: groupId.hexString),
                                            message: try! GroupUpdateMemberChangeMessage(
                                                changeType: .added,
                                                memberSessionIds: [
                                                    "051111111111111111111111111111111111111111111111111111111111111112"
                                                ],
                                                sentTimestamp: 1234567890000,
                                                authMethod: Authentication.groupAdmin(
                                                    groupSessionId: groupId,
                                                    ed25519SecretKey: Array(groupSecretKey)
                                                ),
                                                using: dependencies
                                            ),
                                            isSyncMessage: false
                                        )
                                    ),
                                    dependantJob: nil,
                                    canStartJob: true,
                                    using: .any
                                )
                            })
                    }
                }
            }
        }
    }
}

// MARK: - Mock Types

extension SendMessagesResponse: Mocked {
    static var mock: SendMessagesResponse = SendMessagesResponse(
        hash: "hash",
        swarm: [:],
        hardFork: [1, 2],
        timeOffset: 0
    )
}

// MARK: - Mock Batch Responses
                        
extension HTTP.BatchResponse {
    // MARK: - Valid Responses
    
    fileprivate static let mockConfigSyncResponse: AnyPublisher<(ResponseInfoType, Data?), Error> = MockNetwork.batchResponseData(
        with: [
            (SnodeAPI.Endpoint.sendMessage, SendMessagesResponse.mockBatchSubResponse()),
            (SnodeAPI.Endpoint.sendMessage, SendMessagesResponse.mockBatchSubResponse()),
            (SnodeAPI.Endpoint.sendMessage, SendMessagesResponse.mockBatchSubResponse())
        ]
    )
}
