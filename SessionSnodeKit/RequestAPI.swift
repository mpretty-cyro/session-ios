// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import PromiseKit
import SessionUtilitiesKit

public protocol RequestAPIType {
    static func sendRequest(to snode: Snode, invoking method: SnodeAPIEndpoint, with parameters: JSON, associatedWith publicKey: String?) -> Promise<Data>
    static func sendRequest(_ request: URLRequest, to server: String, using version: OnionRequestAPIVersion, with x25519PublicKey: String) -> Promise<(OnionRequestResponseInfoType, Data?)>
}

public extension RequestAPIType {
    static func sendRequest(_ request: URLRequest, to server: String, with x25519PublicKey: String) -> Promise<(OnionRequestResponseInfoType, Data?)> {
        sendRequest(request, to: server, using: .v4, with: x25519PublicKey)
    }
}

public enum RequestAPI: RequestAPIType {
    public enum NetworkLayer: String, Codable, CaseIterable {
        case onionRequest
        case lokinet
        case nativeLokinet
        case direct
        
        public var name: String {
            switch self {
                case .onionRequest: return "Onion Requests"
                case .lokinet: return "Lokinet"
                case .nativeLokinet: return "Native Lokinet"
                case .direct: return "Direct"
            }
        }
    }
    
    fileprivate static let currentRequests: Atomic<[RequestContainer<(OnionRequestResponseInfoType, Data?)>]> = Atomic([])
    
    public static func sendRequest(to snode: Snode, invoking method: SnodeAPIEndpoint, with parameters: JSON, associatedWith publicKey: String? = nil) -> Promise<Data> {
        let payloadJson: JSON = [ "method" : method.rawValue, "params" : parameters ]
        
        guard let payload: Data = try? JSONSerialization.data(withJSONObject: payloadJson, options: []) else {
            return Promise(error: HTTP.Error.invalidJSON)
        }
        
        return sendRequest(
            .post,
            headers: [:],
            endpoint: "storage_rpc/v1",
            body: payload,
            to: OnionRequestAPIDestination.snode(snode)
        )
        .map { _, maybeData in
            guard let data: Data = maybeData else { throw HTTP.Error.invalidResponse }

            return data
        }
        .recover2 { error -> Promise<Data> in
            let layer: NetworkLayer = (NetworkLayer(rawValue: UserDefaults.standard[.networkLayer] ?? "") ?? .onionRequest)
            
            guard
                layer == .onionRequest,
                case OnionRequestAPIError.httpRequestFailedAtDestination(let statusCode, let data, _) = error
            else { throw error }
            
            throw SnodeAPI.handleError(withStatusCode: statusCode, data: data, forSnode: snode, associatedWith: publicKey) ?? error
        }
    }
    
    /// Sends an onion request to `server`. Builds new paths as needed.
    public static func sendRequest(_ request: URLRequest, to server: String, using version: OnionRequestAPIVersion = .v4, with x25519PublicKey: String) -> Promise<(OnionRequestResponseInfoType, Data?)> {
        guard let url = request.url, let host = request.url?.host else {
            return Promise(error: OnionRequestAPIError.invalidURL)
        }
        
        var endpoint = url.path.removingPrefix("/")
        if let query = url.query { endpoint += "?\(query)" }
        let scheme = url.scheme
        let port = given(url.port) { UInt16($0) }
        let headers: [String: Any] = (request.allHTTPHeaderFields ?? [:])
            .removingValue(forKey: "User-Agent")
            .mapValues { value in
                switch value.lowercased() {
                    case "true": return true
                    case "false": return false
                    default: return value
                }
            }
        
        let layer: NetworkLayer = (NetworkLayer(rawValue: UserDefaults.standard[.networkLayer] ?? "") ?? .onionRequest)
        let destination = OnionRequestAPIDestination.server(
            host: host,
            target: version.rawValue,
            x25519PublicKey: x25519PublicKey,
            scheme: scheme,
            port: port
        )
        let body: Data?
        
        switch layer {
            case .onionRequest:
                guard let payload: Data = OnionRequestAPI.generatePayload(for: request, with: version) else {
                    return Promise(error: OnionRequestAPIError.invalidRequestInfo)
                }
                
                body = payload
                break
            
            default: body = request.httpBody
        }
        
        return sendRequest(
            (HTTP.Verb.from(request.httpMethod) ?? .get),   // The default (if nil) is 'GET'
            headers: headers,
            endpoint: endpoint,
            body: body,
            to: destination,
            version: version
        )
    }
    
    private static func sendRequest(
        _ method: HTTP.Verb,
        headers: [String: Any],
        endpoint: String,
        body: Data?,
        to destination: OnionRequestAPIDestination,
        version: OnionRequestAPIVersion = .v4
    ) -> Promise<(OnionRequestResponseInfoType, Data?)> {
        let container: RequestContainer<(OnionRequestResponseInfoType, Data?)> = {
            let layer: NetworkLayer = (NetworkLayer(rawValue: UserDefaults.standard[.networkLayer] ?? "") ?? .onionRequest)

            switch layer {
                case .onionRequest:
                    guard let payload: Data = body else {
                        return RequestContainer(promise: Promise(error: OnionRequestAPIError.invalidRequestInfo))
                    }
                    
                    return OnionRequestAPI.sendOnionRequest(with: payload, to: destination, version: version)
                    
                case .lokinet:
                    return LokinetRequestAPI
                        .sendLokinetRequest(
                            method,
                            endpoint: endpoint,
                            body: body,
                            destination: destination
                        )
                    
                case .nativeLokinet:
                    return NativeLokinetRequestAPI
                        .sendNativeLokinetRequest(
                            method,
                            endpoint: endpoint,
                            body: body,
                            destination: destination
                        )
                    
                case .direct:
                    return DirectRequestAPI
                        .sendDirectRequest(
                            method,
                            endpoint: endpoint,
                            body: body,
                            destination: destination
                        )
            }
        }()
        
        // Add the request from the cache
        RequestAPI.currentRequests.mutate { requests in
            requests = requests.appending(container)
        }
        
        // Handle `clockOffset` setting
        return container.promise
            .map2 { response in
                guard
                    let data: Data = response.1,
                    let json: JSON = try? JSONSerialization.jsonObject(with: data, options: [ .fragmentsAllowed ]) as? JSON,
                    let timestamp: Int64 = json["t"] as? Int64
                else { return response }
                    
                let offset = timestamp - Int64(floor(Date().timeIntervalSince1970 * 1000))
                SnodeAPI.clockOffset = offset
                
                return response
            }
            .ensure {
                // Remove the request from the cache
                RequestAPI.currentRequests.mutate { requests in
                    requests = requests.filter { $0.uuid != container.uuid }
                }
            }
    }
}

@objc(SSKNetworkLayer)
public class objc_NetworkLayer: NSObject {
    @objc public static func currentLayer() -> String {
        return (RequestAPI.NetworkLayer(rawValue: UserDefaults.standard[.networkLayer] ?? "") ?? .onionRequest).rawValue
    }
    
    @objc public static func allLayers() -> [String] {
        return RequestAPI.NetworkLayer.allCases.map { $0.rawValue }
    }
    
    @objc public static func allLayerNames() -> [String] {
        return RequestAPI.NetworkLayer.allCases.map { $0.name }
    }
    
    @objc public static func setLayerTo(_ value: String) {
        UserDefaults.standard[.networkLayer] = (RequestAPI.NetworkLayer(rawValue: value) ?? .onionRequest).rawValue
        NotificationCenter.default.post(name: .networkLayerChanged, object: nil, userInfo: nil)
        
        GetSnodePoolJob.run()
        
        // Cancel and remove all current requests
        RequestAPI.currentRequests.mutate { requests in
            requests.forEach { $0.task?.cancel() }
            requests = []
        }
    }
}

public class RequestContainer<T> {
    public let uuid: UUID = UUID()
    public let promise: Promise<T>
    public var task: URLSessionDataTask?
    
    init(promise: Promise<T>, task: URLSessionDataTask? = nil) {
        self.promise = promise
        self.task = task
    }
    
    public func map<U>(_ transform: @escaping(T) throws -> U) -> RequestContainer<U> {
        return RequestContainer<U>(promise: promise.map(transform), task: task)
    }
    
    public func recover2<U: Thenable>(_ body: @escaping(Error) throws -> U) -> RequestContainer<T> where U.T == T {
        return RequestContainer(promise: promise.recover2(body), task: task)
    }
}
