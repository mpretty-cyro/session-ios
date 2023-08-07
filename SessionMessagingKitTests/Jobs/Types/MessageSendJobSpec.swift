// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

import Quick
import Nimble

@testable import SessionMessagingKit
@testable import SessionUtilitiesKit

class MessageSendJobSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        var job: Job!
        var interaction: Interaction!
        var attachment: Attachment!
        var interactionAttachment: InteractionAttachment!
        var mockStorage: Storage!
        var mockJobRunner: MockJobRunner!
        var dependencies: Dependencies!
        
        // MARK: - JobRunner
        
        describe("a MessageSendJob") {
            // MARK: - Configuration
            
            beforeEach {
                mockStorage = SynchronousStorage(
                    customWriter: try! DatabaseQueue(),
                    customMigrationTargets: [
                        SNUtilitiesKit.self,
                        SNMessagingKit.self
                    ]
                )
                mockJobRunner = MockJobRunner()
                dependencies = Dependencies(
                    storage: mockStorage,
                    jobRunner: mockJobRunner,
                    dateNow: Date(timeIntervalSince1970: 1234567890)
                )
                attachment = Attachment(
                    id: "200",
                    variant: .standard,
                    state: .failedDownload,
                    contentType: "text/plain",
                    byteCount: 200
                )
                
                mockStorage.write { db in
                    try SessionThread.fetchOrCreate(db, id: "Test1", variant: .contact, shouldBeVisible: true)
                }
                
                mockJobRunner
                    .when {
                        $0.jobInfoFor(
                            jobs: nil,
                            state: .running,
                            variant: .attachmentUpload
                        )
                    }
                    .thenReturn([:])
                mockJobRunner
                    .when { $0.insert(any(), job: any(), before: any()) }
                    .then { args in
                        let db: Database = args[0] as! Database
                        var job: Job = args[1] as! Job
                        job.id = 1000
                        
                        try! job.insert(db)
                    }
                    .thenReturn((1000, Job(variant: .messageSend)))
            }
            
            afterEach {
                job = nil
                mockStorage = nil
                dependencies = nil
            }
            
            // MARK: - fails when not given any details
            it("fails when not given any details") {
                job = Job(variant: .messageSend)
                
                var error: Error? = nil
                var permanentFailure: Bool = false
                
                MessageSendJob.run(
                    job,
                    queue: .main,
                    success: { _, _, _ in },
                    failure: { _, runError, runPermanentFailure, _ in
                        error = runError
                        permanentFailure = runPermanentFailure
                    },
                    deferred: { _, _ in },
                    using: dependencies
                )
                
                expect(error).to(matchError(JobRunnerError.missingRequiredDetails))
                expect(permanentFailure).to(beTrue())
            }
            
            // MARK: - fails when given incorrect details
            it("fails when given incorrect details") {
                job = Job(
                    variant: .messageSend,
                    details: MessageReceiveJob.Details(messages: [], calledFromBackgroundPoller: false)
                )
                
                var error: Error? = nil
                var permanentFailure: Bool = false
                
                MessageSendJob.run(
                    job,
                    queue: .main,
                    success: { _, _, _ in },
                    failure: { _, runError, runPermanentFailure, _ in
                        error = runError
                        permanentFailure = runPermanentFailure
                    },
                    deferred: { _, _ in },
                    using: dependencies
                )
                
                expect(error).to(matchError(JobRunnerError.missingRequiredDetails))
                expect(permanentFailure).to(beTrue())
            }
            
            // MARK: - of VisibleMessage
            context("of VisibleMessage") {
                beforeEach {
                    interaction = Interaction(
                        id: 100,
                        serverHash: nil,
                        messageUuid: nil,
                        threadId: "Test1",
                        authorId: "Test",
                        variant: .standardOutgoing,
                        body: "Test",
                        timestampMs: 1234567890,
                        receivedAtTimestampMs: 1234567900,
                        wasRead: false,
                        hasMention: false,
                        expiresInSeconds: nil,
                        expiresStartedAtMs: nil,
                        linkPreviewUrl: nil,
                        openGroupServerMessageId: nil,
                        openGroupWhisperMods: false,
                        openGroupWhisperTo: nil
                    )
                    job = Job(
                        variant: .messageSend,
                        interactionId: interaction.id!,
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            )
                        )
                    )
                    
                    mockStorage.write { db in
                        try interaction.insert(db)
                        try job.insert(db)
                    }
                }
                
                // MARK: -- fails when there is no job id
                it("fails when there is no job id") {
                    job = Job(
                        variant: .messageSend,
                        interactionId: interaction.id!,
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            )
                        )
                    )
                    
                    var error: Error? = nil
                    var permanentFailure: Bool = false
                    
                    MessageSendJob.run(
                        job,
                        queue: .main,
                        success: { _, _, _ in },
                        failure: { _, runError, runPermanentFailure, _ in
                            error = runError
                            permanentFailure = runPermanentFailure
                        },
                        deferred: { _, _ in },
                        using: dependencies
                    )
                    
                    expect(error).to(matchError(JobRunnerError.missingRequiredDetails))
                    expect(permanentFailure).to(beTrue())
                }
                
                // MARK: -- fails when there is no interaction id
                it("fails when there is no interaction id") {
                    job = Job(
                        variant: .messageSend,
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            )
                        )
                    )
                    
                    var error: Error? = nil
                    var permanentFailure: Bool = false
                    
                    MessageSendJob.run(
                        job,
                        queue: .main,
                        success: { _, _, _ in },
                        failure: { _, runError, runPermanentFailure, _ in
                            error = runError
                            permanentFailure = runPermanentFailure
                        },
                        deferred: { _, _ in },
                        using: dependencies
                    )
                    
                    expect(error).to(matchError(JobRunnerError.missingRequiredDetails))
                    expect(permanentFailure).to(beTrue())
                }
                
                // MARK: -- fails when there is no interaction for the provided interaction id
                it("fails when there is no interaction for the provided interaction id") {
                    job = Job(
                        variant: .messageSend,
                        interactionId: 12345,
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            )
                        )
                    )
                    mockStorage.write { db in try job.insert(db) }
                    
                    var error: Error? = nil
                    var permanentFailure: Bool = false
                    
                    MessageSendJob.run(
                        job,
                        queue: .main,
                        success: { _, _, _ in },
                        failure: { _, runError, runPermanentFailure, _ in
                            error = runError
                            permanentFailure = runPermanentFailure
                        },
                        deferred: { _, _ in },
                        using: dependencies
                    )
                    
                    expect(error).to(matchError(StorageError.objectNotFound))
                    expect(permanentFailure).to(beTrue())
                }
                
                // MARK: -- with an attachment
                context("with an attachment") {
                    beforeEach {
                        interactionAttachment = InteractionAttachment(
                            albumIndex: 0,
                            interactionId: interaction.id!,
                            attachmentId: attachment.id
                        )
                        
                        mockStorage.write { db in
                            try attachment.insert(db)
                            try interactionAttachment.insert(db)
                        }
                    }
                    
                    // MARK: ---- it fails when trying to send with an attachment which previously failed to download
                    it("it fails when trying to send with an attachment which previously failed to download") {
                        mockStorage.write { db in
                            try attachment.with(state: .failedDownload).save(db)
                        }
                        
                        var error: Error? = nil
                        var permanentFailure: Bool = false
                        
                        MessageSendJob.run(
                            job,
                            queue: .main,
                            success: { _, _, _ in },
                            failure: { _, runError, runPermanentFailure, _ in
                                error = runError
                                permanentFailure = runPermanentFailure
                            },
                            deferred: { _, _ in },
                            using: dependencies
                        )
                        
                        expect(error).to(matchError(AttachmentError.notUploaded))
                        expect(permanentFailure).to(beTrue())
                    }
                    
                    // MARK: ---- with a pending upload
                    context("with a pending upload") {
                        beforeEach {
                            mockStorage.write { db in
                                try attachment.with(state: .uploading).save(db)
                            }
                        }
                        
                        // MARK: ------ it defers when trying to send with an attachment which is still pending upload
                        it("it defers when trying to send with an attachment which is still pending upload") {
                            var didDefer: Bool = false
                            
                            mockStorage.write { db in
                                try attachment.with(state: .uploading).save(db)
                            }
                            
                            MessageSendJob.run(
                                job,
                                queue: .main,
                                success: { _, _, _ in },
                                failure: { _, _, _, _ in },
                                deferred: { _, _ in didDefer = true },
                                using: dependencies
                            )
                            
                            expect(didDefer).to(beTrue())
                        }
                        
                        // MARK: ------ it defers when trying to send with an uploaded attachment that has an invalid downloadUrl
                        it("it defers when trying to send with an uploaded attachment that has an invalid downloadUrl") {
                            var didDefer: Bool = false
                            
                            mockStorage.write { db in
                                try attachment
                                    .with(
                                        state: .uploaded,
                                        downloadUrl: nil
                                    )
                                    .save(db)
                            }
                            
                            MessageSendJob.run(
                                job,
                                queue: .main,
                                success: { _, _, _ in },
                                failure: { _, _, _, _ in },
                                deferred: { _, _ in didDefer = true },
                                using: dependencies
                            )
                            
                            expect(didDefer).to(beTrue())
                        }
                        
                        // MARK: ------ inserts an attachment upload job before the message send job
                        it("inserts an attachment upload job before the message send job") {
                            mockJobRunner
                                .when {
                                    $0.jobInfoFor(
                                        jobs: nil,
                                        state: .running,
                                        variant: .attachmentUpload
                                    )
                                }
                                .thenReturn([:])
                            
                            MessageSendJob.run(
                                job,
                                queue: .main,
                                success: { _, _, _ in },
                                failure: { _, _, _, _ in },
                                deferred: { _, _ in },
                                using: dependencies
                            )
                            
                            expect(mockJobRunner)
                                .to(call(.exactly(times: 1), matchingParameters: true) {
                                    $0.insert(
                                        any(),
                                        job: Job(
                                            variant: .attachmentUpload,
                                            behaviour: .runOnce,
                                            shouldBlock: false,
                                            shouldSkipLaunchBecomeActive: false,
                                            interactionId: 100,
                                            details: AttachmentUploadJob.Details(
                                                messageSendJobId: 1,
                                                attachmentId: "200"
                                            )
                                        ),
                                        before: job
                                    )
                                })
                        }
                        
                        // MARK: ------ creates a dependency between the new job and the existing one
                        it("creates a dependency between the new job and the existing one") {
                            MessageSendJob.run(
                                job,
                                queue: .main,
                                success: { _, _, _ in },
                                failure: { _, _, _, _ in },
                                deferred: { _, _ in },
                                using: dependencies
                            )
                            
                            expect(mockStorage.read { db in try JobDependencies.fetchOne(db) })
                                .to(equal(JobDependencies(jobId: 9, dependantId: 1000)))
                        }
                    }
                }
            }
        }
    }
}
