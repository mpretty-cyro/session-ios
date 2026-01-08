// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Testing
import Foundation
import Combine
import GRDB
import SessionMessagingKit

@testable import SessionNetworkingKit
@testable import SessionUtilitiesKit

@Suite("Network Resilience Tests", .serialized)
struct MessageSendJobResilienceTests {
    var fixture: ResilienceTestFixture!
    var snodePoolCacheData: Data!
    
    init() async throws {
        fixture = try await ResilienceTestFixture.create()
        fixture.clearTestData()
        
        fixture.useLiveDateNow()
        try await fixture.createStorage()
        try await fixture.createWarmedNetwork(
            singlePathMode: true,
            customCachePath: nil,
            snodePoolCacheData: nil
        )
        
        /// We need to ensure we have a snode pool (don't want fetching the snode pool to impact the timing results of the tests) so
        /// get the swarm for a pubkey which will fetch the snode pool if it's empty
        _ = try await fixture.dependencies[singleton: .network]
            .getSwarm(for: "05\(TestConstants.publicKey)")
            .values
            .first { _ in true }
        
        snodePoolCacheData = try Data(contentsOf: URL(fileURLWithPath: "\(LibSession.NetworkCache.snodeCachePath)/snode_pool"))
    }
    
    typealias Config = ResilienceTest.Config
    
    @Test(
        "Direct Request Resilience",
        .serialized,
        arguments: [
            Config.directVariations(
                variant: .sendMessage,
                attempts: 500,
                networkModes: [.newNetworkPerRequest, .shared],
                behaviours: [
                    .concurrent(num: 500),
                    .concurrent(num: 50),
                    .staggered(delayMs: 250)
                ],
                numPaths: [2, 1]
            ),
            Config.directVariations(
                variant: .sendAttachment(fileSize: 5_000_000),
                attempts: 200,
                networkModes: [.newNetworkPerRequest, .shared],
                behaviours: [
                    .concurrent(num: 250),
                    .concurrent(num: 50),
                    .staggered(delayMs: 250)
                ],
                numPaths: [2, 1]
            ),
            Config.directVariations(
                variant: .downloadAttachment(fileSize: 5_000_000),
                attempts: 200,
                networkModes: [.newNetworkPerRequest, .shared],
                behaviours: [
                    .concurrent(num: 250),
                    .concurrent(num: 50),
                    .staggered(delayMs: 250)
                ],
                numPaths: [2, 1]
            )
        ].flatMap { $0 }
    )
    func testDirectRequestResilience(config: Config) async throws {
        var testResult: ResilienceTest = ResilienceTest(
            name: "Direct Request Resilience - \(config.testDescription)"
        )
        
        /// This test doesn't support the `messageAndAttachment` variant
        switch config.variant {
            case .sendMessage, .sendAttachment, .downloadAttachment: break
            case .sendMessageWithAttachment: throw TestError.unableToEvaluateExpression
        }
        
        /// Before we run any tests we want to ensure we have a snode pool (don't want fetching the snode pool to impact the timing
        /// results of the tests)
        func setupNetwork(for fixture: ResilienceTestFixture) async throws {
            fixture.useLiveDateNow()
            
            /// The network will use "single path mode" if it's not running in the main app
            try await fixture.mockAppContext
                .when { $0.isMainApp }
                .thenReturn(config.numPaths > 1)
            
            try await fixture.createWarmedNetwork(
                singlePathMode: config.numPaths == 1,
                customCachePath: fixture.customCachePath,
                snodePoolCacheData: snodePoolCacheData
            )
        }
        
        let parentFixture: ResilienceTestFixture = try await ResilienceTestFixture.create()
        try await parentFixture.createStorage()
        try await setupNetwork(for: parentFixture)
        
        /// Perform any preparation work
        testResult.setupResult = await Result(catching: {
            try await parentFixture.prepareForTestVariant(config.variant, isParentFixture: true)
        })
        
        /// Now we can kick off the actual tests
        if case .success = testResult.setupResult {
            await withTaskGroup(of: (attempt: Int, latency: TimeInterval, result: Result<Void, Error>).self) { group in
                let fullStartTime: TimeInterval = parentFixture.dependencies.dateNow.timeIntervalSince1970
                
                for attempt in 1...config.numberOfAttempts {
                    /// Add stagger if desired
                    switch config.behaviour {
                        case .concurrent: break
                        case .staggered(let delayMs) where delayMs > 0 && attempt > 1:
                            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                            
                            /// Yield to give any previous tearDown the chance to complete
                            if config.mode == .newNetworkPerRequest {
                                await Task.yield()
                            }
                            
                        default: break
                    }
                    
                    group.addTask {
                        let fixture: ResilienceTestFixture
                        let job: Job
                        
                        do {
                            switch config.mode {
                                case .shared: fixture = parentFixture
                                case .newNetworkPerRequest:
                                    fixture = try await ResilienceTestFixture.create()
                                    fixture.setStorage(parentFixture.dependencies[singleton: .storage])
                                    try await setupNetwork(for: fixture)
                                    try await fixture.prepareForTestVariant(
                                        config.variant,
                                        isParentFixture: false
                                    )
                            }
                            
                            job = try await fixture.createTestJob(for: config.variant, attempt: attempt)
                        }
                        catch { return (attempt, 0, .failure(error)) }
                        
                        let startTime: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970
                        let result: Result<Void, Error> = await Result(catching: {
                            try await fixture.runJob(job, attempt: attempt, usingJobRunner: false)
                        })
                        let latency: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970 - startTime
                        
                        switch config.mode {
                            case .shared: break
                            case .newNetworkPerRequest: await fixture.tearDown()
                        }
                        
                        return (attempt, latency, result)
                    }
                    
                    /// Handle concurrenct limit if specified
                    switch config.behaviour {
                        case .staggered: break
                        case .concurrent(let numToSendAtOnce) where numToSendAtOnce > 0 && numToSendAtOnce < config.numberOfAttempts:
                            if attempt % numToSendAtOnce == 0 {
                                for await (attempt, latency, result) in group {
                                    testResult.recordResult(attempt: attempt, latency: latency, result: result)
                                }
                            }
                            
                        default: break
                    }
                }
                
                /// Collect remaining results
                for await (attempt, latency, result) in group {
                    testResult.recordResult(attempt: attempt, latency: latency, result: result)
                }
                
                let endTime: TimeInterval = parentFixture.dependencies.dateNow.timeIntervalSince1970
                testResult.recordTiming(startTime: fullStartTime, endTime: endTime)
            }
        }
        
        await parentFixture.tearDown()
        
        print(testResult.description)
        
        #expect(testResult.successRate >= 0.95, "Success rate should be at least 95%")
        #expect(testResult.averageLatency < 5.0, "Average latency should be under 5 seconds")
    }
    
    @Test(
        "Job Runner Resilience",
        .serialized,
        arguments: [
            Config.jobRunnerVariations(
                variant: .sendMessageWithAttachment(fileSize: 5_000_000),
                attempts: 200,
                behaviours: [
                    .concurrent(num: 50),
                    .staggered(delayMs: 250)
                ],
                numPaths: [2, 1]
            ),
            Config.jobRunnerVariations(
                variant: .downloadAttachment(fileSize: 5_000_000),
                attempts: 200,
                behaviours: [
                    .concurrent(num: 50),
                    .staggered(delayMs: 250)
                ],
                numPaths: [2, 1]
            )
        ].flatMap { $0 }
    )
    func testJobRunnerResilience(config: Config) async throws {
        var testResult: ResilienceTest = ResilienceTest(
            name: "Job Runner Resilience - \(config.testDescription)"
        )
        
        /// Setup the dependencies based on the config
        fixture.createJobRunner()
        try await fixture.mockAppContext
            .when { $0.isMainApp }
            .thenReturn(config.numPaths > 1)
        try await fixture.createWarmedNetwork(
            singlePathMode: config.numPaths == 1,
            customCachePath: nil,   /// The main fixture will use the proper snode pool
            snodePoolCacheData: nil /// Same as above
        )
        
        /// Perform any preparation work
        testResult.setupResult = await Result(catching: {
            try await fixture.prepareForTestVariant(config.variant, isParentFixture: true)
        })
        
        /// Now we can kick off the actual tests
        if case .success = testResult.setupResult {
            await withTaskGroup(of: (attempt: Int, latency: TimeInterval, result: Result<Void, Error>).self) { group in
                let fullStartTime: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970
                
                for attempt in 1...config.numberOfAttempts {
                    /// Add stagger if desired
                    switch config.behaviour {
                        case .concurrent: break
                        case .staggered(let delayMs) where delayMs > 0 && attempt > 1:
                            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                            
                            /// Yield to give any previous tearDown the chance to complete
                            if config.mode == .newNetworkPerRequest {
                                await Task.yield()
                            }
                            
                        default: break
                    }
                    
                    group.addTask {
                        var job: Job
                        
                        do {
                            job = try await fixture.createTestJob(for: config.variant, attempt: attempt)
                        }
                        catch { return (attempt, 0, .failure(error)) }
                        
                        let startTime: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970
                        let result: Result<Void, Error> = await Result(catching: {
                            job = try await fixture.runJob(job, attempt: attempt, usingJobRunner: true)
                            
                            /// If we get a `deferred`error then the job was probably deferred waiting on an attachment
                            /// upload so wait briefly and then check the result again (limit the number of loops to avoid
                            /// running forever - allow `2m` max)
                            for _ in 0..<((2 * 60 * 1000) / 50) {
                                try? await Task.sleep(nanoseconds: UInt64(50) * 1_000_000)
                                
                                let result: JobRunner.JobResult = await fixture
                                    .dependencies[singleton: .jobRunner]
                                    .awaitResult(for: job)
                                
                                switch result {
                                    case .succeeded: return                 /// Leave the loop
                                    case .failed(let error, _): throw error /// Fail immediately
                                    case .deferred, .notFound: continue     /// Keep looping
                                }
                            }
                            
                            /// If we got to the end of the loop then error
                            throw NetworkError.explicit("Test Timeout")
                        })
                        
                        let latency: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970 - startTime
                        return (attempt, latency, result)
                    }
                    
                    /// Handle concurrenct limit if specified
                    switch config.behaviour {
                        case .staggered: break
                        case .concurrent(let numToSendAtOnce) where numToSendAtOnce > 0 && numToSendAtOnce < config.numberOfAttempts:
                            if attempt % numToSendAtOnce == 0 {
                                for await (attempt, latency, result) in group {
                                    testResult.recordResult(attempt: attempt, latency: latency, result: result)
                                }
                            }
                            
                        default: break
                    }
                }
                
                /// Collect remaining results
                for await (attempt, latency, result) in group {
                    testResult.recordResult(attempt: attempt, latency: latency, result: result)
                }
                
                let endTime: TimeInterval = fixture.dependencies.dateNow.timeIntervalSince1970
                testResult.recordTiming(startTime: fullStartTime, endTime: endTime)
            }
        }
        
        await fixture.tearDown()
        
        print(testResult.description)
        
        #expect(testResult.successRate >= 0.95, "Success rate should be at least 95%")
        #expect(testResult.averageLatency < 5.0, "Average latency should be under 5 seconds")
    }
}

// MARK: - Test Fixture

class ResilienceTestFixture: FixtureBase {
    static let testDataPath: String = "\(SessionFileManager.nonInjectedAppSharedDataDirectoryPath)/testData"
    let customCachePath: String = "\(testDataPath)/snodeCache_\(UUID().uuidString)"
    
    var mockAppContext: MockAppContext { mock(for: .appContext) { _ in MockAppContext() } }
    var mockNetwork: MockNetwork { mock(for: .network) { _ in MockNetwork() } }
    var mockJobRunner: MockJobRunner { mock(for: .jobRunner) { _ in MockJobRunner() } }
    var mockCrypto: MockCrypto { mock(for: .crypto) { _ in MockCrypto() } }
    var mockExtensionHelper: MockExtensionHelper { mock(for: .extensionHelper) { _ in MockExtensionHelper() } }
    var mockFileManager: MockFileManager { mock(for: .fileManager) { _ in MockFileManager() } }
    var mockGeneralCache: MockGeneralCache { mock(cache: .general) { _ in MockGeneralCache() } }
    var mockLibSessionCache: MockLibSessionCache { mock(cache: .libSession) { _ in MockLibSessionCache() } }
        
    static func create() async throws -> ResilienceTestFixture {
        let fixture: ResilienceTestFixture = ResilienceTestFixture()
        try await fixture.applyBaselineStubs()
        
        return fixture
    }
    
    func tearDown() async {
        await Task.yield()
        
        dependencies[singleton: .jobRunner].stopAndClearPendingJobs()
        _ = try? await dependencies[singleton: .storage].writeAsync { db in
            try Job.deleteAll(db)
        }
        
        dependencies.removeAll()
        try? FileManager.default.removeItem(atPath: customCachePath)
        
        await Task.yield()
    }
    
    // MARK: - Setup
    
    private func applyBaselineStubs() async throws {
        try await applyBaselineAppContext()
        try await applyBaselineNetwork()
        try await applyBaselineJobRunner()
        try await applyBaselineCrypto()
        try await applyBaselineExtensionHelper()
        try await applyBaselineFileManager()
        try await applyBaselineGeneralCache()
        try await applyBaselineLibSessionCache()
    }
    
    private func applyBaselineAppContext() async throws {
        try await mockAppContext.when { $0.isValid }.thenReturn(true)
        try await mockAppContext.when { $0.isMainApp }.thenReturn(false)
    }
    
    private func applyBaselineNetwork() async throws {}
    private func applyBaselineJobRunner() async throws {}
    private func applyBaselineCrypto() async throws {
        try await mockCrypto
            .when { $0.generate(.ed25519KeyPair(seed: Array<UInt8>.any)) }
            .thenReturn(
                KeyPair(
                    publicKey: Array(Data(hex: TestConstants.edPublicKey)),
                    secretKey: Array(Data(hex: TestConstants.edSecretKey))
                )
            )
        try await mockCrypto
            .when {
                $0.generate(
                    .x25519(ed25519Pubkey: Array(Data(hex: Network.FileServer.defaultEdPublicKey)))
                )
            }
            .thenReturn(Array(Data(
                hex: "09324794aa9c11948189762d198c618148e9136ac9582068180661208927ef34")
            ))
        try await mockCrypto
            .when { try $0.tryGenerate(.hash(message: .any)) }
            .thenReturn([1, 2, 3])
    }
    
    private func applyBaselineFileManager() async throws {
        try await mockFileManager.defaultInitialSetup()
    }
    
    private func applyBaselineGeneralCache() async throws {
        try await mockGeneralCache
            .when { $0.sessionId }
            .thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
        try await mockGeneralCache
            .when { $0.ed25519SecretKey }
            .thenReturn(Array(Data(hex: TestConstants.edSecretKey)))
        try await mockGeneralCache
            .when { $0.ed25519Seed }
            .thenReturn(Array(Data(hex: TestConstants.edKeySeed)))
    }
    
    private func applyBaselineExtensionHelper() async throws {
        try await mockExtensionHelper
            .when { try $0.createDedupeRecord(threadId: .any, uniqueIdentifier: .any) }
            .thenReturn(())
        try await mockExtensionHelper
            .when { $0.dedupeRecordExists(threadId: .any, uniqueIdentifier: .any) }
            .thenReturn(false)
    }
    
    private func applyBaselineLibSessionCache() async throws {}
    
    // MARK: - Test Helpers
    
    func prepareForTestVariant(_ variant: ResilienceTest.Variant, isParentFixture: Bool) async throws {
        /// Need to ensure the `MockFileManager` returns the right amount of content for the upload/download tests
        switch variant {
            case .sendMessage: break
            case .sendAttachment(let fileSize), .sendMessageWithAttachment(let fileSize),
                .downloadAttachment(let fileSize):
                let fileData: Data = Data([UInt8](repeating: 1, count: Int(fileSize)))
                
                await mockFileManager.removeMocksFor { try $0.contents(atPath: .any) }
                try await mockFileManager
                    .when { try $0.contents(atPath: .any) }
                    .thenReturn(fileData)
                try await mockCrypto
                    .when {
                        try $0.tryGenerate(
                            .legacyExpectedEncryptedAttachmentSize(plaintextSize: .any)
                        )
                    }
                    .thenReturn(Int(fileSize))
                try await mockCrypto
                    .when {
                        try $0.tryGenerate(
                            .legacyEncryptedAttachment(plaintext: .any)
                        )
                    }
                    .thenReturn((fileData, Data(), Data()))
                try await mockCrypto
                    .when {
                        try $0.tryGenerate(
                            .legacyDecryptAttachment(
                                ciphertext: .any,
                                key: .any,
                                digest: .any,
                                unpaddedSize: .any
                            )
                        )
                    }
                    .thenReturn(fileData)
        }
        
        /// Need to allow duplicate downloads for any download testing
        switch variant {
            case .sendMessage, .sendAttachment, .sendMessageWithAttachment: break
            case .downloadAttachment:
                dependencies.set(feature: .allowDuplicateDownloads, to: true)
        }
        
        /// Need to upload an attachment before we can test downloading (only want to do this once)
        if isParentFixture {
            switch variant {
                case .sendMessage, .sendAttachment, .sendMessageWithAttachment: break
                case .downloadAttachment(let fileSize):
                    let job: Job = try await createTestJob(
                        for: .sendAttachment(fileSize: fileSize),
                        attempt: 0
                    )
                    try await runJob(job, attempt: 0, usingJobRunner: false)
            }
        }
    }
    
    func clearTestData() {
        try? FileManager.default.removeItem(atPath: ResilienceTestFixture.testDataPath)
    }
    
    func useLiveDateNow() {
        dependencies.useLiveDateNow()
    }
    
    func setStorage(_ storage: Storage) {
        dependencies.set(singleton: .storage, to: storage)
    }
    
    func createStorage() async throws {
        let storage: Storage = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        dependencies.set(singleton: .storage, to: storage)
        
        try await withUnsafeThrowingContinuation { continuation in
            storage.perform(migrations: SNMessagingKit.migrations, onProgressUpdate: nil) { result in
                switch result {
                    case .success: continuation.resume(returning: ())
                    case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        try await storage.writeAsync { db in
            try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
            try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
            try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
            try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            
            try SessionThread(
                id: "05\(TestConstants.publicKey)",
                variant: .contact,
                creationDateTimestamp: 1234567890
            ).insert(db)
            
            /// Need to clear any pre-created jobs to avoid `id` collisions with the job runner tests
            try Job.deleteAll(db)
        }
    }
    
    func createWarmedNetwork(
        singlePathMode: Bool,
        customCachePath: String?,
        snodePoolCacheData: Data?
    ) async throws {
        if let path: String = customCachePath, let data = snodePoolCacheData {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: "\(path)/snode_pool"))
        }
        
        /// The `libSessionNetwork` dependency defaults to a Noop instance when running tests so we need to manually
        /// create it to ensure it runs correctly
        dependencies.set(
            cache: .libSessionNetwork,
            to: LibSession.NetworkCache(
                customCachePath: customCachePath,
                using: dependencies
            )
        )
        dependencies.warm(singleton: .network)
    }
    
    func createJobRunner() {
        let jobRunner: JobRunner = JobRunner(isTestingJobRunner: true, using: dependencies)
        jobRunner.setExecutor(MessageSendJob.self, for: .messageSend)
        jobRunner.setExecutor(AttachmentUploadJob.self, for: .attachmentUpload)
        jobRunner.setExecutor(AttachmentDownloadJob.self, for: .attachmentDownload)
        jobRunner.appDidFinishLaunching()
        jobRunner.appDidBecomeActive()
        dependencies.set(singleton: .jobRunner, to: jobRunner)
    }
    
    func createTestMessage(attempt: Int) -> VisibleMessage {
        VisibleMessage(text: "Resilience Test Message \(attempt)")
    }
    
    func createTestJob(for variant: ResilienceTest.Variant, attempt: Int) async throws -> Job {
        let message: VisibleMessage = createTestMessage(attempt: attempt)
        
        return try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
            let interaction: Interaction = try Interaction(
                threadId: "05\(TestConstants.publicKey)",
                threadVariant: .contact,
                authorId: "05\(TestConstants.publicKey)",
                variant: .standardOutgoing,
                body: message.text!,
                timestampMs: Int64(attempt),
                using: dependencies
            ).inserted(db)
            let messageSendJob: Job = Job(
                id: nil,
                failureCount: 0,
                variant: .messageSend,
                behaviour: .runOnce,
                shouldBlock: false,
                shouldBeUnique: false,
                shouldSkipLaunchBecomeActive: false,
                nextRunTimestamp: 0,
                threadId: "05\(TestConstants.publicKey)",
                interactionId: interaction.id!,
                details: try! JSONEncoder()
                    .with(outputFormatting: .sortedKeys)    // Needed for deterministic comparison
                    .encode(
                        MessageSendJob.Details(
                            destination: .contact(publicKey: "05\(TestConstants.publicKey)"),
                            message: message
                        )
                    ),
                transientData: nil
            )
            
            /// If we don't want to upload then we can just return the `messageSendJob` here
            let fileSize: UInt
            
            switch variant {
                case .sendMessage: return messageSendJob
                case .downloadAttachment:
                    let attachments: [SessionMessagingKit.Attachment] = try Attachment.fetchAll(db)
                    
                    guard
                        let attachment: SessionMessagingKit.Attachment = attachments.first,
                        let path: String = try? dependencies[singleton: .attachmentManager].path(
                            for: attachment.downloadUrl
                        )
                    else { throw StorageError.objectNotFound }
                    
                    /// Remove the uploaded attachment file just in case (since we plan to download it) and reset the attachment
                    /// state so we can re-download
                    try? FileManager.default.removeItem(atPath: path)
                    try Attachment
                        .filter(id: attachment.id)
                        .updateAll(
                            db,
                            Attachment.Columns.state.set(to: Attachment.State.pendingDownload)
                        )
                    
                    return Job(
                        id: nil,
                        failureCount: 0,
                        variant: .attachmentDownload,
                        behaviour: .runOnce,
                        shouldBlock: false,
                        shouldBeUnique: false,
                        shouldSkipLaunchBecomeActive: false,
                        nextRunTimestamp: 0,
                        threadId: "05\(TestConstants.publicKey)",
                        interactionId: interaction.id!,
                        details: try! JSONEncoder()
                            .with(outputFormatting: .sortedKeys)    // Needed for deterministic comparison
                            .encode(
                                AttachmentDownloadJob.Details(
                                    attachmentId: attachment.id
                                )
                            ),
                        transientData: nil
                    )
                    
                case .sendAttachment(let targetFileSize), .sendMessageWithAttachment(let targetFileSize):
                    fileSize = targetFileSize
                    break
            }
            
            let attachment: SessionMessagingKit.Attachment = try Attachment(
                id: "Resilience_Test_Attachment_\(attempt)",
                serverId: nil,
                variant: .standard,
                state: .uploading,
                contentType: "text/plain",
                byteCount: fileSize,
                creationTimestamp: dependencies.dateNow.timeIntervalSince1970,
                sourceFilename: nil,
                downloadUrl: dependencies[singleton: .attachmentManager].pendingUploadPath(
                    for: "Resilience_Test_Attachment_\(attempt)"
                ),
                width: nil,
                height: nil,
                duration: nil,
                isVisualMedia: false,
                isValid: true,
                encryptionKey: nil,
                digest: nil
            ).inserted(db)
            try InteractionAttachment(
                albumIndex: 0,
                interactionId: interaction.id!,
                attachmentId: attachment.id
            ).insert(db)
            
            switch variant {
                case .downloadAttachment: throw TestError.unableToEvaluateExpression
                case .sendMessage: return messageSendJob
                case .sendMessageWithAttachment:
                    /// When we want to send a message with an attachment we should just run the `MessageSendJob` as it
                    /// will schedule and run the `AttachmentUploadJob`
                    return messageSendJob
                
                case .sendAttachment:
                    return Job(
                        id: nil,
                        failureCount: 0,
                        variant: .attachmentUpload,
                        behaviour: .runOnce,
                        shouldBlock: false,
                        shouldBeUnique: false,
                        shouldSkipLaunchBecomeActive: false,
                        nextRunTimestamp: 0,
                        threadId: "05\(TestConstants.publicKey)",
                        interactionId: interaction.id!,
                        details: try! JSONEncoder()
                            .with(outputFormatting: .sortedKeys)    // Needed for deterministic comparison
                            .encode(
                                AttachmentUploadJob.Details(
                                    messageSendJobId: -1,   /// Won't be related to a message send job
                                    attachmentId: attachment.id
                                )
                            ),
                        transientData: nil
                    )
            }
        }
    }
    
    @discardableResult func runJob(
        _ job: Job,
        attempt: Int,
        usingJobRunner: Bool,
        onRetry: ((Job) -> Void)? = nil
    ) async throws -> Job {
        guard !usingJobRunner else {
            let insertedJob: Job? = try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
                dependencies[singleton: .jobRunner].add(
                    db,
                    job: job,
                    canStartJob: true
                )
            }
            
            /// If we failed to insert the job then error and fail the test
            guard let insertedJob else {
                throw StorageError.objectNotFound
            }
            
            return insertedJob
        }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            /// If we are running the job directly then we need to set it's `id` or the job may fail to run
            let targetJob: JobExecutor.Type
            let updatedJob: Job = job.with(id: .set(to: Int64(attempt)))
            
            switch updatedJob.variant {
                case .messageSend: targetJob = MessageSendJob.self
                case .attachmentUpload: targetJob = AttachmentUploadJob.self
                case .attachmentDownload: targetJob = AttachmentDownloadJob.self
                default:
                    continuation.resume(throwing: TestError.unableToEvaluateExpression)
                    return
            }
            
            targetJob.run(
                updatedJob,
                scheduler: DispatchQueue.global(),
                success: { job, _ in
                    continuation.resume()
                },
                failure: { job, error, permanent in
                    if !permanent {
                        onRetry?(job)
                    }
                    continuation.resume(throwing: error)
                },
                deferred: { _ in
                    // For resilience tests, treat deferrals as temporary failures
                    continuation.resume(throwing: TestError.deferred)
                },
                using: dependencies
            )
        }
        
        return job
    }
}
