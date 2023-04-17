// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import PromiseKit
import SessionUtilitiesKit

public enum LokinetRequestAPI {
    /// **Note:** If testing against Testnet use `dan.lokinet.dev` as the others are all on Mainnet
    internal static let lokiAddressLookup: [String: (address: String, port: UInt16)] = [
        "open.getsession.org": ("http://xp5ph6qkse3dr3yecjkgstxekrhc8jbprr88frrfcxeaw1kiao8y.loki", 88),
        "116.203.70.33": ("http://xp5ph6qkse3dr3yecjkgstxekrhc8jbprr88frrfcxeaw1kiao8y.loki", 88),
        "chat.lokinet.dev": ("http://kcpyawm9se7trdbzncimdi5t7st4p5mh9i1mg7gkpuubi4k4ku1y.loki", 88),
        "dan.lokinet.dev": ("http://dan.kcpyawm9se7trdbzncimdi5t7st4p5mh9i1mg7gkpuubi4k4ku1y.loki", 85)
    ]
    
    internal static func sendLokinetRequest(
        _ method: HTTP.Verb,
        endpoint: String,
        headers: [String: String] = [:],
        body: Data?,
        destination: OnionRequestAPIDestination,
        timeout: TimeInterval = HTTP.timeout
    ) -> RequestContainer<(OnionRequestResponseInfoType, Data?)> {
        guard LokinetWrapper.isReady else {
            return RequestContainer(promise: Promise(error: RequestAPI.RequestAPIError.networkWrappersNotReady))
        }
        
        let (promise, seal) = Promise<(OnionRequestResponseInfoType, Data?)>.pending()
        let container = RequestContainer(promise: promise)
        
        Threading.workQueue.async { // Avoid race conditions on `guardSnodes` and `paths`
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
                seal.reject(OnionRequestAPIError.invalidURL)
                return
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
            
            let (promise, task) = HTTP
                .execute2(
                    method,
                    finalUrlString,
                    headers: headers,
                    body: body,
                    // FIXME: Why do we need an increased timeout for Lokinet? (smaller values seem to result in timeouts even though we get responses much quicker...)
                    timeout: 60// timeout
                )
            
            container.task = task
            promise
                .done2 { data in
                    let end = CACurrentMediaTime()
                    SNLog("[Lokinet] \(isSnode ? "Snode" : "Server") request completed \(end - start)s")
                    seal.fulfill((OnionRequestAPI.ResponseInfo(code: 0, headers: [:]), data))
                }
                .catch2 { error in
                    let end = CACurrentMediaTime()
                    let errorType: String = {
                        switch error as? HTTP.Error {
                            case .timeout: return "timed out"
                            case .cancelled: return "was cancelled"
                            case .httpRequestFailed(let status, let data):
                                switch status {
                                    case 400: return "failed: Bad request"
                                    default: return "failed \(data.map { String(data: $0, encoding: .utf8) } ?? "unknown")"
                                }
                                
                            default: return "failed: unknown"
                        }
                    }()
                    SNLog("[Lokinet] \(isSnode ? "Snode" : "Server") request \(errorType) \(end - start)s")
                    seal.reject(error)
                }
        }
        
        return container
    }
}
