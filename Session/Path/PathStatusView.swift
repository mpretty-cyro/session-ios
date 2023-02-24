// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Reachability
import SessionUIKit
import SessionSnodeKit

final class PathStatusView: UIView {
    enum Size {
        case small
        case large
        
        var pointSize: CGFloat {
            switch self {
                case .small: return 8
                case .large: return 16
            }
        }
        
        func offset(for interfaceStyle: UIUserInterfaceStyle) -> CGFloat {
            switch self {
                case .small: return (interfaceStyle == .light ? 6 : 8)
                case .large: return (interfaceStyle == .light ? 6 : 8)
            }
        }
    }
    
    enum Status {
        case unknown
        case connecting
        case connected
        case error
        
        var textThemeColor: ThemeValue {
            switch self {
                case .unknown: return .white
                case .connecting: return .white
                case .connected: return .black
                case .error: return .white
            }
        }
        
        var themeColor: ThemeValue {
            switch self {
                case .unknown: return .path_unknown
                case .connecting: return .path_connecting
                case .connected: return .path_connected
                case .error: return .path_error
            }
        }
    }
    
    // MARK: - UI
    
    private lazy var layerLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: 6)
        result.textAlignment = .center
        
        return result
    }()
    
    // MARK: - Initialization
    
    public let size: Size
    private let networkLayer: RequestAPI.NetworkLayer
    private let reachability: Reachability = Reachability.forInternetConnection()
    
    init(size: Size = .small, networkLayer: RequestAPI.NetworkLayer) {
        self.size = size
        self.networkLayer = networkLayer
        
        super.init(frame: .zero)
        
        setUpViewHierarchy(networkLayer: networkLayer)
        registerObservers(networkLayer: networkLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("use init(size:) instead")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Layout
    
    private func setUpViewHierarchy(networkLayer: RequestAPI.NetworkLayer) {
        layer.cornerRadius = (self.size.pointSize / 2)
        layer.masksToBounds = false
        self.set(.width, to: self.size.pointSize)
        self.set(.height, to: self.size.pointSize)
        
        addSubview(layerLabel)
        layerLabel.pin(to: self, withInset: 2)
        
        let currentLayer: RequestAPI.NetworkLayer = Storage.shared[.debugNetworkLayer]
            .defaulting(to: .onionRequest)
        
        switch networkLayer {
            case .onionRequest:
                layerLabel.text = "O"
                setStatus(to: (!OnionRequestAPI.paths.isEmpty ? .connected : .connecting))
                
            case .lokinet:
                layerLabel.text = "L"
                setStatus(to: (LokinetWrapper.isReady ? .connected : .connecting))
                
            case .nativeLokinet: break
                
            case .direct:
                layerLabel.text = "D"
                setStatus(to: .connected)
        }
        
        // For the settings view we want to change the path colour to gray if it's not currently active
        switch (networkLayer != currentLayer, reachability.isReachable(), OnionRequestAPI.paths.isEmpty) {
            case (true, _, _): setStatus(to: .unknown)
            case (_, false, _): setStatus(to: .error)
            case (_, true, true): setStatus(to: .connecting)
            case (_, true, false): setStatus(to: .connected)
        }
    }
    
    // MARK: - Functions
    
    private func registerObservers(networkLayer: RequestAPI.NetworkLayer) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNetworkLayerChangedNotification),
            name: .networkLayerChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBuildingPathsNotification),
            name: .buildingPaths,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePathsBuiltNotification),
            name: .pathsBuilt,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBuildingPathsLokiNotification),
            name: .buildingPathsLoki,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePathsBuiltLokiNotification),
            name: .pathsBuiltLoki,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDirectNetworkReadyNotification),
            name: .directNetworkReady,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reachabilityChanged),
            name: .reachabilityChanged,
            object: nil
        )
    }

    private func setStatus(to status: Status) {
        layerLabel.themeTextColor = status.textThemeColor
        themeBackgroundColor = status.themeColor
        layer.themeShadowColor = status.themeColor
        layer.shadowOffset = CGSize(width: 0, height: 0.8)
        layer.shadowPath = UIBezierPath(
            ovalIn: CGRect(
                origin: CGPoint.zero,
                size: CGSize(width: self.size.pointSize, height: self.size.pointSize)
            )
        ).cgPath
        
        ThemeManager.onThemeChange(observer: self) { [weak self] theme, _ in
            self?.layer.shadowOpacity = (theme.interfaceStyle == .light ? 0.4 : 1)
            self?.layer.shadowRadius = (self?.size.offset(for: theme.interfaceStyle) ?? 0)
        }
    }
    
    // MARK: - Notification Handling
    
    @objc private func handleNetworkLayerChangedNotification() {
        let newLayer: RequestAPI.NetworkLayer = Storage.shared[.debugNetworkLayer]
            .defaulting(to: .onionRequest)
        
        switch (networkLayer, newLayer) {
            case (.onionRequest, .onionRequest):
                setStatus(to: (!OnionRequestAPI.paths.isEmpty ? .connected : .connecting))
                
            case (.lokinet, .lokinet):
                setStatus(to: (LokinetWrapper.isReady ? .connected : .connecting))
                
            case (.nativeLokinet, .nativeLokinet): fallthrough
            case (.direct, .direct):
                setStatus(to: .connected)
                
            default:
                setStatus(to: .unknown)
        }
    }

    @objc private func handleBuildingPathsNotification() {
        switch networkLayer {
            case .onionRequest:
                setStatus(to: .connecting)
                
            case .lokinet: fallthrough
            case .nativeLokinet: fallthrough
            case .direct:
                setStatus(to: .unknown)
        }
    }

    @objc private func handlePathsBuiltNotification() {
        guard reachability.isReachable() else {
            setStatus(to: .error)
            return
        }
        
        switch networkLayer {
            case .onionRequest:
                setStatus(to: .connected)
                
            case .lokinet: fallthrough
            case .nativeLokinet: fallthrough
            case .direct:
                setStatus(to: .unknown)
        }
    }
    
    @objc private func handleBuildingPathsLokiNotification() {
        switch networkLayer {
            case .lokinet:
                setStatus(to: .connecting)
                
            case .onionRequest: fallthrough
            case .nativeLokinet: fallthrough
            case .direct:
                setStatus(to: .unknown)
        }
    }

    @objc private func handlePathsBuiltLokiNotification() {
        guard reachability.isReachable() else {
            setStatus(to: .error)
            return
        }
        
        switch networkLayer {
            case .lokinet:
                setStatus(to: .connected)
                
            case .onionRequest: fallthrough
            case .nativeLokinet: fallthrough
            case .direct:
                setStatus(to: .unknown)
        }
    }
    
    @objc private func handleDirectNetworkReadyNotification() {
        switch networkLayer {
            case .nativeLokinet: fallthrough
            case .direct:
                setStatus(to: .connected)
                
            case .onionRequest: fallthrough
            case .lokinet:
                setStatus(to: .unknown)
        }
    }
    
    @objc private func reachabilityChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.reachabilityChanged() }
            return
        }
        
        guard reachability.isReachable() else {
            setStatus(to: .error)
            return
        }
        
        switch networkLayer {
            case .onionRequest: setStatus(to: (!OnionRequestAPI.paths.isEmpty ? .connected : .connecting))
            case .lokinet: setStatus(to: (LokinetWrapper.isReady ? .connected : .connecting))
            case .nativeLokinet: setStatus(to: .connected)
            case .direct: setStatus(to: .connected)
        }
    }
}
