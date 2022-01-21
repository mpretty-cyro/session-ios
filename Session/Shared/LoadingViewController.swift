// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import NVActivityIndicatorView
import SessionUIKit

class LoadingViewController: UIViewController {
    // MARK: - UI
    
    private let loadingIndicator: NVActivityIndicatorView = {
        let view: NVActivityIndicatorView = NVActivityIndicatorView(
            frame: CGRect.zero,
            type: .circleStrokeSpin,
            color: (isLightMode ? .black : .white),
            padding: nil
        )
        view.translatesAutoresizingMaskIntoConstraints = false
        view.startAnimating()
        
        return view
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        
        view.addSubview(loadingIndicator)
        
        setupLayout()
    }
    
    // MARK: - Layout
    
    private func setupLayout() {
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            loadingIndicator.widthAnchor.constraint(equalToConstant: 24),
            loadingIndicator.heightAnchor.constraint(equalToConstant: 24)
        ])
    }
}
