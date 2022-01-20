// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

class Interactions<Id: Hashable, DataType> {
    typealias Callback = (DataType) -> ()
    typealias IdentifiedCallback = (Id, DataType) -> ()
    
    /// Method to define what type of interaction should trigger the callback, this could be expanded to allow different interactions
    /// to trigger different behaviours (eg. swipe, longPress, etc.)
    enum Style: Hashable {
        case any
        case tap
    }
    struct IdentifiedInteraction<Id: Hashable>: Hashable {
        let id: Id?
        let style: Style
    }
    
    // MARK: - Variables
    
    private let dataProvider: () -> DataType?
    private var interactions: [IdentifiedInteraction<Id>: [Int: Callback]] = [:]
    private var anyInteractions: [Style: [Int: IdentifiedCallback]] = [:]
    
    // MARK: - Initialization
    
    init(_ dataProvider: @escaping (() -> DataType?)) {
        self.dataProvider = dataProvider
    }
    
    deinit {
        interactions.removeAll()
    }
    
    // MARK: - Internal Functions
    
    /// This function triggers the interaction callbacks for the given `id` and `style` as well as the `Style.any` callbacks for the `id` and
    /// the `onAny` interactions for either the `id` or the `style`
    private func interact(_ id: Id, style: Style) {
        guard let data: DataType = dataProvider() else { return }
        
        var targetInteractions: [Callback?]
        var targetAnyInteractions: [IdentifiedCallback?]
        
        // First populate the id-specific interactions for each style
        switch style {
            case .tap:
                targetInteractions = [
                    Array((interactions[IdentifiedInteraction(id: id, style: .tap)] ?? [:]).values),
                    Array((interactions[IdentifiedInteraction(id: id, style: .any)] ?? [:]).values)
                ].flatMap { $0 }
                
            case .any:
                targetInteractions = [
                    Array((interactions[IdentifiedInteraction(id: id, style: .tap)] ?? [:]).values),
                    Array((interactions[IdentifiedInteraction(id: id, style: .any)] ?? [:]).values)
                ].flatMap { $0 }
        }

        // Then populate the 'onAny' interactions for each style (ie. ones which trigger for every Id)
        switch style {
            case .tap:
                targetAnyInteractions = [
                    Array((anyInteractions[.tap] ?? [:]).values),
                    Array((anyInteractions[.any] ?? [:]).values)
                ].flatMap { $0 }
                
            case .any:
                targetAnyInteractions = [
                    Array((anyInteractions[.tap] ?? [:]).values),
                    Array((anyInteractions[.any] ?? [:]).values)
                ].flatMap { $0 }
        }
        
        // Finally actually run the interactions
        targetInteractions.forEach { $0?(data) }
        targetAnyInteractions.forEach { $0?(id, data) }
    }

    // MARK: - Observing Functions
    
    /// This function allows an observer to listen for interactions for a given event identifier
    ///
    /// - Parameter id: The event identifier to observe interactions for
    /// - Parameter style: The type of interactions to observe for
    /// - Parameter forceToMainThread: This will force the `callback` to be called on the main thread (which is the default
    /// to simplify UI updates), when `false` the callback will run on the current thread
    /// - Parameter callback: This is the callback which gets triggered when an interaction occurs
    @discardableResult public func on(
        _ id: Id,
        style: Style = .any,
        forceToMainThread: Bool = true,
        callback: @escaping Callback
    ) -> Listener {
        let identifier: IdentifiedInteraction<Id> = IdentifiedInteraction(id: id, style: style)
        let uniqueIdentifier: Int = UUID().hashValue
        let finalCallback: Callback = { data in
            guard forceToMainThread else { return callback(data) }
            
            DispatchQueue.main.async { callback(data) }
        }
        interactions[identifier] = (interactions[identifier] ?? [:]).setting(uniqueIdentifier, value: finalCallback)
        
        return Listener { [weak self] in
            var registeredInteractions: [Int: Callback] = (self?.interactions[identifier] ?? [:])
            registeredInteractions[uniqueIdentifier] = nil
            
            self?.interactions[identifier] = (registeredInteractions.isEmpty ? nil : registeredInteractions)
        }
    }
    
    /// This function allows an observer to listen for all interactions of a given style
    ///
    /// - Parameter style: The type of interactions to observe for
    /// - Parameter forceToMainThread: This will force the `callback` to be called on the main thread (which is the default
    /// to simplify UI updates), when `false` the callback will run on the current thread
    /// - Parameter callback: This is the callback which gets triggered when an interaction occurs
    @discardableResult public func onAny(
        style: Style = .any,
        forceToMainThread: Bool = true,
        callback: @escaping IdentifiedCallback
    ) -> Listener {
        let uniqueIdentifier: Int = UUID().hashValue
        let finalCallback: IdentifiedCallback = { id, data in
            guard forceToMainThread else { return callback(id, data) }
            
            DispatchQueue.main.async { callback(id, data) }
        }
        anyInteractions[style] = (anyInteractions[style] ?? [:]).setting(uniqueIdentifier, value: finalCallback)
        
        return Listener { [weak self] in
            var registeredAnyInteractions: [Int: IdentifiedCallback] = (self?.anyInteractions[style] ?? [:])
            registeredAnyInteractions[uniqueIdentifier] = nil
            
            self?.anyInteractions[style] = (registeredAnyInteractions.isEmpty ? nil : registeredAnyInteractions)
        }
    }
    
    // MARK: - Interaction Functions
    
    public func trigger(_ id: Id) {
        interact(id, style: .any)
    }
    
    public func tap(_ id: Id) {
        interact(id, style: .tap)
    }
}
