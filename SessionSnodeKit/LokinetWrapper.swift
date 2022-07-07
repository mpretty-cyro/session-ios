// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Lokinet
import QuartzCore
import SessionUtilitiesKit

/// This is a wrapper around the Lokinet library
///
/// **Note:** For info about how to actually link the static library refer to the following link (tip: the modulemap file
/// must be called _exactly_ `module.modulemap`)
/// https://bjhomer.com/2015/05/03/defining-modules-for-static-libraries/
public enum LokinetWrapper {
    private static let setupQueue = DispatchQueue(label: "SessionSnodeKit.lokinetQueue", qos: .userInitiated)
    public static private(set) var isReady: Bool = false
    public static private(set) var startTime: CFTimeInterval = 0
    private static var context: OpaquePointer?
    
    public static func setupIfNeeded() {
        guard !LokinetWrapper.isReady else { return }
        guard LokinetWrapper.context == nil else { return }
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .buildingPathsLoki, object: nil)
        }
        
        LokinetWrapper.setupQueue.async {
            guard !LokinetWrapper.isReady else { return }
            
            SNLog("[Lokinet] Start")
            let start = CACurrentMediaTime()
            let bundle: Bundle = Bundle(for: SnodeAPI.self)
            let context = lokinet_context_new()
            let bootstrapContent = try! Data(contentsOf: bundle.url(forResource: "mainnet", withExtension: "signed")!)
            var bootstrapBytes: [CChar] = bootstrapContent.bytes.map { CChar(bitPattern: $0) }
            LokinetWrapper.context = context
            
            guard
                lokinet_add_bootstrap_rc(&bootstrapBytes, bootstrapBytes.count, context) == 0 &&
                lokinet_context_start(context) == 0
            else {
                SNLog("[Lokinet] Startup failed")
                LokinetWrapper.context = nil
                LokinetWrapper.startTime = 0
                return
            }
            
            /// return 0 if we our endpoint has published on the network and is ready to send
            /// return -1 if we don't have enough paths ready
            /// retrun -2 if we look deadlocked
            /// retrun -3 if context was null or not started yet
            var lastStatus = lokinet_status(context)
            while lastStatus == -1 || lastStatus == -3 {
                Thread.sleep(forTimeInterval: 0.1)
                lastStatus = lokinet_status(context)
            }
            
            switch lastStatus {
                case 0:
                    let end = CACurrentMediaTime()
                    SNLog("[Lokinet] Ready: \(end - start)s")
                    LokinetWrapper.startTime = (end - start)
                    LokinetWrapper.isReady = true
                    
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .pathsBuiltLoki, object: nil)
                    }
                    
                default:
                    SNLog("[Lokinet] Failed")
                    LokinetWrapper.context = nil
                    LokinetWrapper.isReady = false
            }
        }
    }
    
    public static func getDestinationFor(host: String, port: UInt16) throws -> String {
        guard LokinetWrapper.isReady else { throw OnionRequestAPI.Error.insufficientSnodes }
        
        /// **Note:** Need to ensure we remove any leading 'http/https' and any trailing forward slash from the .loki and .snode address
        let remote: String = [
            host
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: ""),
            ":",
            "\(port)"
        ]
        .compactMap { $0 }
        .joined()
        var result: lokinet_stream_result = lokinet_stream_result()
        var remoteAddr: [CChar] = remote.bytes.map { CChar(bitPattern: $0) }
        
        lokinet_outbound_stream(
            &result,
            &remoteAddr,
            nil,
            LokinetWrapper.context
        )
        
        guard result.error == 0 else { throw OnionRequestAPI.Error.insufficientSnodes }
        
        /// **Note:** The `result.local_address` length is hard-coded to 256 but will include buffer data so we will
        /// need to remove it
        let localAddress: String = withUnsafePointer(to: result.local_address) {
            $0.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout.size(ofValue: $0)) {
                String(cString: $0)
            }
        }
        
        return "\(localAddress):\(result.local_port)"
    }
    
    public static func base32SnodePublicKey(publicKey: String) -> String? {
        var publicKeyCStr: [CChar] = publicKey.bytes.map { CChar(bitPattern: $0) }
        
        guard let base32KeyCStr: UnsafeMutablePointer<CChar> = lokinet_hex_to_base32z(&publicKeyCStr) else {
            return nil
        }
        
        let base32Key: String = base32KeyCStr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout.size(ofValue: base32KeyCStr)) {
            String(cString: $0)
        }
        
        return base32Key
    }
}

@objc(SSKLokinetWrapper)
public class objc_LokinetWrapper: NSObject {
    @objc public static func setupIfNeeded() {
        LokinetWrapper.setupIfNeeded()
    }
}
