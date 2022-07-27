import UIKit
import SessionUIKit
import SessionSnodeKit

final class PathStatusView: UIView {
    
    static let size = CGFloat(10)
    
    private lazy var layerLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: 6)
        result.textAlignment = .center
        
        return result
    }()
    
    init(networkLayer: RequestAPI.NetworkLayer) {
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
    }

    private func registerObservers(networkLayer: RequestAPI.NetworkLayer) {
        switch networkLayer {
            case .onionRequest:
                NotificationCenter.default.addObserver(self, selector: #selector(handleBuildingPathsNotification), name: .buildingPaths, object: nil)
                NotificationCenter.default.addObserver(self, selector: #selector(handlePathsBuiltNotification), name: .pathsBuilt, object: nil)
                
            case .lokinet:
                NotificationCenter.default.addObserver(self, selector: #selector(handleBuildingPathsNotification), name: .buildingPathsLoki, object: nil)
                NotificationCenter.default.addObserver(self, selector: #selector(handlePathsBuiltNotification), name: .pathsBuiltLoki, object: nil)
                
            case .nativeLokinet: break
            case .direct: break
        }
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

    @objc private func handleBuildingPathsNotification() {
        setColor(to: Colors.pathsBuilding, isAnimated: true)
    }

    @objc private func handlePathsBuiltNotification() {
        setColor(to: Colors.accent, isAnimated: true)
    }
}
