import UIKit
import SessionUIKit
import SessionSnodeKit

final class PathStatusView: UIView {
    
    static let size = CGFloat(10)
    
    private let networkLayer: RequestAPI.NetworkLayer
    
    private lazy var layerLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: 6)
        result.textAlignment = .center
        
        return result
    }()
    
    init(networkLayer: RequestAPI.NetworkLayer) {
        self.networkLayer = networkLayer
        
        super.init(frame: .zero)
        
        setUpViewHierarchy(networkLayer: networkLayer)
        registerObservers(networkLayer: networkLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("use init(layer:) instead")
    }
    
    private func setUpViewHierarchy(networkLayer: RequestAPI.NetworkLayer) {
        layer.cornerRadius = (PathStatusView.size / 2)
        layer.masksToBounds = false
        
        addSubview(layerLabel)
        layerLabel.pin(to: self, withInset: 2)
        
        let currentLayer: RequestAPI.NetworkLayer = (RequestAPI.NetworkLayer(rawValue: UserDefaults.standard[.networkLayer] ?? "") ?? .onionRequest)
        
        switch networkLayer {
            case .onionRequest:
                let color = (!OnionRequestAPI.paths.isEmpty ? Colors.accent : Colors.pathsBuilding)
                layerLabel.text = "O"
                setColor(to: color, isAnimated: false)
                
            case .lokinet:
                let color = (LokinetWrapper.isReady ? Colors.accent : Colors.pathsBuilding)
                layerLabel.text = "L"
                setColor(to: color, isAnimated: false)
                
            case .nativeLokinet: break
                
            case .direct:
                layerLabel.text = "D"
                setColor(to: Colors.accent, isAnimated: false)
        }
        
        // For the settings view we want to change the path colour to gray if it's not currently active
        if networkLayer != currentLayer {
            setColor(to: .lightGray, isAnimated: false)
        }
    }

    private func registerObservers(networkLayer: RequestAPI.NetworkLayer) {
        NotificationCenter.default.addObserver(self, selector: #selector(handleNetworkLayerChangedNotification), name: .networkLayerChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleBuildingPathsNotification), name: .buildingPaths, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handlePathsBuiltNotification), name: .pathsBuilt, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleBuildingPathsLokiNotification), name: .buildingPathsLoki, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handlePathsBuiltLokiNotification), name: .pathsBuiltLoki, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDirectNetworkReadyNotification), name: .directNetworkReady, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setColor(to color: UIColor, isAnimated: Bool) {
        backgroundColor = color
        let size = PathStatusView.size
        let glowConfiguration = UIView.CircularGlowConfiguration(size: size, color: color, isAnimated: isAnimated, radius: isLightMode ? 6 : 8)
        setCircularGlow(with: glowConfiguration)
    }
    
    @objc private func handleNetworkLayerChangedNotification() {
        let newLayer: RequestAPI.NetworkLayer = (RequestAPI.NetworkLayer(rawValue: UserDefaults.standard[.networkLayer] ?? "") ?? .onionRequest)
        
        switch (networkLayer, newLayer) {
            case (.onionRequest, .onionRequest):
                let color = (!OnionRequestAPI.paths.isEmpty ? Colors.accent : Colors.pathsBuilding)
                setColor(to: color, isAnimated: false)
                
            case (.lokinet, .lokinet):
                let color = (LokinetWrapper.isReady ? Colors.accent : Colors.pathsBuilding)
                setColor(to: color, isAnimated: false)
                
            case (.nativeLokinet, .nativeLokinet): fallthrough
            case (.direct, .direct):
                setColor(to: Colors.accent, isAnimated: false)
                
            default:
                setColor(to: .lightGray, isAnimated: true)
        }
    }

    @objc private func handleBuildingPathsNotification() {
        switch networkLayer {
            case .onionRequest:
                setColor(to: Colors.pathsBuilding, isAnimated: true)
                
            case .lokinet: fallthrough
            case .nativeLokinet: fallthrough
            case .direct:
                setColor(to: .lightGray, isAnimated: true)
        }
    }

    @objc private func handlePathsBuiltNotification() {
        switch networkLayer {
            case .onionRequest:
                setColor(to: Colors.accent, isAnimated: true)
                
            case .lokinet: fallthrough
            case .nativeLokinet: fallthrough
            case .direct:
                setColor(to: .lightGray, isAnimated: true)
        }
    }
    
    @objc private func handleBuildingPathsLokiNotification() {
        switch networkLayer {
            case .lokinet:
                setColor(to: Colors.pathsBuilding, isAnimated: true)
                
            case .onionRequest: fallthrough
            case .nativeLokinet: fallthrough
            case .direct:
                setColor(to: .lightGray, isAnimated: true)
        }
    }

    @objc private func handlePathsBuiltLokiNotification() {
        switch networkLayer {
            case .lokinet:
                setColor(to: Colors.accent, isAnimated: true)
                
            case .onionRequest: fallthrough
            case .nativeLokinet: fallthrough
            case .direct:
                setColor(to: .lightGray, isAnimated: true)
        }
    }
    
    @objc private func handleDirectNetworkReadyNotification() {
        setColor(to: Colors.accent, isAnimated: true)
        
        switch networkLayer {
            case .nativeLokinet: fallthrough
            case .direct:
                setColor(to: Colors.accent, isAnimated: true)
                
            case .onionRequest:  fallthrough
            case .lokinet:
                setColor(to: .lightGray, isAnimated: true)
        }
    }
}
