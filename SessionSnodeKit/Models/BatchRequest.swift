// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import PromiseKit
import SessionUtilitiesKit

internal extension SnodeAPI {
    struct BatchRequest: Encodable {
        let requests: [BatchSubRequest]
        
        init(requests: [SnodeAPIBatchRequestInfoType]) {
            self.requests = requests.map { $0.toSubRequest() }
        }
    }
    
    // MARK: - BatchSubRequest
    
    struct BatchSubRequest: Encodable {
        enum CodingKeys: String, CodingKey {
            case method
            case params
        }
        
        let endpoint: SnodeAPI.Endpoint
        
        /// The `jsonBodyEncoder` is used to avoid having to make `BatchSubRequest` a generic type (haven't found a good way
        /// to keep `BatchSubRequest` encodable using protocols unfortunately so need this work around)
        private let jsonBodyEncoder: ((inout KeyedEncodingContainer<CodingKeys>, CodingKeys) throws -> ())?
        
        init<T: Encodable>(request: SnodeRequest<T>) {
            self.endpoint = request.endpoint
            
            self.jsonBodyEncoder = { [params = request.params] container, key in
                try container.encode(params, forKey: key)
            }
        }
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

            try container.encode(endpoint.rawValue, forKey: .method)
            try jsonBodyEncoder?(&container, .params)
        }
    }
    
    // MARK: - BatchRequestInfo<T, R>
    
    struct BatchRequestInfo<T: Encodable>: SnodeAPIBatchRequestInfoType {// TODO: Can just use EndpointType and use the existing one???
        let request: SnodeRequest<T>
        public let responseType: Codable.Type
        public var endpoint: SnodeAPI.Endpoint { request.endpoint }
        
        public init<R: Codable>(request: SnodeRequest<T>, responseType: R.Type) {
            self.request = request
            self.responseType = HTTP.BatchSubResponse<R>.self
        }
        
        public init(request: SnodeRequest<T>) {
            self.init(
                request: request,
                responseType: NoResponse.self
            )
        }
        
        public func toSubRequest() -> SnodeAPI.BatchSubRequest {
            return BatchSubRequest(request: request)
        }
    }
}

/// This protocol is designed to erase the types from `BatchRequestInfo<T, R>` so multiple types can be used
/// in arrays when doing `/batch` and `/sequence` requests
internal protocol SnodeAPIBatchRequestInfoType {
    var responseType: Codable.Type { get }
    var endpoint: SnodeAPI.Endpoint { get }

    func toSubRequest() -> SnodeAPI.BatchSubRequest
}

internal extension Promise where T == HTTP.BatchResponse {
    func map<E: EndpointType>(
        requests: [SnodeAPIBatchRequestInfoType],
        toHashMapFor endpointType: E.Type
    ) -> Promise<[E: (info: ResponseInfoType, data: Codable?)]> {
        return self.map { result in
            result.enumerated()
                .reduce(into: [:]) { prev, next in
                    guard let endpoint: E = requests[next.offset].endpoint as? E else { return }
                    
                    prev[endpoint] = next.element
                }
        }
    }
}
