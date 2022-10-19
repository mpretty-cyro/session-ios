// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class ThreadNotificationSettingsViewModel: SessionTableViewModel<ThreadNotificationSettingsViewModel.NavButton, ThreadNotificationSettingsViewModel.Section, ThreadNotificationSettingsViewModel.Item> {
    // MARK: - Config
    
    enum NavButton: Equatable {
        case cancel
        case save
    }
    
    public enum Section: SessionTableSection {
        case content
    }
    
    public struct Item: Equatable, Hashable, Differentiable {
        let title: String
        
        public var differenceIdentifier: String { title }
    }
    
    // MARK: - Variables
    
    private let dependencies: Dependencies
    private let threadId: String
    private var storedSelection: SessionThreadViewModel.NotificationOption
    private var currentSelection: CurrentValueSubject<SessionThreadViewModel.NotificationOption, Never>
    
    // MARK: - Initialization
    
    init(
        dependencies: Dependencies = Dependencies(),
        threadId: String,
        notificationOption: SessionThreadViewModel.NotificationOption
    ) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.storedSelection = notificationOption
        self.currentSelection = CurrentValueSubject(notificationOption)
    }
    
    // MARK: - Navigation
    
    override var leftNavItems: AnyPublisher<[NavItem]?, Never> {
        Just([
            NavItem(
                id: .cancel,
                systemItem: .cancel,
                accessibilityIdentifier: "Cancel button"
            ) { [weak self] in self?.dismissScreen() }
        ]).eraseToAnyPublisher()
    }

    override var rightNavItems: AnyPublisher<[NavItem]?, Never> {
        currentSelection
            .removeDuplicates()
            .map { [weak self] currentSelection in (self?.storedSelection != currentSelection) }
            .map { isChanged in
                guard isChanged else { return [] }
                
                return [
                    NavItem(
                        id: .save,
                        systemItem: .save,
                        accessibilityIdentifier: "Save button"
                    ) { [weak self] in
                        self?.saveChanges()
                        self?.dismissScreen()
                    }
                ]
            }
           .eraseToAnyPublisher()
    }
    
    // MARK: - Content
    
    override var title: String { "NOTIFICATIONS_TITLE".localized() }
    
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
        .trackingConstantRegion { [weak self] db -> [SectionModel] in
            return [
                SectionModel(
                    model: .content,
                    elements: SessionThreadViewModel.NotificationOption.allCases
                        .map { option in
                            SessionCell.Info(
                                id: Item(title: option.title),
                                title: option.title,
                                rightAccessory: .radio(
                                    isSelected: { (self?.currentSelection.value == option) }
                                ),
                                onTap: { self?.currentSelection.send(option) }
                            )
                        }
                )
            ]
        }
        .removeDuplicates()
        .publisher(in: dependencies.storage, scheduling: dependencies.scheduler)
    
    // MARK: - Functions

    public override func updateSettings(_ updatedSettings: [SectionModel]) {
        self._settingsData = updatedSettings
    }
    
    private func saveChanges() {
        let threadId: String = self.threadId
        let updatedSelection: SessionThreadViewModel.NotificationOption = self.currentSelection.value
        
        guard self.storedSelection != updatedSelection else { return }
        
        dependencies.storage.writeAsync { db in
            try SessionThread
                .filter(id: threadId)
                .updateAll(
                    db,
                    SessionThread.Columns.mutedUntilTimestamp
                        .set(to: (updatedSelection == .mute ?
                            Date.distantFuture.timeIntervalSince1970 :
                            nil
                         )),
                    SessionThread.Columns.onlyNotifyForMentions
                        .set(to: (updatedSelection == .mentionsOnly))
                )
        }
    }
}
