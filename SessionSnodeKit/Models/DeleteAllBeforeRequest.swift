// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

extension SnodeAPI {
    public class DeleteAllBeforeRequest: SnodeAuthenticatedRequestBody {
        enum CodingKeys: String, CodingKey {
            case beforeMs = "before"
            case namespace
        }
        
        let beforeMs: UInt64
        let namespace: SnodeAPI.Namespace?
        
        // MARK: - Init
        
        public init(
            beforeMs: UInt64,
            namespace: SnodeAPI.Namespace?,
            authInfo: AuthenticationInfo,
            timestampMs: UInt64
        ) {
            self.beforeMs = beforeMs
            self.namespace = namespace
            
            super.init(
                authInfo: authInfo,
                timestampMs: timestampMs
            )
        }
        
        // MARK: - Coding
        
        override public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(beforeMs, forKey: .beforeMs)
            
            // If no namespace is specified it defaults to the default namespace only (namespace
            // 0), so instead in this case we want to explicitly delete from `all` namespaces
            switch namespace {
                case .some(let namespace): try container.encode(namespace, forKey: .namespace)
                case .none: try container.encode("all", forKey: .namespace)
            }
            
            try super.encode(to: encoder)
        }
        
        // MARK: - Abstract Methods
        
        override func generateSignature(using dependencies: Dependencies) throws -> [UInt8] {
            /// Ed25519 signature of `("delete_before" || namespace || before)`, signed by
            /// `pubkey`.  Must be base64 encoded (json) or bytes (OMQ).  `namespace` is the stringified
            /// version of the given non-default namespace parameter (i.e. "-42" or "all"), or the empty
            /// string for the default namespace (whether explicitly given or not).
            let verificationBytes: [UInt8] = SnodeAPI.Endpoint.deleteAllBefore.path.bytes
                .appending(
                    contentsOf: (namespace == nil ?
                        "all" :
                        namespace?.verificationString
                    )?.bytes
                )
                .appending(contentsOf: "\(beforeMs)".data(using: .ascii)?.bytes)
            
            return try authInfo.generateSignature(with: verificationBytes, using: dependencies)
        }
    }
}
