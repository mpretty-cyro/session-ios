// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class ConversationSettingsViewModel: SessionTableViewModel<NoNav, ConversationSettingsViewModel.Section, ConversationSettingsViewModel.Section> {
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case messageTrimming
        case audioMessages
        case blockedContacts
        
        var title: String? {
            switch self {
                case .messageTrimming: return "CONVERSATION_SETTINGS_SECTION_MESSAGE_TRIMMING".localized()
                case .audioMessages: return "CONVERSATION_SETTINGS_SECTION_AUDIO_MESSAGES".localized()
                case .blockedContacts: return nil
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .blockedContacts: return .padding
                default: return .title
            }
        }
    }
    
    // MARK: - Content
    
    override var title: String { "CONVERSATION_SETTINGS_TITLE".localized() }
    
    private var _settingsData: [SectionModel] = []
    public override var settingsData: [SectionModel] { _settingsData }
    
    public override var observableSettingsData: ObservableData { _observableSettingsData }
    
    /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
    /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
    ///
    /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
    /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
    /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
    /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
    private lazy var _observableSettingsData: ObservableData = ValueObservation
        .trackingConstantRegion { db -> [SectionModel] in
            return [
                SectionModel(
                    model: .messageTrimming,
                    elements: [
                        SessionCell.Info(
                            id: .messageTrimming,
                            title: "CONVERSATION_SETTINGS_MESSAGE_TRIMMING_TITLE".localized(),
                            subtitle: "CONVERSATION_SETTINGS_MESSAGE_TRIMMING_DESCRIPTION".localized(),
                            rightAccessory: .toggle(
                                .settingBool(key: .trimOpenGroupMessagesOlderThanSixMonths)
                            ),
                            onTap: {
                                Storage.shared.write { db in
                                    db[.trimOpenGroupMessagesOlderThanSixMonths] = !db[.trimOpenGroupMessagesOlderThanSixMonths]
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .audioMessages,
                    elements: [
                        SessionCell.Info(
                            id: .audioMessages,
                            title: "CONVERSATION_SETTINGS_AUDIO_MESSAGES_AUTOPLAY_TITLE".localized(),
                            subtitle: "CONVERSATION_SETTINGS_AUDIO_MESSAGES_AUTOPLAY_DESCRIPTION".localized(),
                            rightAccessory: .toggle(
                                .settingBool(key: .shouldAutoPlayConsecutiveAudioMessages)
                            ),
                            onTap: {
                                Storage.shared.write { db in
                                    db[.shouldAutoPlayConsecutiveAudioMessages] = !db[.shouldAutoPlayConsecutiveAudioMessages]
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .blockedContacts,
                    elements: [
                        SessionCell.Info(
                            id: .blockedContacts,
                            title: "CONVERSATION_SETTINGS_BLOCKED_CONTACTS_TITLE".localized(),
                            tintColor: .danger,
                            shouldHaveBackground: false,
                            onTap: { [weak self] in
                                self?.transitionToScreen(BlockedContactsViewController())
                            }
                        )
                    ]
                )
            ]
        }
        .removeDuplicates()
        .publisher(in: Storage.shared)
    
    // MARK: - Functions

    public override func updateSettings(_ updatedSettings: [SectionModel]) {
        self._settingsData = updatedSettings
    }
}
