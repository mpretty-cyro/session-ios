// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class NetworkLayerViewModel: SessionTableViewModel<NoNav, NetworkLayerViewModel.Section, RequestAPI.NetworkLayer> {
    private let storage: Storage
    private let scheduler: ValueObservationScheduler
    
    // MARK: - Initialization
    
    init(
        storage: Storage = Storage.shared,
        scheduling scheduler: ValueObservationScheduler = Storage.defaultPublisherScheduler
    ) {
        self.storage = storage
        self.scheduler = scheduler
    }
    
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case content
    }
    
    // MARK: - Content
    
    override var title: String { "Network Layer" }
    
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
        .trackingConstantRegion { [storage] db -> [SectionModel] in
            let currentSelection: RequestAPI.NetworkLayer? = db[.debugNetworkLayer]
                .defaulting(to: .onionRequest)
            
            return [
                SectionModel(
                    model: .content,
                    elements: RequestAPI.NetworkLayer.allCases
                        .map { networkLayer in
                            SessionCell.Info(
                                id: networkLayer,
                                title: networkLayer.name,
                                rightAccessory: .radio(
                                    isSelected: { (currentSelection == networkLayer) }
                                ),
                                onTap: { [weak self] in
                                    storage.write { db in
                                        db[.debugNetworkLayer] = networkLayer
                                    }
                                    
                                    RequestAPI.NetworkLayer.didChangeNetworkLayer()
                                    self?.dismissScreen()
                                }
                            )
                        }
                )
            ]
        }
        .removeDuplicates()
        .publisher(in: storage, scheduling: scheduler)
    
    // MARK: - Functions

    public override func updateSettings(_ updatedSettings: [SectionModel]) {
        self._settingsData = updatedSettings
    }
}
