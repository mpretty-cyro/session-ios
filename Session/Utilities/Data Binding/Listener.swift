// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

struct Listener {
    private let callback: () -> ()
    
    init(callback: @escaping () -> ()) {
        self.callback = callback
    }
    
    public func stop() {
        callback()
    }
}
