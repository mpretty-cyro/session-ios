// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public enum DeadlockWorkAround {
    private static let keychainService: String = "DWAKeyChainService"
    private static let encryptionKeyKey: String = "DWAEncryptionKeyKey"
    private static let encryptionKeyLength: Int = 32
    static var sharedDeadlockDirectoryPath: String { "\(OWSFileSystem.appSharedDataDirectoryPath())/messages" }
    
    struct DeadlockMessage: Codable {
        public enum Variant: Codable {
            case incomingMessage(Data)
            case incomingCall(
                threadId: String,
                threadVariant: SessionThread.Variant,
                sentTimestamp: UInt64?,
                state: CallMessage.MessageInfo.State
            )
            case outgoingMessage(
                serverHash: String?,
                base64EncodedMessage: String
            )
            case outgoingOpenGroupMessage(
                roomToken: String,
                server: String,
                sender: String?,
                openGroupServerMessageId: Int64?,
                openGroupMessageSeqNo: Int64?,
                openGroupMessagePosted: TimeInterval?,
                base64EncodedMessage: String
            )
            case outgoingOpenGroupInboxMessage(
                server: String,
                recipientBlindedPublicKey: String,
                sender: String?,
                openGroupServerMessageId: Int64?,
                openGroupMessagePosted: TimeInterval?,
                openGroupMessageExpires: TimeInterval?,
                base64EncodedMessage: String
            )
            case configSync(String)
        }
        
        let variant: Variant
        let attachments: [Attachment]?
    }
    
    // MARK: - Writing Records
    
    public static func createRecord(
        with preparedSendData: MessageSender.PreparedSendData,
        updatedMessage: Message,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        let message: DeadlockMessage = DeadlockMessage(
            variant: {
                switch preparedSendData.destination {
                    case .contact, .closedGroup:
                        return .outgoingMessage(
                            serverHash: updatedMessage.serverHash,
                            base64EncodedMessage: (preparedSendData.snodeMessage?.data ?? "")
                        )
                        
                    case .openGroup(let roomToken, let server, _, _, _):
                        return .outgoingOpenGroupMessage(
                            roomToken: roomToken,
                            server: server,
                            sender: updatedMessage.sender,
                            openGroupServerMessageId: updatedMessage.openGroupServerMessageId.map { Int64($0) },
                            openGroupMessageSeqNo: updatedMessage.openGroupMessageSeqNo,
                            openGroupMessagePosted: updatedMessage.openGroupMessagePosted,
                            base64EncodedMessage: (preparedSendData.plaintext?.base64EncodedString() ?? "")
                        )
                        
                    case .openGroupInbox(let server, _, let blindedPublicKey):
                        return .outgoingOpenGroupInboxMessage(
                            server: server,
                            recipientBlindedPublicKey: blindedPublicKey,
                            sender: updatedMessage.sender,
                            openGroupServerMessageId: updatedMessage.openGroupServerMessageId.map { Int64($0) },
                            openGroupMessagePosted: updatedMessage.openGroupMessagePosted,
                            openGroupMessageExpires: updatedMessage.openGroupMessageExpires,
                            base64EncodedMessage: (preparedSendData.ciphertext?.base64EncodedString() ?? "")
                        )
                }
            }(),
            attachments: preparedSendData.attachments?.map { $0.attachment }
        )
        
        try persist(message: message, using: dependencies)
    }
    
    public static func createRecord(
        with envelope: SNProtoEnvelope,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        let message: DeadlockMessage = DeadlockMessage(
            variant: .incomingMessage(try envelope.serializedData()),
            attachments: nil
        )
        
        try persist(message: message, using: dependencies)
    }
    
    public static func createRecord(
        with processedMessage: ProcessedMessage,
        callMessage: CallMessage,
        state: CallMessage.MessageInfo.State,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        let message: DeadlockMessage = DeadlockMessage(
            variant: .incomingCall(
                threadId: processedMessage.threadId,
                threadVariant: processedMessage.threadVariant,
                sentTimestamp: callMessage.sentTimestamp,
                state: state
            ),
            attachments: nil
        )
        
        try persist(message: message, using: dependencies)
    }
    
    public static func createConfigSyncRecord(
        publicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) {
        let message: DeadlockMessage = DeadlockMessage(
            variant: .configSync(publicKey),
            attachments: nil
        )
        
        do { try persist(message: message, using: dependencies) }
        catch { SNLog("[DeadlockWorkAround] Failed to persist configSyncRecord due to error: \(error)") }
    }
    
    private static func persist(message: DeadlockMessage, using dependencies: Dependencies) throws {
        OWSFileSystem.ensureDirectoryExists(DeadlockWorkAround.sharedDeadlockDirectoryPath)
        OWSFileSystem.protectFileOrFolder(atPath: DeadlockWorkAround.sharedDeadlockDirectoryPath)
        
        guard
            let nonce: [UInt8] = try? dependencies.crypto.perform(.generateNonce24()),
            var encKey: Data = try? DeadlockWorkAround.getOrGenerateEncryptionKey(using: dependencies)
        else { return }
        
        defer { encKey.resetBytes(in: 0..<encKey.count) } // Reset content immediately after use
        
        let timestampMs: Int = Int(Date().timeIntervalSince1970 * 1000)
        let filename: String = "\(timestampMs)-0-\(nonce.toHexString())"
        
        // Encode, encrypt and write the data to disk
        let encodedData: Data = try JSONEncoder().encode(message)
        let ciphertext: [UInt8] = try dependencies.crypto.perform(
            .encryptAeadXChaCha20(
                message: Array(encodedData),
                secretKey: Array(encKey),
                nonce: nonce,
                using: dependencies
            )
        )
        
        try Data(ciphertext)
            .write(to: URL(fileURLWithPath: "\(DeadlockWorkAround.sharedDeadlockDirectoryPath)/\(filename)"))
    }
    
    // MARK: - Reading Records
    
    public static func readProcessAndRemoveRecords(using dependencies: Dependencies = Dependencies()) throws {
        let filesToProcess: [String] = try FileManager.default
            .contentsOfDirectory(atPath: DeadlockWorkAround.sharedDeadlockDirectoryPath)
            .filter { $0 != ".DS_Store" }   // Ignoring for sim builds
        
        guard
            !filesToProcess.isEmpty,
            var encKey: Data = try? DeadlockWorkAround.getOrGenerateEncryptionKey(using: dependencies)
        else { return }
        
        defer { encKey.resetBytes(in: 0..<encKey.count) } // Reset content immediately after use
        
        let deadlockMessages: [(message: DeadlockMessage, filename: String)] = filesToProcess
            .compactMap { filename -> (DeadlockMessage, String)? in
                guard
                    let fileData: Data = try? Data(
                        contentsOf: URL(fileURLWithPath: "\(DeadlockWorkAround.sharedDeadlockDirectoryPath)/\(filename)")
                    ),
                    let nonce: [UInt8] = filename.split(separator: "-").last
                        .map({ Array(Data(hex: String($0))) }),
                    let plaintext: [UInt8] = try? dependencies.crypto.perform(
                        .decryptAeadXChaCha20(
                            authenticatedCipherText: Array(fileData),
                            secretKey: Array(encKey),
                            nonce: nonce
                        )
                    )
                else { return nil }
                
                return (try? JSONDecoder().decode(DeadlockMessage.self, from: Data(plaintext)))
                    .map { ($0, filename) }
            }
        
        // Process the messages which were successful
        dependencies.storage.write { db in
            try deadlockMessages.forEach { deadlockMessage, _ in
                switch deadlockMessage.variant {
                    case .incomingMessage(let envelopeData):
                        try processIncomingMessage(db, envelopeData: envelopeData, using: dependencies)
                        
                    case .incomingCall(let threadId, let threadVariant, let sentTimestamp, let state):
                        try processIncomingCallMessage(
                            db,
                            threadId: threadId,
                            threadVariant: threadVariant,
                            sentTimestamp: sentTimestamp,
                            state: state,
                            using: dependencies
                        )
                        
                    case .outgoingMessage, .outgoingOpenGroupMessage, .outgoingOpenGroupInboxMessage:
                        try processOutgoingMessage(db, message: deadlockMessage, using: dependencies)
                        
                    case .configSync(let publicKey):
                        processConfigSyncMessage(db, publicKey: publicKey, using: dependencies)
                }
            }
        }
        
        // Remove the files which were parsed successfully - only want to process them once
        // even if they failed
        let completedFilenames: [String] = deadlockMessages.map { $0.filename }
        completedFilenames.forEach { filename in
            try? FileManager.default.removeItem(atPath: "\(DeadlockWorkAround.sharedDeadlockDirectoryPath)/\(filename)")
        }
        
        // Log that a number of failed files and increment the failure count
        let filesToUpdate: [(old: String, new: String, shouldDelete: Bool)] = filesToProcess
            .filter { !completedFilenames.contains($0) }
            .map { filename -> (String, String, Bool) in
                let filenameParts: [String] = filename.split(separator: "-").map { String($0) }
                let errorCount: Int = filenameParts
                    .dropFirst()
                    .first
                    .map { Int($0) }
                    .defaulting(to: 1)
                let updatedErrorCount: Int = (errorCount + 1)
                
                guard
                    let timestampString: String = filenameParts.first,
                    let nonceString: String = filenameParts.last
                else { return (filename, "", true) }
                
                return (
                    filename,
                    "\(timestampString)-\(updatedErrorCount)-\(nonceString)",
                    (updatedErrorCount >= 2)
                )
            }
        let numToRemove: Int = filesToUpdate.filter { $0.shouldDelete }.count
        SNLog("[DeadlockWorkAround] Completed processing \(deadlockMessages.count) message\(deadlockMessages.count == 1 ? "" : "s") (ignoring \(numToRemove) message\(numToRemove == 1 ? "" : "s"))")
    
        // Remove/Rename remaining files
        filesToUpdate
            .forEach { old, new, shouldRemove in
                guard !shouldRemove else {
                    try? FileManager.default.removeItem(atPath: old)
                    return
                }
                
                try? FileManager.default.moveItem(atPath: old, toPath: new)
            }
    }
    
    private static func processIncomingMessage(
        _ db: Database,
        envelopeData: Data,
        using dependencies: Dependencies
    ) throws {
        guard
            let envelope: SNProtoEnvelope = try? SNProtoEnvelope.parseData(envelopeData),
            let processedMessage: ProcessedMessage = try Message.processRawReceivedMessageAsNotification(db, envelope: envelope)
        else { return }
        
        try MessageReceiver.handle(
            db,
            threadId: processedMessage.threadId,
            threadVariant: processedMessage.threadVariant,
            message: processedMessage.messageInfo.message,
            serverExpirationTimestamp: processedMessage.messageInfo.serverExpirationTimestamp,
            associatedWithProto: processedMessage.proto
        )
    }
    
    private static func processIncomingCallMessage(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        sentTimestamp: UInt64?,
        state: CallMessage.MessageInfo.State,
        using dependencies: Dependencies
    ) throws {
        _ = try MessageReceiver.createInteraction(
            db,
            threadId: threadId,
            threadVariant: threadVariant,
            message: Message(sentTimestamp: sentTimestamp, sender: threadId),
            customBody: try CallMessage.MessageInfo(state: state)
                .messageInfoString(),
            interactionVariant: .infoCall,
            associatedWithProto: nil,
            currentUserPublicKey: getUserHexEncodedPublicKey(db, using: dependencies)
        ).inserted(db)
    }
    
    private static func processOutgoingMessage(
        _ db: Database,
        message: DeadlockMessage,
        using dependencies: Dependencies
    ) throws {
        switch message.variant {
            case .outgoingMessage(let serverHash, let base64EncodedMessage):
                guard
                    let envelopeData: Data = Data(base64Encoded: base64EncodedMessage),
                    let envelope: SNProtoEnvelope = try? MessageWrapper.unwrap(data: envelopeData),
                    let processedMessage: ProcessedMessage = try? Message.processRawReceivedMessage(
                        db,
                        envelope: envelope,
                        serverHash: serverHash
                    )
                else { return }
                
                try MessageReceiver.handle(
                    db,
                    threadId: processedMessage.threadId,
                    threadVariant: processedMessage.messageInfo.threadVariant,
                    message: processedMessage.messageInfo.message,
                    preparedAttachments: message.attachments?
                        .reduce(into: [:]) { result, next in result[next.serverId ?? ""] = next },
                    serverExpirationTimestamp: processedMessage.messageInfo.serverExpirationTimestamp,
                    associatedWithProto: processedMessage.proto
                )
                
            case .outgoingOpenGroupMessage(
                let roomToken,
                let server,
                let sender,
                let openGroupServerMessageId,
                let openGroupMessageSeqNo,
                let openGroupMessagePosted,
                let base64EncodedMessage
            ):
                let openGroupId: String = OpenGroup.idFor(roomToken: roomToken, server: server)
                
                guard
                    let openGroup: OpenGroup = try? OpenGroup.fetchOne(db, id: openGroupId),
                    let openGroupMessage: OpenGroupAPI.Message = OpenGroupAPI.Message(
                        id: openGroupServerMessageId,
                        sender: sender,
                        posted: openGroupMessagePosted,
                        seqNo: openGroupMessageSeqNo,
                        base64EncodedData: base64EncodedMessage
                    ),
                    let messageData: Data = Data(base64Encoded: base64EncodedMessage),
                    let processedMessage: ProcessedMessage = try? Message.processReceivedOpenGroupMessage(
                        db,
                        openGroupId: openGroupId,
                        openGroupServerPublicKey: openGroup.publicKey,
                        message: openGroupMessage,
                        data: messageData,
                        using: dependencies
                    )
                else { return }
                
                try MessageReceiver.handle(
                    db,
                    threadId: openGroup.id,
                    threadVariant: .community,
                    message: processedMessage.messageInfo.message,
                    preparedAttachments: message.attachments?
                        .reduce(into: [:]) { result, next in result[next.serverId ?? ""] = next },
                    serverExpirationTimestamp: processedMessage.messageInfo.serverExpirationTimestamp,
                    associatedWithProto: processedMessage.proto,
                    using: dependencies
                )
                
            case .outgoingOpenGroupInboxMessage(
                let server,
                let recipientBlindedPublicKey,
                let sender,
                let openGroupServerMessageId,
                let openGroupMessagePosted,
                let openGroupMessageExpires,
                let base64EncodedMessage
            ):
                guard
                    let openGroupServerMessageId: Int64 = openGroupServerMessageId,
                    let sender: String = sender,
                    let posted: TimeInterval = openGroupMessagePosted,
                    let expires: TimeInterval = openGroupMessageExpires
                else { return }
                
                OpenGroupManager.handleDirectMessages(
                    db,
                    messages: [
                        OpenGroupAPI.DirectMessage(
                            id: openGroupServerMessageId,
                            sender: sender,
                            recipient: recipientBlindedPublicKey,
                            posted: posted,
                            expires: expires,
                            base64EncodedMessage: base64EncodedMessage
                        )
                    ],
                    fromOutbox: true,
                    on: server,
                    using: dependencies
                )
                
            case .incomingMessage, .incomingCall, .configSync: break
        }
    }
    
    private static func processConfigSyncMessage(
        _ db: Database,
        publicKey: String,
        using dependencies: Dependencies
    ) {
        ConfigurationSyncJob.enqueue(db, publicKey: publicKey, dependencies: dependencies)
    }
    
    // MARK: - Security
    
    @discardableResult private static func getOrGenerateEncryptionKey(using dependencies: Dependencies) throws -> Data {
        do {
            var encryptionKey: Data = try SSKDefaultKeychainStorage.shared.data(
                forService: keychainService,
                key: encryptionKeyKey
            )
            defer { encryptionKey.resetBytes(in: 0..<encryptionKey.count) }
            
            guard encryptionKey.count == encryptionKeyLength else { throw StorageError.invalidKeySpec }
            
            return encryptionKey
        }
        catch {
            switch (error, (error as? KeychainStorageError)?.code) {
                case (StorageError.invalidKeySpec, _), (_, errSecItemNotFound):
                    // No keySpec was found so we need to generate a new one
                    do {
                        var keySpec: Data = try Randomness.generateRandomBytes(numberBytes: encryptionKeyLength)
                        defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
                        
                        try SSKDefaultKeychainStorage.shared.set(
                            data: keySpec,
                            service: keychainService,
                            key: encryptionKeyKey
                        )
                        return keySpec
                    }
                    catch {
                        SNLog("[DeadlockWorkAround] Setting keychain value failed with error: \(error.localizedDescription)")
                        throw StorageError.keySpecCreationFailed
                    }
                    
                default:
                    // Because we use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, the keychain will be inaccessible
                    // after device restart until device is unlocked for the first time. If the app receives a push
                    // notification, we won't be able to access the keychain to process that notification, so we should
                    // just terminate by throwing an uncaught exception
                    if CurrentAppContext().isMainApp || CurrentAppContext().isInBackground() {
                        let appState: UIApplication.State = CurrentAppContext().reportedApplicationState
                        SNLog("[DeadlockWorkAround] CipherKeySpec inaccessible. New install or no unlock since device restart?, ApplicationState: \(NSStringForUIApplicationState(appState))")
                        throw StorageError.keySpecInaccessible
                    }
                    
                    SNLog("[DeadlockWorkAround] CipherKeySpec inaccessible; not main app.")
                    throw StorageError.keySpecInaccessible
            }
        }
    }
}
