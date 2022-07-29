import Foundation

public extension Notification.Name {

    static let buildingPaths = Notification.Name("buildingPaths")
    static let pathsBuilt = Notification.Name("pathsBuilt")
    static let buildingPathsLoki = Notification.Name("buildingPathsLoki")
    static let pathsBuiltLoki = Notification.Name("pathsBuiltLoki")
    static let directNetworkReady = Notification.Name("directNetworkReady")
    static let onionRequestPathCountriesLoaded = Notification.Name("onionRequestPathCountriesLoaded")
    static let networkLayerChanged = Notification.Name("networkLayerChanged")
}
