// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import PromiseKit
import SessionUtilitiesKit

extension MessageSender {
    
    // MARK: - Durable
    
    public static func send(_ db: Database, interaction: Interaction, with attachments: [SignalAttachment], in thread: SessionThread) throws {
        guard let interactionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
        
        try prep(db, signalAttachments: attachments, for: interactionId)
        send(
            db,
            message: VisibleMessage.from(db, interaction: interaction),
            threadId: thread.id,
            interactionId: interactionId,
            to: try Message.Destination.from(db, thread: thread)
        )
    }
    
    public static func send(_ db: Database, interaction: Interaction, in thread: SessionThread) throws {
        // Only 'VisibleMessage' types can be sent via this method
        guard interaction.variant == .standardOutgoing else { throw MessageSenderError.invalidMessage }
        guard let interactionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
        
        send(
            db,
            message: VisibleMessage.from(db, interaction: interaction),
            threadId: thread.id,
            interactionId: interactionId,
            to: try Message.Destination.from(db, thread: thread)
        )
    }
    
    public static func send(_ db: Database, message: Message, interactionId: Int64?, in thread: SessionThread) throws {
        send(
            db,
            message: message,
            threadId: thread.id,
            interactionId: interactionId,
            to: try Message.Destination.from(db, thread: thread)
        )
    }
    
    public static func send(_ db: Database, message: Message, threadId: String?, interactionId: Int64?, to destination: Message.Destination) {
        JobRunner.add(
            db,
            job: Job(
                variant: .messageSend,
                threadId: threadId,
                interactionId: interactionId,
                details: MessageSendJob.Details(
                    destination: destination,
                    message: message
                )
            )
        )
    }

    // MARK: - Non-Durable
    
    public static func sendNonDurably(_ db: Database, interaction: Interaction, with attachments: [SignalAttachment], in thread: SessionThread) throws -> Promise<Void> {
        guard let interactionId: Int64 = interaction.id else { return Promise(error: StorageError.objectNotSaved) }
        
        try prep(db, signalAttachments: attachments, for: interactionId)
        
        return sendNonDurably(
            db,
            message: VisibleMessage.from(db, interaction: interaction),
            interactionId: interactionId,
            to: try Message.Destination.from(db, thread: thread)
        )
    }
    
    
    public static func sendNonDurably(_ db: Database, interaction: Interaction, in thread: SessionThread) throws -> Promise<Void> {
        // Only 'VisibleMessage' types can be sent via this method
        guard interaction.variant == .standardOutgoing else { throw MessageSenderError.invalidMessage }
        guard let interactionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
        
        return sendNonDurably(
            db,
            message: VisibleMessage.from(db, interaction: interaction),
            interactionId: interactionId,
            to: try Message.Destination.from(db, thread: thread)
        )
    }
    
    public static func preparedSendData(
        _ db: Database,
        interaction: Interaction,
        in thread: SessionThread
    ) throws -> PreparedSendData {
        // Only 'VisibleMessage' types can be sent via this method
        guard interaction.variant == .standardOutgoing else { throw MessageSenderError.invalidMessage }
        guard let interactionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
        
        return try MessageSender.preparedSendData(
            db,
            message: VisibleMessage.from(db, interaction: interaction),
            to: try Message.Destination.from(db, thread: thread),
            interactionId: interactionId
        )
    }
    
    public static func sendNonDurably(_ db: Database, message: Message, interactionId: Int64?, in thread: SessionThread) throws -> Promise<Void> {
        return sendNonDurably(
            db,
            message: message,
            interactionId: interactionId,
            to: try Message.Destination.from(db, thread: thread)
        )
    }
    
    public static func sendNonDurably(_ db: Database, message: Message, interactionId: Int64?, to destination: Message.Destination) -> Promise<Void> {
        var attachmentUploadPromises: [Promise<String?>] = [Promise.value(nil)]
        
        // If we have an interactionId then check if it has any attachments and process them first
        if let interactionId: Int64 = interactionId {
            let threadId: String = {
                switch destination {
                    case .contact(let publicKey, _): return publicKey
                    case .closedGroup(let groupPublicKey, _): return groupPublicKey
                    case .openGroup(let roomToken, let server, _, _, _):
                        return OpenGroup.idFor(roomToken: roomToken, server: server)
                        
                    case .openGroupInbox(_, _, let blindedPublicKey): return blindedPublicKey
                }
            }()
            let openGroup: OpenGroup? = try? OpenGroup.fetchOne(db, id: threadId)
            let attachmentStateInfo: [Attachment.StateInfo] = (try? Attachment
                .stateInfo(interactionId: interactionId, state: .uploading)
                .fetchAll(db))
                .defaulting(to: [])
            
            attachmentUploadPromises = (try? Attachment
                .filter(ids: attachmentStateInfo.map { $0.attachmentId })
                .fetchAll(db))
                .defaulting(to: [])
                .map { attachment -> Promise<String?> in
                    let (promise, seal) = Promise<String?>.pending()
    
                    attachment.upload(
                        db,
                        queue: DispatchQueue.global(qos: .userInitiated),
                        using: { db, data in
                            if let openGroup: OpenGroup = openGroup {
                                return OpenGroupAPI
                                    .uploadFile(
                                        db,
                                        bytes: data.bytes,
                                        to: openGroup.roomToken,
                                        on: openGroup.server
                                    )
                                    .map { _, response -> String in response.id }
                                    .eraseToAnyPublisher()
                            }
    
                            return FileServerAPI.upload(data)
                                .map { response -> String in response.id }
                                .eraseToAnyPublisher()
                        },
                        encrypt: (openGroup == nil),
                        success: { fileId in seal.fulfill(fileId) },
                        failure: { seal.reject($0) }
                    )
    
                    return promise
                }
        }

        // Once the attachments are processed then send the message
        // TODO: Need to update all usages of this method
        preconditionFailure()
//        return when(resolved: attachmentUploadPromises)
//            .then { results -> Promise<Void> in
//                let errors: [Error] = results
//                    .compactMap { result -> Error? in
//                        if case .rejected(let error) = result { return error }
//
//                        return nil
//                    }
//
//                if let error: Error = errors.first { return Promise(error: error) }
//
//                return Storage.shared.writeAsync { db in
//                    let fileIds: [String] = results
//                        .compactMap { result -> String? in
//                            if case .fulfilled(let value) = result { return value }
//
//                            return nil
//                        }
//
//                    return try MessageSender.sendImmediate(
//                        db,
//                        message: message,
//                        to: destination
//                            .with(fileIds: fileIds),
//                        interactionId: interactionId
//                    )
//                }
//            }
    }
    
    public static func performUploadsIfNeeded(
        preparedSendData: PreparedSendData
    ) -> AnyPublisher<PreparedSendData, Error> {
        // We need an interactionId in order for a message to have uploads
        guard let interactionId: Int64 = preparedSendData.interactionId else {
            return Just(preparedSendData)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // Ensure we have the rest of the required data
        guard let destination: Message.Destination = preparedSendData.destination else {
            return Fail<PreparedSendData, Error>(error: MessageSenderError.invalidMessage)
                .eraseToAnyPublisher()
        }
        
        let threadId: String = {
            switch destination {
                case .contact(let publicKey): return publicKey
                case .closedGroup(let groupPublicKey): return groupPublicKey
                case .openGroup(let roomToken, let server, _, _, _):
                    return OpenGroup.idFor(roomToken: roomToken, server: server)
                    
                case .openGroupInbox(_, _, let blindedPublicKey): return blindedPublicKey
            }
        }()
        let fileIdPublisher: AnyPublisher<[String?], Error> = Storage.shared
            .write { db -> AnyPublisher<[String?], Error>? in
                let attachmentStateInfo: [Attachment.StateInfo] = (try? Attachment
                    .stateInfo(interactionId: interactionId, state: .uploading)
                    .fetchAll(db))
                    .defaulting(to: [])
                
                // If there is no attachment data then just return early
                guard !attachmentStateInfo.isEmpty else { return nil }
                
                // Otherwise we need to generate the upload requests
                let openGroup: OpenGroup? = try? OpenGroup.fetchOne(db, id: threadId)
                
                return Publishers
                    .MergeMany(
                        (try? Attachment
                            .filter(ids: attachmentStateInfo.map { $0.attachmentId })
                            .fetchAll(db))
                            .defaulting(to: [])
                            .map { attachment -> AnyPublisher<String?, Error> in
                                Future { resolver in
                                    attachment.upload(
                                        db,
                                        queue: DispatchQueue.global(qos: .userInitiated),
                                        using: { db, data in
                                            if let openGroup: OpenGroup = openGroup {
                                                return OpenGroupAPI
                                                    .uploadFile(
                                                        db,
                                                        bytes: data.bytes,
                                                        to: openGroup.roomToken,
                                                        on: openGroup.server
                                                    )
                                                    .map { _, response -> String in response.id }
                                                    .eraseToAnyPublisher()
                                            }
                                            
                                            return FileServerAPI.upload(data)
                                                .map { response -> String in response.id }
                                                .eraseToAnyPublisher()
                                        },
                                        encrypt: (openGroup == nil),
                                        success: { fileId in resolver(Swift.Result.success(fileId)) },
                                        failure: { resolver(Swift.Result.failure($0)) }
                                    )
                                }
                                .eraseToAnyPublisher()
                            }
                    )
                    .collect()
                    .eraseToAnyPublisher()
            }
            .defaulting(
                to: Just<[String?]>([])
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            )
        
        return fileIdPublisher
            .map { results in
                // Once the attachments are processed then update the PreparedSendData with
                // the fileIds associated to the message
                let fileIds: [String] = results.compactMap { result -> String? in result }
                
                return preparedSendData.with(fileIds: fileIds)
            }
            .eraseToAnyPublisher()
    }
    
    /// This method requires the `db` value to be passed in because if it's called within a `writeAsync` completion block
    /// it will throw a "re-entrant" fatal error when attempting to write again
    public static func syncConfiguration(
        _ db: Database,
        forceSyncNow: Bool = true
    ) throws -> AnyPublisher<Void, Error> {
        // If we don't have a userKeyPair yet then there is no need to sync the configuration
        // as the user doesn't exist yet (this will get triggered on the first launch of a
        // fresh install due to the migrations getting run)
        guard Identity.userExists(db) else {
            return Fail(error: StorageError.generic)
                .eraseToAnyPublisher()
        }
        
        let publicKey: String = getUserHexEncodedPublicKey(db)
        let legacyDestination: Message.Destination = Message.Destination.contact(
            publicKey: publicKey,
            namespace: .default
        )
        let legacyConfigurationMessage = try ConfigurationMessage.getCurrent(db)
        let userConfigMessageChanges: [SharedConfigMessage] = SessionUtil.getChanges(
            ed25519SecretKey: ed25519SecretKey
        )
        let destination: Message.Destination = Message.Destination.contact(
            publicKey: publicKey,
            namespace: .userProfileConfig
        )
        
        guard forceSyncNow else {
            JobRunner.add(
                db,
                job: Job(
                    variant: .messageSend,
                    threadId: publicKey,
                    details: MessageSendJob.Details(
                        destination: legacyDestination,
                        message: legacyConfigurationMessage
                    )
                )
            )
            
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        let sendData: PreparedSendData = try MessageSender.preparedSendData(
            db,
            message: legacyConfigurationMessage,
            to: legacyDestination,
            interactionId: nil
        )

        when(
            resolved: try userConfigMessageChanges.map { message in
                try MessageSender
                    .sendImmediate(
                        db,
                        message: message,
                        to: destination,
                        interactionId: nil
                    )
            }
        )
        .done { results in
            let hadError: Bool = results.contains { result in
                switch result {
                    case .fulfilled: return false
                    case .rejected: return true
                }
            }
            
            guard !hadError else {
                seal.reject(StorageError.generic)
                return
            }
            
            seal.fulfill(())
        }
        .catch { _ in seal.reject(StorageError.generic) }
        .retainUntilComplete()
        
        // TODO: Test this (does it break anything? want to stop the db write asap)
        return Future<Void, Error> { resolver in
            db.afterNextTransaction { _ in
                // TODO: Remove the 'Swift.'
                resolver(Swift.Result.success(()))
            }
        }
        .flatMap { _ in MessageSender.sendImmediate(data: sendData) }
        .eraseToAnyPublisher()
        
//        return MessageSender
//            .sendImmediate(
//                data: try MessageSender.preparedSendData(
//                    db,
//                    message: configurationMessage,
//                    to: destination,
//                    interactionId: nil
//                )
//            )
    }
}
