// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import PromiseKit
import SessionUtilitiesKit

public enum NativeLokinetRequestAPI {
    internal static func sendNativeLokinetRequest(
        _ method: HTTP.Verb,
        endpoint: String,
        headers: [String: String] = [:],
        body: Data?,
        destination: OnionRequestAPIDestination,
        timeout: TimeInterval = HTTP.timeout
    ) -> RequestContainer<(OnionRequestResponseInfoType, Data?)> {
        let (promise, seal) = Promise<(OnionRequestResponseInfoType, Data?)>.pending()
        let container = RequestContainer(promise: promise)
        
        Threading.workQueue.async { // Avoid race conditions on `guardSnodes` and `paths`
            let maybeFinalUrlString: String? = {
                switch destination {
                    case .server(let host, _, _, let scheme, _):
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
                        
                        return "\(scheme ?? "https")://\(addressInfo.address):\(addressInfo.port)/\(endpoint)"
                        
                    case .snode(let snode):
                        guard
                            let targetLokiAddress = LokinetWrapper.base32SnodePublicKey(
                                publicKey: snode.ed25519PublicKey
                            )
                        else { return nil }
                        
                        return "https://\(targetLokiAddress).snode:\(snode.port)/\(endpoint)"
                }
            }()
            
            // Ensure we have the final URL
            guard let finalUrlString: String = maybeFinalUrlString else {
                seal.reject(OnionRequestAPIError.invalidURL)
                return
            }
            
            /// Note: `Host` is a protected header so we can't custom set it
//                        customHeaders["Host"] = "chat.kcpyawm9se7trdbzncimdi5t7st4p5mh9i1mg7gkpuubi4k4ku1y.loki"//host
            
            let (promise, task) = HTTP
                .execute2(
                    method,
                    finalUrlString,
                    headers: headers,
                    body: body,
                    timeout: timeout
                )
            
            container.task = task
            promise
                .done2 { data in seal.fulfill((OnionRequestAPI.ResponseInfo(code: 0, headers: [:]), data)) }
                .catch2 { error in seal.reject(error) }
        }
        
        return container
    }
}
