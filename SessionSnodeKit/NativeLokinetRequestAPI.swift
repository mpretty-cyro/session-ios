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
                        guard let addressInfo: (address: String, port: UInt16) = LokinetRequestAPI.lokiAddressLookup[host] else {
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
