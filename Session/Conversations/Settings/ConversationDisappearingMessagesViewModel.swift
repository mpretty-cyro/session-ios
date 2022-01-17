// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionMessagingKit
import SessionUtilitiesKit

class ConversationDisappearingMessagesViewModel {
    private var disappearingMessageConfiguration: OWSDisappearingMessagesConfiguration?
    
    // MARK: - Initialization
    
    init(disappearingMessageConfiguration: OWSDisappearingMessagesConfiguration?) {
        self.disappearingMessageConfiguration = disappearingMessageConfiguration
    }
    
    // MARK: - Data
    
    let title: String = NSLocalizedString("DISAPPEARING_MESSAGES", comment: "label in conversation settings")
    
    lazy var items: [(title: String, isActive: Bool)] = {
        //disappearingMessageConfiguration?.durationIndex
        //
        // TODO: Dynamically update
        [NSLocalizedString("DISAPPEARING_MESSAGES_OFF", comment: "label in conversation settings")]
            .appending(
                contentsOf: OWSDisappearingMessagesConfiguration.validDurationsSeconds()
                    .map { seconds in NSString.formatDurationSeconds(UInt32(seconds.intValue), useShortFormat: false) }
            )
            .enumerated()
            .map { [weak self] index, title -> (String, Bool) in
                // Need to '- 1' as the "Off" option ins't included in the 'validDurationsSeconds' set
                (title, ((self?.disappearingMessageConfiguration?.durationIndex ?? 0) == (index - 1)))
            }
    }()
}
