// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import SessionMessagingKit
import SessionUtilitiesKit

class ConversationNotificationSettingsViewModel {
    struct Item: Equatable {
        enum Id {
            case all
            case mentionsOnly
            case mute
        }
            
        let id: Id
        let title: String
        let isActive: Bool
        
        // Convenience
        
        func with(
            isActive: Bool? = nil
        ) -> Item {
            return Item(
                id: id,
                title: title,
                isActive: (isActive ?? self.isActive)
            )
        }
    }
    
    // MARK: - Variables
    
    private let thread: TSGroupThread
    private let dataChanged: () -> ()
    
    // MARK: - Initialization
    
    init(thread: TSGroupThread, dataChanged: @escaping () -> ()) {
        self.thread = thread
        self.dataChanged = dataChanged
    }
    
    // MARK: - Input
    
    let itemSelected: PassthroughSubject<Item.Id, Never> = PassthroughSubject()
    
    // MARK: - Content
    
    let title: String = NSLocalizedString("CONVERSATION_SETTINGS_MESSAGE_NOTIFICATIONS", comment: "")
    
    lazy var items: AnyPublisher<[Item], Never> = {
        itemSelected
            .flatMap { [weak self] selectedId -> Future<Void, Never> in
                Future { promise in
                    switch selectedId {
                        case .all:
                            Storage.write { transaction in
                                self?.thread.setIsOnlyNotifyingForMentions(false, with: transaction)
                                self?.thread.updateWithMuted(until: nil, transaction: transaction)
                                
                                promise(.success(()))
                                self?.dataChanged()
                            }
                            
                        case .mentionsOnly:
                            Storage.write { transaction in
                                self?.thread.setIsOnlyNotifyingForMentions(true, with: transaction)
                                self?.thread.updateWithMuted(until: nil, transaction: transaction)

                                promise(.success(()))
                                self?.dataChanged()
                            }
                            
                        case .mute:
                            Storage.write { transaction in
                                self?.thread.setIsOnlyNotifyingForMentions(false, with: transaction)
                                self?.thread.updateWithMuted(until: Date.distantFuture, transaction: transaction)

                                promise(.success(()))
                                self?.dataChanged()
                            }
                    }
                }
            }
            .prepend(())    // Trigger for initial load
            .compactMap { [weak self] _ -> [Item]? in
                guard let thread: TSGroupThread = self?.thread else { return nil }
                
                return [
                    Item(
                        id: .all,
                        title: "vc_conversation_notifications_settings_all_title".localized(),
                        isActive: (!thread.isMuted && !thread.isOnlyNotifyingForMentions)
                    ),
                    
                    Item(
                        id: .mentionsOnly,
                        title: "vc_conversation_notifications_settings_mentions_only_title".localized(),
                        isActive: thread.isOnlyNotifyingForMentions
                    ),
                    
                    Item(
                        id: .mute,
                        title: "vc_conversation_notifications_settings_mute_title".localized(),
                        isActive: thread.isMuted
                    )
                ]
            }
            .shareReplay(1)
            .eraseToAnyPublisher()
    }()
}
