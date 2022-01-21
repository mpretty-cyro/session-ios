// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

class ClosureBarButtonItem: UIBarButtonItem {
    private class Target {
        private let callback: () -> ()
        
        init(callback: @escaping () -> ()) {
            self.callback = callback
        }
        
        @objc fileprivate func onPress() {
            self.callback()
        }
    }
    
    private var actionTarget: Target?
    
    // MARK: - Initialization
    
    convenience init(barButtonSystemItem: UIBarButtonItem.SystemItem, callback: @escaping () -> ()) {
        let actionTarget: Target = Target(callback: callback)
        
        self.init(barButtonSystemItem: barButtonSystemItem, target: actionTarget, action: #selector(Target.onPress))
        
        self.actionTarget = actionTarget
    }
    
    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        preconditionFailure("use init(barButtonSystemItem:callback:) instead")
    }
}
