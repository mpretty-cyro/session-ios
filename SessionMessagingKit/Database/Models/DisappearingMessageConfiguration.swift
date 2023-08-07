// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

public struct DisappearingMessagesConfiguration: Codable, Identifiable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "disappearingMessagesConfiguration" }
    internal static let threadForeignKey = ForeignKey([Columns.threadId], to: [SessionThread.Columns.id])
    private static let thread = belongsTo(SessionThread.self, using: threadForeignKey)
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case threadId
        case isEnabled
        case durationSeconds
    }
    
    public enum DisappearingMessageType: Int, Codable, Hashable, DatabaseValueConvertible {
        case disappearAfterRead
        case disappearAfterSend
    }
    
    public var id: String { threadId }  // Identifiable

    public let threadId: String
    public let isEnabled: Bool
    public let durationSeconds: TimeInterval
    public var type: DisappearingMessageType? { return nil }    // TODO: Add as part of Disappearing Message Rebuild
    
    // MARK: - Relationships
    
    public var thread: QueryInterfaceRequest<SessionThread> {
        request(for: DisappearingMessagesConfiguration.thread)
    }
}

// MARK: - Mutation

public extension DisappearingMessagesConfiguration {
    static let defaultDuration: TimeInterval = (24 * 60 * 60)
    
    static func defaultWith(_ threadId: String) -> DisappearingMessagesConfiguration {
        return DisappearingMessagesConfiguration(
            threadId: threadId,
            isEnabled: false,
            durationSeconds: defaultDuration
        )
    }
    
    func with(
        isEnabled: Bool? = nil,
        durationSeconds: TimeInterval? = nil,
        type: DisappearingMessageType? = nil
    ) -> DisappearingMessagesConfiguration {
        return DisappearingMessagesConfiguration(
            threadId: threadId,
            isEnabled: (isEnabled ?? self.isEnabled),
            durationSeconds: (durationSeconds ?? self.durationSeconds)
        )
    }
}

// MARK: - Convenience

public extension DisappearingMessagesConfiguration {
    struct MessageInfo: Codable {
        public let senderName: String?
        public let isEnabled: Bool
        public let durationSeconds: TimeInterval
        
        var previewText: String {
            guard let senderName: String = senderName else {
                // Changed by this device or via synced transcript
                guard isEnabled, durationSeconds > 0 else { return "YOU_DISABLED_DISAPPEARING_MESSAGES_CONFIGURATION".localized() }
                
                return String(
                    format: "YOU_UPDATED_DISAPPEARING_MESSAGES_CONFIGURATION".localized(),
                    floor(durationSeconds).formatted(format: .long)
                )
            }
            
            guard isEnabled, durationSeconds > 0 else {
                return String(format: "OTHER_DISABLED_DISAPPEARING_MESSAGES_CONFIGURATION".localized(), senderName)
            }
            
            return String(
                format: "OTHER_UPDATED_DISAPPEARING_MESSAGES_CONFIGURATION".localized(),
                senderName,
                floor(durationSeconds).formatted(format: .long)
            )
        }
    }
    
    var durationString: String {
        floor(durationSeconds).formatted(format: .long)
    }
    
    func messageInfoString(with senderName: String?) -> String? {
        let messageInfo: MessageInfo = DisappearingMessagesConfiguration.MessageInfo(
            senderName: senderName,
            isEnabled: isEnabled,
            durationSeconds: durationSeconds
        )
        
        guard let messageInfoData: Data = try? JSONEncoder().encode(messageInfo) else { return nil }
        
        return String(data: messageInfoData, encoding: .utf8)
    }
}

// MARK: - UI Constraints

extension DisappearingMessagesConfiguration {
    public static var validDurationsSeconds: [TimeInterval] {
        return [
            5,
            10,
            30,
            (1 * 60),
            (5 * 60),
            (30 * 60),
            (1 * 60 * 60),
            (6 * 60 * 60),
            (12 * 60 * 60),
            (24 * 60 * 60),
            (7 * 24 * 60 * 60)
        ]
    }
    
    public static var maxDurationSeconds: TimeInterval = {
        return (validDurationsSeconds.max() ?? 0)
    }()
}
