// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import PromiseKit
import SessionUtilitiesKit

public enum LokinetRequestAPI {
    internal static let sogsLiveLoki: String = "http://xp5ph6qkse3dr3yecjkgstxekrhc8jbprr88frrfcxeaw1kiao8y.loki"
    internal static let sogsDevLoki: String = "http://kcpyawm9se7trdbzncimdi5t7st4p5mh9i1mg7gkpuubi4k4ku1y.loki"
    internal static let sogsLivePort: UInt16 = 80
    internal static let sogsDevPort: UInt16 = 88
    
    internal static func sendLokinetRequest(with payload: JSON, to destination: OnionRequestAPI.Destination) -> Promise<JSON> {
        guard LokinetWrapper.isReady else {
            // Use this error to indicate not setup for now
            return Promise(error: OnionRequestAPI.Error.insufficientSnodes)
        }
        
        let (promise, seal) = Promise<JSON>.pending()
        
        Threading.workQueue.async { // Avoid race conditions on `guardSnodes` and `paths`
            let maybeRequestInfo: (method: HTTP.Verb, address: String, body: Data?)? = {
                switch destination {
                    case .server(let host, _, _, _, _):
                        let maybeAddressInfo: (address: String, port: UInt16)? = {
                            if host.contains("chat.lokinet.dev") {
                                return (LokinetRequestAPI.sogsDevLoki, LokinetRequestAPI.sogsDevPort)
                            }
                            
                            if host.contains("open.getsession.org") || host.contains("116.203.70.33") {
                                return (LokinetRequestAPI.sogsLiveLoki, LokinetRequestAPI.sogsLivePort)
                            }
                            
                            return nil
                        }()
                        
                        guard let addressInfo: (address: String, port: UInt16) = maybeAddressInfo else {
                            return nil
                        }
                        
                        guard
                            let endpoint: String = payload["endpoint"] as? String,
                            let body: String = payload["body"] as? String,
                            let payloadData: Data = body.data(using: .utf8),
                            let targetAddress: String = try? LokinetWrapper.getDestinationFor(
                                host: addressInfo.address,
                                port: addressInfo.port
                            )
                        else { return nil }
                        
                        /// Note: Lokinet encrypts the packets sent over it so no need to send requests over HTTPS (which would end
                        /// up being slower with no real benefit)
                        return (
                            (HTTP.Verb.from(payload["method"] as? String) ?? .get),
                            "http://\(targetAddress)/legacy/\(endpoint)",
                            (body == "null" ? nil : payloadData)
                        )
                        
                    case .snode(let snode):
                        guard let targetLokiAddress = LokinetWrapper.base32SnodePublicKey(publicKey: snode.publicKeySet.ed25519Key) else {
                            return nil
                        }
                        
                        guard
                            let payloadData: Data = try? JSONSerialization.data(
                                withJSONObject: payload,
                                options: [ .fragmentsAllowed ]
                            ),
                            let targetAddress: String = try? LokinetWrapper.getDestinationFor(
                                host: "https://\(targetLokiAddress).snode",
                                port: snode.port
                            )
                        else { return nil }
                        
                        /// Note: The service nodes require requests to run over HTTPS
                        return (
                            .post,
                            "https://\(targetAddress)/storage_rpc/v1",
                            payloadData
                        )
                }
            }()
            
            // Ensure we have the address info
            guard let requestInfo: (method: HTTP.Verb, address: String, body: Data?) = maybeRequestInfo else {
                seal.reject(OnionRequestAPI.Error.invalidURL)
                return
            }
            
            let customHeaders: [String: String] = ((payload["headers"] as? [String: String]) ?? [:])
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
            
            HTTP
                .execute(
                    requestInfo.method,
                    requestInfo.address,
                    headers: customHeaders,
                    body: requestInfo.body,
                    // FIXME: Why do we need an increased timeout for Lokinet? (smaller values seem to result in timeouts even though we get responses much quicker...)
                    timeout: 60
                )
                .done2 { json in
                    let end = CACurrentMediaTime()
                    SNLog("[Lokinet] \(isSnode ? "Snode" : "Server") request completed \(end - start)s")
                    if let statusCode = json["status_code"] as? Int {
                        if statusCode == 406 { // Clock out of sync
                            SNLog("The user's clock is out of sync with the service node network.")
                            return seal.reject(SnodeAPI.Error.clockOutOfSync)
                        }
                        
                        if statusCode == 401 { // Signature verification failed
                            SNLog("Failed to verify the signature.")
                            return seal.reject(SnodeAPI.Error.signatureVerificationFailed)
                        }
                        
                        guard 200...299 ~= statusCode else {
                            return seal.reject(OnionRequestAPI.Error.httpRequestFailedAtDestination(statusCode: UInt(statusCode), json: json, destination: destination))
                        }
                    }
                    
                    if let timestamp = json["t"] as? Int64 {
                        let offset = timestamp - Int64(NSDate.millisecondTimestamp())
                        SnodeAPI.clockOffset = offset
                    }
                    
                    seal.fulfill(json)
                }
                .catch2 { error in
                    let end = CACurrentMediaTime()
                    SNLog("[Lokinet] \(isSnode ? "Snode" : "Server") request failed \(end - start)s")
                    seal.reject(error)
                }
        }
        
        return promise
    }
}
