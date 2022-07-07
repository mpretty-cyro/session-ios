// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import PromiseKit
import SessionUtilitiesKit

public enum NativeLokinetRequestAPI {
    internal static func sendNativeLokinetRequest(with payload: JSON, to destination: OnionRequestAPI.Destination) -> Promise<JSON> {
        let (promise, seal) = Promise<JSON>.pending()
        
        Threading.workQueue.async { // Avoid race conditions on `guardSnodes` and `paths`
            let maybeRequestInfo: (method: HTTP.Verb, address: String, body: Data?)? = {
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
                        
                        guard
                            let endpoint: String = payload["endpoint"] as? String,
                            let body: String = payload["body"] as? String,
                            let payloadData: Data = body.data(using: .utf8)
                        else { return nil }
                        
                        return (
                            (HTTP.Verb.from(payload["method"] as? String) ?? .get),
                            "\(scheme ?? "https")://\(addressInfo.address):\(addressInfo.port)/legacy/\(endpoint)",
                            (body == "null" ? nil : payloadData)
                        )
                        
                    case .snode(let snode):
                        guard
                            let targetLokiAddress = LokinetWrapper.base32SnodePublicKey(
                                publicKey: snode.publicKeySet.ed25519Key
                            ),
                            let payloadData: Data = try? JSONSerialization.data(
                                withJSONObject: payload,
                                options: [ .fragmentsAllowed ]
                            )
                        else { return nil }
                        
                        return (
                            .post,
                            "https://\(targetLokiAddress).snode:\(snode.port)/storage_rpc/v1",
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
            
            HTTP
                .execute(
                    requestInfo.method,
                    requestInfo.address,
                    headers: customHeaders,
                    body: requestInfo.body
                )
                .done2 { json in
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
                .catch2 { error in seal.reject(error) }
        }
        
        return promise
    }
}
