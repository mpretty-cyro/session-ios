// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class NetworkLayerViewModel: SessionTableViewModel<NoNav, NetworkLayerViewModel.Section, Network.Layers> {
    private let dependencies: Dependencies
    private let currentSelectionSubject: CurrentValueSubject<Network.Layers, Error>
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        self.currentSelectionSubject = CurrentValueSubject(
            (dependencies.storage[.networkLayers]
                .map { Int8($0) }
                .map { Network.Layers(rawValue: $0) })
                .defaulting(to: .defaultLayers)
        )
    }
    
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case content
    }
    
    // MARK: - Content
    
    override var title: String { "Network Layers" }
    
    override var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> {
        currentSelectionSubject
            .catch { _ in Just([]).eraseToAnyPublisher() }
            .prepend([])
            .map { currentSelection in
                SessionButton.Info(
                    style: .destructive,
                    title: "Set",
                    isEnabled: !currentSelection.isEmpty,
                    onTap: { [weak self] in self?.saveChanges() }
                )
            }
            .eraseToAnyPublisher()
    }
    
    public override var observableTableData: ObservableData { _observableTableData }
    
    private lazy var _observableTableData: ObservableData = currentSelectionSubject
        .map { selectedLayers -> [SectionModel] in
            return [
                SectionModel(
                    model: .content,
                    elements: Network.Layers.all
                        .map { networkLayer in
                            SessionCell.Info(
                                id: networkLayer,
                                title: networkLayer.name,
                                subtitle: networkLayer.description,
                                rightAccessory: .radio(
                                    isSelected: { selectedLayers.contains(networkLayer) }
                                ),
                                onTap: { [weak self] in
                                    let updatedSelection: Network.Layers = (selectedLayers.contains(networkLayer) ?
                                        selectedLayers.subtracting(networkLayer) :
                                        selectedLayers.union(networkLayer)
                                    )
                                    self?.currentSelectionSubject.send(updatedSelection)
                                }
                            )
                        }
                )
            ]
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
        .mapToSessionTableViewData(for: self)
    
    // MARK: - Functions
    
    private func saveChanges() {
        let currentSelection: Network.Layers = self.currentSelectionSubject.value
        
        guard !currentSelection.isEmpty else { return }
        
        dependencies.storage.writeAsync(
            using: dependencies,
            updates: { db in db[.networkLayers] = Int(currentSelection.rawValue) },
            completion: { [weak self] _, _ in
                Network.Layers.didChangeNetworkLayer()
                self?.dismissScreen()
            }
        )
    }
}
