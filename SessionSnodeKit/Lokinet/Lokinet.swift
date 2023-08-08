// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import libLokinet
import QuartzCore
import SessionUtilitiesKit

public enum Lokinet {
    private static let setupQueue = DispatchQueue(label: "SessionSnodeKit.lokinetQueue", qos: .userInitiated)
    public static private(set) var isReady: Bool = false
    public static private(set) var didError: Bool = false
    public static private(set) var startTime: CFTimeInterval = 0
    private static var context: OpaquePointer?
    private static var loggerFunc: lokinet_logger_func?
    
    public static func setupIfNeeded() {
        guard !Lokinet.isReady else { return }
        guard Lokinet.context == nil else { return }
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .buildingPathsLoki, object: nil)
        }
        
        Lokinet.setupQueue.async {
            guard !Lokinet.isReady else { return }
            
            SNLog("[Lokinet] Start")
            let start = CACurrentMediaTime()
            let bundle: Bundle = Bundle(for: SnodeAPI.self)
            var context = lokinet_context_new()
            let bootstrapContent = try! Data(
                contentsOf: bundle.url(
                    forResource: (Features.useTestnet ? "testnet" : "mainnet"),
                    withExtension: "signed"
                )!
            )
            var bootstrapBytes: [CChar] = bootstrapContent.bytes.map { CChar(bitPattern: $0) }
            Lokinet.didError = false
            Lokinet.context = context
            Network.requestTiming.mutate { timing in
                var updatedTiming: [String: Network.Timing] = (timing[.lokinet] ?? [:])
                updatedTiming["Startup"] = Network.Timing(
                    requestType: "Startup",
                    startTime: start,
                    endTime: -1,
                    didError: false,
                    didTimeout: false
                )
                timing[.lokinet] = updatedTiming
            }
            
            // Set the data directory so we can cache the nodedb
            var dataDir: [CChar] = Storage.sharedDatabaseDirectoryPath.bytes.map { CChar(bitPattern: $0) }
            lokinet_set_data_dir(&dataDir, context)
            print("[Lokinet] Database path \(Storage.sharedDatabaseDirectoryPath)")
            
            // Set the netid when on testnet
            if Features.useTestnet { lokinet_set_netid("gamma") }
            
            var logLevel: [CChar] = "trace".bytes.map { CChar(bitPattern: $0) }
            lokinet_log_level(&logLevel)
            let loggerFunc: lokinet_logger_func = { messagePtr, _ in
                guard let messagePtr = messagePtr else { return }
                
                let message: String = String(cString: messagePtr)
                print("[Lokinet Info] \(message)")
            }
            lokinet_set_logger(loggerFunc, &context)
            Lokinet.loggerFunc = loggerFunc
            
            guard
                lokinet_add_bootstrap_rc(&bootstrapBytes, bootstrapBytes.count, context) == 0 &&
                lokinet_context_start(context) == 0
            else {
                SNLog("[Lokinet] Startup failed")
                Lokinet.context = nil
                Lokinet.startTime = 0
                Lokinet.didError = true
                
                Network.requestTiming.mutate { timing in
                    let updatedTiming: Network.Timing? = (timing[.lokinet] ?? [:])?["Startup"]?.with(
                        endTime: CACurrentMediaTime(),
                        didError: true,
                        didTimeout: false
                    )
                    timing[.lokinet]?["Startup"] = updatedTiming
                }
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
                    Lokinet.startTime = (end - start)
                    Lokinet.isReady = true
                    Network.requestTiming.mutate { timing in
                        let updatedTiming: Network.Timing? = (timing[.lokinet] ?? [:])?["Startup"]?.with(endTime: end)
                        timing[.lokinet]?["Startup"] = updatedTiming
                    }
                    
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .pathsBuiltLoki, object: nil)
                    }
                    
                default:
                    SNLog("[Lokinet] Failed")
                    Lokinet.context = nil
                    Lokinet.isReady = false
                    Lokinet.didError = true
                    
                    Network.requestTiming.mutate { timing in
                        let updatedTiming: Network.Timing? = (timing[.lokinet] ?? [:])?["Startup"]?.with(
                            endTime: CACurrentMediaTime(),
                            didError: true,
                            didTimeout: false
                        )
                        timing[.lokinet]?["Startup"] = updatedTiming
                    }
            }
        }
    }
    
    public static func stop() {
        guard Lokinet.isReady else { return }
        guard Lokinet.context != nil else { return }
        
        lokinet_context_stop(Lokinet.context)
        Lokinet.context = nil
        Lokinet.isReady = false
        Lokinet.didError = true
    }
    
    public static func getDestinationFor(host: String, port: UInt16) throws -> String {
        guard Lokinet.isReady else { throw OnionRequestAPIError.insufficientSnodes }
        
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
        var result: lokinet_tcp_result = lokinet_tcp_result()
        var remoteAddr: [CChar] = remote.bytes.map { CChar(bitPattern: $0) }
        
        lokinet_outbound_tcp(
            &result,
            &remoteAddr,
            nil,
            Lokinet.context,
            nil,
            nil,
            nil
        )
        
        guard result.error == 0 else { throw OnionRequestAPIError.insufficientSnodes }
        
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
        return publicKey.withCString { cStr -> String? in
            return lokinet_hex_to_base32z(cStr).map {
                $0.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout.size(ofValue: $0)) {
                    String(cString: $0)
                }
            }
        }
    }
}
