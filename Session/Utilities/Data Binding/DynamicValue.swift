// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

class DynamicValue<T> {
    typealias ChangeHandler = (T) -> Void
    
    private var observers: [Int: ChangeHandler] = [:]
    
    var value: T {
        didSet {
            // Let all observers know about the change
            observers.values.forEach { callback in
                callback(value)
            }
        }
    }

    // MARK: - Initialization

    init(_ value: T) {
        self.value = value
    }
    
    deinit {
        observers.removeAll()
    }
    
    // MARK: - Functions

    /// This function allows an observer to listen for changes to the value
    ///
    /// **Warning:** The `changeHandler`will be triggered from whatever thread the value is updated on which may not be the thread
    /// which the observer was added on
    ///
    /// - Parameter forceToMainThread: This will force the `changeHandler` to be called on the main thread (which is the default to simplify
    /// UI updates
    /// - Parameter firstOnly: This will mean the `changeHandler` only gets called once immediately and doesn't get triggered for
    /// changes
    /// - Parameter skipFirst: This will mean the `changeHander` doesn't get called immediately and only triggers on changes
    /// - Parameter changeHandler: This is the callback which gets triggered with the latest value
    @discardableResult public func onChange(
        forceToMainThread: Bool = true,
        firstOnly: Bool = false,
        skipFirst: Bool = false,
        changeHandler: @escaping ChangeHandler
    ) -> Listener {
        let identifier: Int = UUID().hashValue
        let finalChangeHandler: ChangeHandler = { value in
            guard forceToMainThread && !Thread.isMainThread else { return changeHandler(value) }
            
            DispatchQueue.main.async { changeHandler(value) }
        }
        
        // Some situations will mean we only want the first value, others we will only want changes
        if !firstOnly { observers[identifier] = finalChangeHandler }
        if !skipFirst { finalChangeHandler(value) }
        
        return Listener { [weak self] in
            self?.observers[identifier] = nil
        }
    }
}
