// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Reachability
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit

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
        result.text = targetLayers.name
            .replacingOccurrences(of: " and ", with: ", ")
            .components(separatedBy: ", ")
            .asSet()
            .sorted()
            .map { name in
                name
                    .components(separatedBy: " ")
                    .compactMap { $0.first.map { "\($0)" } }
                    .joined()
            }
            .joined(separator: "/")
        result.textAlignment = .center
        result.adjustsFontSizeToFitWidth = true
        result.numberOfLines = 2
        
        return result
    }()
    
    // MARK: - Initialization
    
    private let size: Size
    private let targetLayers: Network.Layers
    private let reachability: Reachability? = Environment.shared?.reachabilityManager.reachability
    
    init(size: Size = .small, targetLayers: Network.Layers) {
        self.size = size
        self.targetLayers = targetLayers
        
        super.init(frame: .zero)
        
        setUpViewHierarchy()
        registerObservers()
    }
    
    required init?(coder: NSCoder) {
        fatalError("use init(size:) instead")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Layout
    
    private func setUpViewHierarchy() {
        layer.cornerRadius = (self.size.pointSize / 2)
        layer.masksToBounds = false
        self.set(.width, to: self.size.pointSize)
        self.set(.height, to: self.size.pointSize)
        
        addSubview(layerLabel)
        layerLabel.pin(to: self, withInset: 1)
        updateNetworkStatus()
    }
    
    // MARK: - Functions

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
    
    private func updateNetworkStatus() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateNetworkStatus() }
            return
        }
        
        let reachabilityStatus: Status = (reachability?.isReachable() == false ? .error : .connected)
        let onionRequestStatus: Status = (!OnionRequestAPI.paths.isEmpty ? .connected : .connecting)
        let lokinetStatus: Status = {
            guard !Lokinet.didError else { return .error }
            
            return (Lokinet.isReady ? .connected : .connecting)
        }()
        
        // Determine the applicable statuses and then update the state accordingly
        let allStatuses: [Status] = [
            reachabilityStatus,
            (targetLayers.contains(.onionRequest) ? onionRequestStatus : nil),
            (targetLayers.contains(.lokinet) ? lokinetStatus : nil)
        ].compactMap { $0 }
        
        guard !allStatuses.contains(.error) else { return setStatus(to: .error) }
        guard !allStatuses.contains(.unknown) else { return setStatus(to: .unknown) }
        guard !allStatuses.contains(.connecting) else { return setStatus(to: .connecting) }
        
        setStatus(to: .connected)
    }
    
    // MARK: - Notification Handling
    
    private func registerObservers() {
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
    
    @objc private func handleNetworkLayerChangedNotification() { updateNetworkStatus() }
    @objc private func handleBuildingPathsNotification() { updateNetworkStatus() }
    @objc private func handlePathsBuiltNotification() { updateNetworkStatus() }
    @objc private func handleBuildingPathsLokiNotification() { updateNetworkStatus() }
    @objc private func handlePathsBuiltLokiNotification() { updateNetworkStatus() }
    @objc private func handleDirectNetworkReadyNotification() { updateNetworkStatus() }
    @objc private func reachabilityChanged() { updateNetworkStatus() }
}
