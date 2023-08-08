// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

public extension Network.RequestType {
    static func lokinetRequest(
        _ payload: Data,
        to snode: Snode,
        timeout: TimeInterval = HTTP.defaultTimeout
    ) -> Network.RequestType<Data?> {
        return Network.RequestType(
            id: "lokinetRequest",
            url: snode.address,
            method: "POST",
            body: payload,
            args: [payload, snode, timeout]
        ) {
            LokinetRequestAPI.sendRequest(
                method: .post,
                headers: [:],
                endpoint: "storage_rpc/v1",
                body: payload,
                destination: OnionRequestAPIDestination.snode(snode),
                timeout: timeout
            )
        }
    }
    
    static func lokinetRequest(
        _ request: URLRequest,
        to server: String,
        with x25519PublicKey: String,
        timeout: TimeInterval = HTTP.defaultTimeout
    ) -> Network.RequestType<Data?> {
        return Network.RequestType(
            id: "lokinetRequest",
            args: [request, server, x25519PublicKey, timeout]
        ) {
            guard let url = request.url, let host = request.url?.host else {
                return Fail(error: HTTPError.invalidURL).eraseToAnyPublisher()
            }
            
            var endpoint = url.path.removingPrefix("/")
            if let query = url.query { endpoint += "?\(query)" }
            let scheme = url.scheme
            let port = url.port.map { UInt16($0) }
            let headers: [String: String] = (request.allHTTPHeaderFields ?? [:])
                .setting(
                    "Content-Type",
                    (request.httpBody == nil ? nil :
                        // Default to JSON if not defined
                        ((request.allHTTPHeaderFields ?? [:])["Content-Type"] ?? "application/json")
                    )
                )
                .removingValue(forKey: "User-Agent")
            
            return LokinetRequestAPI.sendRequest(
                method: (request.httpMethod.map { HTTPMethod(rawValue: $0) } ?? .get),   // The default (if nil) is 'GET'
                headers: headers,
                endpoint: endpoint,
                body: request.httpBody,
                destination: OnionRequestAPIDestination.server(
                    host: host,
                    target: OnionRequestAPIVersion.v4.rawValue,
                    x25519PublicKey: x25519PublicKey,
                    scheme: scheme,
                    port: port
                ),
                timeout: timeout
            )
        }
    }
}

public enum LokinetRequestAPI {
    /// **Note:** If testing against Testnet use `dan.lokinet.dev` as the others are all on Mainnet
    internal static let lokiAddressLookup: [String: (address: String, port: UInt16)] = [
        "open.getsession.org": ("http://xp5ph6qkse3dr3yecjkgstxekrhc8jbprr88frrfcxeaw1kiao8y.loki", 88),
        "116.203.70.33": ("http://xp5ph6qkse3dr3yecjkgstxekrhc8jbprr88frrfcxeaw1kiao8y.loki", 88),
        "chat.lokinet.dev": ("http://kcpyawm9se7trdbzncimdi5t7st4p5mh9i1mg7gkpuubi4k4ku1y.loki", 88),
        "dan.lokinet.dev": ("http://dan.kcpyawm9se7trdbzncimdi5t7st4p5mh9i1mg7gkpuubi4k4ku1y.loki", 85)
    ]
    
    fileprivate static func sendRequest(
        method: HTTPMethod,
        headers: [String: String] = [:],
        endpoint: String,
        body: Data?,
        destination: OnionRequestAPIDestination,
        timeout: TimeInterval = HTTP.defaultTimeout
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        guard LokinetWrapper.isReady else {
            return Fail(error: HTTPError.networkWrappersNotReady).eraseToAnyPublisher()
        }
        
        let maybeFinalUrlString: String? = {
            switch destination {
                case .server(let host, _, _, _, _):
                    guard let addressInfo: (address: String, port: UInt16) = lokiAddressLookup[host] else {
                        return nil
                    }
                    
                    guard
                        let targetAddress: String = try? LokinetWrapper.getDestinationFor(
                            host: addressInfo.address,
                            port: addressInfo.port
                        )
                    else { return nil }
                    
                    /// Note: Lokinet encrypts the packets sent over it so no need to send requests over HTTPS (which would end
                    /// up being slower with no real benefit)
                    return "http://\(targetAddress)/\(endpoint)"
                    
                case .snode(let snode):
                    guard let targetLokiAddress = LokinetWrapper.base32SnodePublicKey(publicKey: snode.ed25519PublicKey) else {
                        return nil
                    }
                    
                    guard
                        let targetAddress: String = try? LokinetWrapper.getDestinationFor(
                            host: "https://\(targetLokiAddress).snode",
                            port: snode.port
                        )
                    else { return nil }
                    
                    /// Note: The service nodes require requests to run over HTTPS
                    return "https://\(targetAddress)/\(endpoint)"
            }
        }()
        
        // Ensure we have the final URL
        guard let finalUrlString: String = maybeFinalUrlString else {
            return Fail(error: OnionRequestAPIError.invalidURL).eraseToAnyPublisher()
        }
        
        /// Note: `Host` is a protected header so we can't custom set it
//                        customHeaders["Host"] = "chat.kcpyawm9se7trdbzncimdi5t7st4p5mh9i1mg7gkpuubi4k4ku1y.loki"//host
                
            // FIXME: No support for websockets yet so still need to do HTTP requests
//                if #available(iOS 13.0, *) {
//                // Web socket usage info: https://appspector.com/blog/websockets-in-ios-using-urlsessionwebsockettask
//                let (promise, seal) = Promise<OnionBuildingResult>.pending()
//                let task = HTTP.openSocket(.post, targetAddress, body: nil)
//
//                // Need to start the socket connection
//                task?.resume()
////                    URLSessionWebSocketTask.Message.
//
//
//                task?.send(.data(payloadData), completionHandler: { error in
//                    print("RAWR")
//                })
//                // Note: This 'receive' method will only be called once, so if we want to receive
//                // again (eg. maintain an open connection) we need to call it again
//                task?.receive(completionHandler: { result in
//                    print("ASD")
//                    switch result {
//                        case .failure(let error): seal.reject(error)
//                        default: break
//                    }
//                })
//
//                // task?.cancel(with: .goingAway, reason: nil)
//
//                return promise

        let start = CACurrentMediaTime()
        let isSnode: Bool = {
            switch destination {
                case .snode: return true
                case .server: return false
            }
        }()
        
        return HTTP
            .execute(
                method,
                finalUrlString,
                headers: headers,
                body: body,
                // FIXME: Why do we need an increased timeout for Lokinet? (smaller values seem to result in timeouts even though we get responses much quicker...)
                timeout: 60// timeout
            )
            .handleEvents(
                receiveCompletion: { result in
                    let end = CACurrentMediaTime()
                    let result: String = {
                        switch result {
                            case .finished: return "completed"
                            case .failure(let error):
                                switch error as? HTTPError {
                                    case .timeout: return "timed out"
                                    case .cancelled: return "was cancelled"
                                    case .httpRequestFailed(let status, let data):
                                        switch status {
                                            case 400: return "failed: Bad request"
                                            default: return "failed \(data.map { String(data: $0, encoding: .utf8) } ?? "unknown")"
                                        }
                                        
                                    default: return "failed: unknown"
                                }
                        }
                    }()
                    SNLog("[Lokinet] \(isSnode ? "Snode" : "Server") request \(result) \(end - start)s")
                }
            )
            .map { data in (HTTP.ResponseInfo(code: 0, headers: [:]), data) }
            .eraseToAnyPublisher()
    }
}
