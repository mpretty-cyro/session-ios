// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import PromiseKit
import SessionUtilitiesKit

public enum LokinetRequestAPI {
    internal static let sogsLiveLoki: String = "http://xp5ph6qkse3dr3yecjkgstxekrhc8jbprr88frrfcxeaw1kiao8y.loki"
    internal static let sogsDevLoki: String = "http://kcpyawm9se7trdbzncimdi5t7st4p5mh9i1mg7gkpuubi4k4ku1y.loki"
    internal static let sogsLivePort: UInt16 = 80
    internal static let sogsDevPort: UInt16 = 88
    
    internal static func sendLokinetRequest(
        _ method: HTTP.Verb,
        endpoint: String,
        headers: [String: String] = [:],
        body: Data?,
        destination: OnionRequestAPIDestination
    ) -> Promise<(OnionRequestResponseInfoType, Data?)> {
        guard LokinetWrapper.isReady else {
            // Use this error to indicate not setup for now
            return Promise(error: OnionRequestAPIError.insufficientSnodes)
        }
        
        let (promise, seal) = Promise<(OnionRequestResponseInfoType, Data?)>.pending()
        
        Threading.workQueue.async { // Avoid race conditions on `guardSnodes` and `paths`
            let maybeFinalUrlString: String? = {
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
                            let targetAddress: String = try? LokinetWrapper.getDestinationFor(
                                host: addressInfo.address,
                                port: addressInfo.port
                            )
                        else { return nil }
                        
                        /// Note: Lokinet encrypts the packets sent over it so no need to send requests over HTTPS (which would end
                        /// up being slower with no real benefit)
                        return "http://\(targetAddress)/legacy/\(endpoint)"
                        
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
            
            HTTP
                .execute(
                    method,
                    finalUrlString,
                    headers: headers,
                    body: body,
                    // FIXME: Why do we need an increased timeout for Lokinet? (smaller values seem to result in timeouts even though we get responses much quicker...)
                    timeout: 60
                )
                .done2 { data in
                    let end = CACurrentMediaTime()
                    SNLog("[Lokinet] \(isSnode ? "Snode" : "Server") request completed \(end - start)s")
                    seal.fulfill((OnionRequestAPI.ResponseInfo(code: 0, headers: [:]), data))
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
