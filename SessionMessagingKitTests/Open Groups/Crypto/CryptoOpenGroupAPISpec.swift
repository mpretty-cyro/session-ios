// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class CryptoOpenGroupAPISpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self,
                SNMessagingKit.self
            ],
            using: dependencies,
            initialData: { db in
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            }
        )
        @TestState(singleton: .crypto, in: dependencies) var crypto: Crypto! = Crypto()
        @TestState var mockCrypto: MockCrypto! = MockCrypto()
        
        // MARK: - Crypto for OpenGroupAPI
        describe("Crypto for OpenGroupAPI") {
            // MARK: -- when generating a blinded15 key pair
            context("when generating a blinded15 key pair") {
                // MARK: ---- successfully generates a blinded key pair
                it("successfully generates a blinded key pair") {
                    let result = crypto.generate(
                        .blindedKeyPair(
                            serverPublicKey: TestConstants.serverPublicKey,
                            edKeyPair: KeyPair(
                                publicKey: Data(hex: TestConstants.edPublicKey).bytes,
                                secretKey: Data(hex: TestConstants.edSecretKey).bytes
                            ),
                            using: dependencies
                        )
                    )
                    
                    // Note: The first 64 characters of the secretKey are consistent but the chars after that always differ
                    expect(result?.publicKey.toHexString()).to(equal(TestConstants.blindedPublicKey))
                    expect(String(result?.secretKey.toHexString().prefix(64) ?? ""))
                        .to(equal("16663322d6b684e1c9dcc02b9e8642c3affd3bc431a9ea9e63dbbac88ce7a305"))
                }
                
                // MARK: ---- fails if the edKeyPair public key length wrong
                it("fails if the edKeyPair public key length wrong") {
                    let result = crypto.generate(
                        .blindedKeyPair(
                            serverPublicKey: TestConstants.serverPublicKey,
                            edKeyPair: KeyPair(
                                publicKey: Data(hex: String(TestConstants.edPublicKey.prefix(4))).bytes,
                                secretKey: Data(hex: TestConstants.edSecretKey).bytes
                            ),
                            using: dependencies
                        )
                    )
                    
                    expect(result).to(beNil())
                }
                
                // MARK: ---- fails if the edKeyPair secret key length wrong
                it("fails if the edKeyPair secret key length wrong") {
                    let result = crypto.generate(
                        .blindedKeyPair(
                            serverPublicKey: TestConstants.serverPublicKey,
                            edKeyPair: KeyPair(
                                publicKey: Data(hex: TestConstants.edPublicKey).bytes,
                                secretKey: Data(hex: String(TestConstants.edSecretKey.prefix(4))).bytes
                            ),
                            using: dependencies
                        )
                    )
                    
                    expect(result).to(beNil())
                }
                
                // MARK: ---- fails if it cannot generate a blinding factor
                it("fails if it cannot generate a blinding factor") {
                    let result = crypto.generate(
                        .blindedKeyPair(
                            serverPublicKey: "Test",
                            edKeyPair: KeyPair(
                                publicKey: Data(hex: TestConstants.edPublicKey).bytes,
                                secretKey: Data(hex: TestConstants.edSecretKey).bytes
                            ),
                            using: dependencies
                        )
                    )
                    
                    expect(result).to(beNil())
                }
            }
            
            // MARK: -- when generating a signatureBlind15
            context("when generating a signatureBlind15") {
                // MARK: ---- generates a correct signature
                it("generates a correct signature") {
                    let result = crypto.generate(
                        .signatureSOGS(
                            message: "TestMessage".bytes,
                            secretKey: Data(hex: TestConstants.edSecretKey).bytes,
                            blindedSecretKey: Data(hex: "44d82cc15c0a5056825cae7520b6b52d000a23eb0c5ed94c4be2d9dc41d2d409").bytes,
                            blindedPublicKey: Data(hex: "0bb7815abb6ba5142865895f3e5286c0527ba4d31dbb75c53ce95e91ffe025a2").bytes
                        )
                    )
                    
                    expect(result?.toHexString())
                        .to(equal(
                            "dcc086abdd2a740d9260b008fb37e12aa0ff47bd2bd9e177bbbec37fd46705a9" +
                            "072ce747bda66c788c3775cdd7ad60ad15a478e0886779aad5d795fd7bf8350d"
                        ))
                }
            }
            
            // MARK: -- when checking if a session id matches a blinded id
            context("when checking if a session id matches a blinded id") {
                // MARK: ---- returns true when they match
                it("returns true when they match") {
                    let result = crypto.verify(
                        .sessionId(
                            "05\(TestConstants.publicKey)",
                            matchesBlindedId: "15\(TestConstants.blindedPublicKey)",
                            serverPublicKey: TestConstants.serverPublicKey,
                            using: dependencies
                        )
                    )
                    
                    expect(result).to(beTrue())
                }
                
                // MARK: ---- returns false if given an invalid session id
                it("returns false if given an invalid session id") {
                    let result = crypto.verify(
                        .sessionId(
                            "AB\(TestConstants.publicKey)",
                            matchesBlindedId: "15\(TestConstants.blindedPublicKey)",
                            serverPublicKey: TestConstants.serverPublicKey,
                            using: dependencies
                        )
                    )
                    
                    expect(result).to(beFalse())
                }
                
                // MARK: ---- returns false if given an invalid blinded id
                it("returns false if given an invalid blinded id") {
                    let result = crypto.verify(
                        .sessionId(
                            "05\(TestConstants.publicKey)",
                            matchesBlindedId: "AB\(TestConstants.blindedPublicKey)",
                            serverPublicKey: TestConstants.serverPublicKey,
                            using: dependencies
                        )
                    )
                    
                    expect(result).to(beFalse())
                }
                
                // MARK: ---- returns false if it fails to generate the blinding factor
                it("returns false if it fails to generate the blinding factor") {
                    let result = crypto.verify(
                        .sessionId(
                            "05\(TestConstants.publicKey)",
                            matchesBlindedId: "15\(TestConstants.blindedPublicKey)",
                            serverPublicKey: "Test",
                            using: dependencies
                        )
                    )
                    
                    expect(result).to(beFalse())
                }
            }
            
            // MARK: -- when encrypting with the session blinding protocol
            context("when encrypting with the session blinding protocol") {
                beforeEach {
                    mockCrypto
                        .when { $0.generate(.blindedKeyPair(serverPublicKey: .any, edKeyPair: .any, using: .any)) }
                        .thenReturn(
                            KeyPair(
                                publicKey: Data(hex: TestConstants.publicKey).bytes,
                                secretKey: Data(hex: TestConstants.edSecretKey).bytes
                            )
                        )
                    mockCrypto
                        .when {
                            $0.generate(
                                .sharedBlindedEncryptionKey(
                                    secretKey: .any,
                                    otherBlindedPublicKey: .any,
                                    fromBlindedPublicKey: .any,
                                    toBlindedPublicKey: .any,
                                    using: .any
                                )
                            )
                        }
                        .thenReturn([1, 2, 3])
                    mockCrypto
                        .when {
                            $0.generate(
                                .encryptedBytesAeadXChaCha20(
                                    message: .any,
                                    secretKey: .any,
                                    nonce: .any,
                                    additionalData: .any,
                                    using: .any
                                )
                            )
                        }
                        .thenReturn([2, 3, 4])
                }
                
                // MARK: ---- can encrypt for a blind15 recipient correctly
                it("can encrypt for a blind15 recipient correctly") {
                    let result: Data? = mockStorage.read { db in
                        try crypto.tryGenerate(
                            .ciphertextWithSessionBlindingProtocol(
                                db,
                                plaintext: "TestMessage".data(using: .utf8)!,
                                recipientBlindedId: "15\(TestConstants.blindedPublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        )
                    }
                    
                    // Note: A Nonce is used for this so we can't compare the exact value when not mocked
                    expect(result).toNot(beNil())
                    expect(result?.count).to(equal(84))
                }
                
                // MARK: ---- can encrypt for a blind25 recipient correctly
                it("can encrypt for a blind25 recipient correctly") {
                    let result: Data? = mockStorage.read { db in
                        try crypto.tryGenerate(
                            .ciphertextWithSessionBlindingProtocol(
                                db,
                                plaintext: "TestMessage".data(using: .utf8)!,
                                recipientBlindedId: "25\(TestConstants.blindedPublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        )
                    }
                    
                    // Note: A Nonce is used for this so we can't compare the exact value when not mocked
                    expect(result).toNot(beNil())
                    expect(result?.count).to(equal(84))
                }
                
                // MARK: ---- includes a version at the start of the encrypted value
                it("includes a version at the start of the encrypted value") {
                    let result: Data? = mockStorage.read { db in
                        try crypto.tryGenerate(
                            .ciphertextWithSessionBlindingProtocol(
                                db,
                                plaintext: "TestMessage".data(using: .utf8)!,
                                recipientBlindedId: "15\(TestConstants.blindedPublicKey)",
                                serverPublicKey: TestConstants.serverPublicKey,
                                using: dependencies
                            )
                        )
                    }
                    
                    expect(result?.toHexString().prefix(2)).to(equal("00"))
                }
                
                // MARK: ---- throws an error if the recipient isn't a blinded id
                it("throws an error if the recipient isn't a blinded id") {
                    mockStorage.read { db in
                        expect {
                            try crypto.tryGenerate(
                                .ciphertextWithSessionBlindingProtocol(
                                    db,
                                    plaintext: "TestMessage".data(using: .utf8)!,
                                    recipientBlindedId: "05\(TestConstants.publicKey)",
                                    serverPublicKey: TestConstants.serverPublicKey,
                                    using: dependencies
                                )
                            )
                        }
                        .to(throwError(MessageSenderError.encryptionFailed))
                    }
                }
                
                // MARK: ---- throws an error if there is no ed25519 keyPair
                it("throws an error if there is no ed25519 keyPair") {
                    mockStorage.write { db in
                        _ = try Identity.filter(id: .ed25519PublicKey).deleteAll(db)
                        _ = try Identity.filter(id: .ed25519SecretKey).deleteAll(db)
                    }
                    
                    mockStorage.read { db in
                        expect {
                            try crypto.tryGenerate(
                                .ciphertextWithSessionBlindingProtocol(
                                    db,
                                    plaintext: "TestMessage".data(using: .utf8)!,
                                    recipientBlindedId: "15\(TestConstants.blindedPublicKey)",
                                    serverPublicKey: TestConstants.serverPublicKey,
                                    using: dependencies
                                )
                            )
                        }
                        .to(throwError(MessageSenderError.noUserED25519KeyPair))
                    }
                }
            }
            
            // MARK: -- when decrypting with the session blinding protocol
            context("when decrypting with the session blinding protocol") {
                // MARK: ---- successfully decrypts a message
                it("successfully decrypts a message") {
                    let result = try? MessageReceiver.decryptWithSessionProtocol(
                        ciphertext: Data(
                            base64Encoded: "SRP0eBUWh4ez6ppWjUs5/Wph5fhnPRgB5zsWWnTz+FBAw/YI3oS2pDpIfyetMTbU" +
                            "sFMhE5G4PbRtQFey1hsxLl221Qivc3ayaX2Mm/X89Dl8e45BC+Lb/KU9EdesxIK4pVgYXs9XrMtX3v8" +
                            "dt0eBaXneOBfr7qB8pHwwMZjtkOu1ED07T9nszgbWabBphUfWXe2U9K3PTRisSCI="
                        )!,
                        using: KeyPair(
                            publicKey: Data(hex: TestConstants.publicKey).bytes,
                            secretKey: Data(hex: TestConstants.privateKey).bytes
                        ),
                        using: Dependencies()   // Don't mock
                    )
                    
                    expect(String(data: (result?.plaintext ?? Data()), encoding: .utf8)).to(equal("TestMessage"))
                    expect(result?.senderX25519PublicKey)
                        .to(equal("0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                }
            }
        }
    }
}
