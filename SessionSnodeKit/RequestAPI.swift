// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import PromiseKit
import SessionUtilitiesKit

public protocol RequestAPIType {
    static func sendRequest(_ db: Database, to snode: Snode, invoking method: SnodeAPIEndpoint, with parameters: JSON, associatedWith publicKey: String?) -> Promise<Data>
    static func sendRequest(_ db: Database, request: URLRequest, to server: String, using version: OnionRequestAPIVersion, with x25519PublicKey: String, timeout: TimeInterval) -> Promise<(OnionRequestResponseInfoType, Data?)>
}

public extension RequestAPIType {
    static func sendRequest(_ db: Database, request: URLRequest, to server: String, with x25519PublicKey: String, timeout: TimeInterval = HTTP.timeout) -> Promise<(OnionRequestResponseInfoType, Data?)> {
        sendRequest(db, request: request, to: server, using: .v4, with: x25519PublicKey, timeout: timeout)
    }
}

public enum RequestAPI: RequestAPIType {
    public enum NetworkLayer: String, Codable, CaseIterable, Equatable, Hashable, EnumStringSetting, Differentiable {
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
        
        public static func didChangeNetworkLayer() {
            NotificationCenter.default.post(name: .networkLayerChanged, object: nil, userInfo: nil)
            
            LokinetWrapper.stop()
            GetSnodePoolJob.run()
            
            // Cancel and remove all current requests
            RequestAPI.currentRequests.mutate { requests in
                requests.forEach { $0.task?.cancel() }
                requests = []
            }
        }
    }
    
    fileprivate static let currentRequests: Atomic<[RequestContainer<(OnionRequestResponseInfoType, Data?)>]> = Atomic([])
    
    public static func sendRequest(_ db: Database, to snode: Snode, invoking method: SnodeAPIEndpoint, with parameters: JSON, associatedWith publicKey: String? = nil) -> Promise<Data> {
        let payloadJson: JSON = [ "method" : method.rawValue, "params" : parameters ]
        
        guard let payload: Data = try? JSONSerialization.data(withJSONObject: payloadJson, options: []) else {
            return Promise(error: HTTP.Error.invalidJSON)
        }
        
        /// **Note:** Currently the service nodes only support V3 Onion Requests
        return sendRequest(
            db,
            method: .post,
            headers: [:],
            endpoint: "storage_rpc/v1",
            body: payload,
            to: OnionRequestAPIDestination.snode(snode),
            version: .v3
        )
        .map { _, maybeData in
            guard let data: Data = maybeData else { throw HTTP.Error.invalidResponse }

            return data
        }
        .recover2 { error -> Promise<Data> in
            let layer: NetworkLayer = Storage.shared[.debugNetworkLayer].defaulting(to: .onionRequest)
            
            guard
                layer == .onionRequest,
                case OnionRequestAPIError.httpRequestFailedAtDestination(let statusCode, let data, _) = error
            else { throw error }
            
            throw SnodeAPI.handleError(withStatusCode: statusCode, data: data, forSnode: snode, associatedWith: publicKey) ?? error
        }
    }
    
    /// Sends an onion request to `server`. Builds new paths as needed.
    public static func sendRequest(
        _ db: Database,
        request: URLRequest,
        to server: String,
        using version: OnionRequestAPIVersion = .v4,
        with x25519PublicKey: String,
        timeout: TimeInterval = HTTP.timeout
    ) -> Promise<(OnionRequestResponseInfoType, Data?)> {
        guard let url = request.url, let host = request.url?.host else {
            return Promise(error: OnionRequestAPIError.invalidURL)
        }
        
        var endpoint = url.path.removingPrefix("/")
        if let query = url.query { endpoint += "?\(query)" }
        let scheme = url.scheme
        let port = given(url.port) { UInt16($0) }
        let headers: [String: String] = (request.allHTTPHeaderFields ?? [:])
            .setting(
                "Content-Type",
                (request.httpBody == nil ? nil :
                    // Default to JSON if not defined
                    ((request.allHTTPHeaderFields ?? [:])["Content-Type"] ?? "application/json")
                )
            )
            .removingValue(forKey: "User-Agent")
        
        let layer: NetworkLayer = db[.debugNetworkLayer].defaulting(to: .onionRequest)
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
            db,
            method: (HTTP.Verb.from(request.httpMethod) ?? .get),   // The default (if nil) is 'GET'
            headers: headers,
            endpoint: endpoint,
            body: body,
            to: destination,
            version: version
        )
    }
    
    private static func sendRequest(
        _ db: Database,
        method: HTTP.Verb,
        headers: [String: String],
        endpoint: String,
        body: Data?,
        to destination: OnionRequestAPIDestination,
        version: OnionRequestAPIVersion = .v4,
        timeout: TimeInterval = HTTP.timeout
    ) -> Promise<(OnionRequestResponseInfoType, Data?)> {
        let container: RequestContainer<(OnionRequestResponseInfoType, Data?)> = {
            let layer: NetworkLayer = db[.debugNetworkLayer].defaulting(to: .onionRequest)

            switch layer {
                case .onionRequest:
                    guard let payload: Data = body else {
                        return RequestContainer(promise: Promise(error: OnionRequestAPIError.invalidRequestInfo))
                    }
                    
                    return OnionRequestAPI
                        .sendOnionRequest(
                            with: payload,
                            to: destination,
                            version: version,
                            timeout: timeout
                        )
                    
                case .lokinet:
                    return LokinetRequestAPI
                        .sendLokinetRequest(
                            method,
                            endpoint: endpoint,
                            headers: headers,
                            body: body,
                            destination: destination,
                            timeout: timeout
                        )
                    
                case .nativeLokinet:
                    return NativeLokinetRequestAPI
                        .sendNativeLokinetRequest(
                            method,
                            endpoint: endpoint,
                            headers: headers,
                            body: body,
                            destination: destination,
                            timeout: timeout
                        )
                    
                case .direct:
                    return DirectRequestAPI
                        .sendDirectRequest(
                            method,
                            endpoint: endpoint,
                            headers: headers,
                            body: body,
                            destination: destination,
                            timeout: timeout
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
                SnodeAPI.clockOffsetMs.mutate { $0 = offset }
                
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
