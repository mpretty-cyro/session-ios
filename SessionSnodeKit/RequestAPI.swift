// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import PromiseKit
import SessionUtilitiesKit

public enum RequestAPI {
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
    
    public static func sendRequest(to snode: Snode, invoking method: Snode.Method, with parameters: JSON, associatedWith publicKey: String? = nil) -> Promise<JSON> {
        let payload: JSON = [
            "method": method.rawValue,
            "params": parameters
        ]
        
        return sendRequest(
            with: payload,
            to: OnionRequestAPI.Destination.snode(snode)
        )
        .recover2 { error -> Promise<JSON> in
            let layer: NetworkLayer = (NetworkLayer(rawValue: UserDefaults.standard[.networkLayer] ?? "") ?? .onionRequest)
            
            guard
                layer == .onionRequest,
                case OnionRequestAPI.Error.httpRequestFailedAtDestination(let statusCode, let json, _) = error
            else { throw error }
            
            throw SnodeAPI.handleError(withStatusCode: statusCode, json: json, forSnode: snode, associatedWith: publicKey) ?? error
        }
    }
    
    /// Sends an onion request to `server`. Builds new paths as needed.
    public static func sendRequest(_ request: NSURLRequest, to server: String, target: String = "/loki/v3/lsrpc", using x25519PublicKey: String) -> Promise<JSON> {
        var rawHeaders = request.allHTTPHeaderFields ?? [:]
        rawHeaders.removeValue(forKey: "User-Agent")
        var headers: JSON = rawHeaders.mapValues { value in
            switch value.lowercased() {
                case "true": return true
                case "false": return false
                default: return value
            }
        }
        guard let url = request.url, let host = request.url?.host else {
            return Promise(error: OnionRequestAPI.Error.invalidURL)
        }
        
        var endpoint = url.path.removingPrefix("/")
        if let query = url.query { endpoint += "?\(query)" }
        let scheme = url.scheme
        let port = given(url.port) { UInt16($0) }
        let parametersAsString: String
        
        if let tsRequest = request as? TSRequest {
            headers["Content-Type"] = "application/json"
            let tsRequestParameters = tsRequest.parameters
            if !tsRequestParameters.isEmpty {
                guard let parameters = try? JSONSerialization.data(withJSONObject: tsRequestParameters, options: [ .fragmentsAllowed ]) else {
                    return Promise(error: HTTP.Error.invalidJSON)
                }
                parametersAsString = String(bytes: parameters, encoding: .utf8) ?? "null"
            }
            else {
                parametersAsString = "null"
            }
        }
        else {
            headers["Content-Type"] = request.allHTTPHeaderFields!["Content-Type"]
            if let parametersAsInputStream = request.httpBodyStream, let parameters = try? Data(from: parametersAsInputStream) {
                parametersAsString = "{ \"fileUpload\" : \"\(String(data: parameters.base64EncodedData(), encoding: .utf8) ?? "null")\" }"
            } else {
                parametersAsString = "null"
            }
        }
        let payload: JSON = [
            "body" : parametersAsString,
            "endpoint" : endpoint,
            "method" : request.httpMethod!,
            "headers" : headers
        ]
        let destination = OnionRequestAPI.Destination.server(host: host, target: target, x25519PublicKey: x25519PublicKey, scheme: scheme, port: port)
        let promise = sendRequest(with: payload, to: destination)
        promise.catch2 { error in
            SNLog("Couldn't reach server: \(url) due to error: \(error).")
        }
        return promise
    }
    
    public static func sendRequest(with payload: JSON, to destination: OnionRequestAPI.Destination) -> Promise<JSON> {
        let layer: NetworkLayer = (NetworkLayer(rawValue: UserDefaults.standard[.networkLayer] ?? "") ?? .onionRequest)
        
        switch layer {
            case .onionRequest: return OnionRequestAPI.sendOnionRequest(with: payload, to: destination)
            case .lokinet: return LokinetRequestAPI.sendLokinetRequest(with: payload, to: destination)
            case .nativeLokinet: return NativeLokinetRequestAPI.sendNativeLokinetRequest(with: payload, to: destination)
            case .direct: return DirectRequestAPI.sendDirectRequest(with: payload, to: destination)
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
    }
}
