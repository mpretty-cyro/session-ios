// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import PromiseKit
import SessionUtilitiesKit

public protocol RequestAPIType {
    static func sendRequest(_ db: Database, to snode: Snode, invoking method: SnodeAPIEndpoint, with parameters: JSON, associatedWith publicKey: String?) -> Promise<Data>
    static func sendRequest(_ db: Database, request: URLRequest, to server: String, using version: OnionRequestAPIVersion, with x25519PublicKey: String, timeout: TimeInterval) -> Promise<(OnionRequestResponseInfoType, Data?)>
}

public extension RequestAPIType {
    static func sendRequest(_ db: Database, request: URLRequest, to server: String, with x25519PublicKey: String, timeout: TimeInterval = HTTP.timeout) -> Promise<(OnionRequestResponseInfoType, Data?)> {
        sendRequest(db, request: request, to: server, using: .v4, with: x25519PublicKey, timeout: timeout)
    }
}

public enum RequestAPI: RequestAPIType {
    public enum RequestAPIError: Error {
        case networkWrappersNotReady
    }
        
    public struct Timing {
        let requestType: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let didError: Bool
        let didTimeout: Bool
        
        func with(endTime: TimeInterval = -1, didError: Bool = false, didTimeout: Bool = false) -> Timing {
            return Timing(
                requestType: requestType,
                startTime: startTime,
                endTime: endTime,
                didError: didError,
                didTimeout: didTimeout
            )
        }
    }
    
    public static var onionRequestTiming: Atomic<[String: Timing]> = Atomic([:])
    public static var lokinetRequestTiming: Atomic<[String: Timing]> = Atomic([:])
    
    public enum NetworkLayer: String, Codable, CaseIterable, Equatable, Hashable, EnumStringSetting, Differentiable {
        case onionRequest
        case lokinet
        case nativeLokinet
        case direct
        case onionAndLokiComparison
        
        public static let defaultLayer: NetworkLayer = .onionRequest
        
        public var name: String {
            switch self {
                case .onionRequest: return "Onion Requests"
                case .lokinet: return "Lokinet"
                case .nativeLokinet: return "Native Lokinet"
                case .direct: return "Direct"
                case .onionAndLokiComparison: return "Onion Requests and Lokinet"
            }
        }
        
        public static func didChangeNetworkLayer() {
            NotificationCenter.default.post(name: .networkLayerChanged, object: nil, userInfo: nil)
            
            LokinetWrapper.stop()
            GetSnodePoolJob.run()
            
            // Cancel and remove all current requests
            RequestAPI.currentRequests.mutate { requests in
                requests.forEach { $0.task?.cancel() }
                requests = []
            }
        }
    }
    
    fileprivate static let currentRequests: Atomic<[RequestContainer<(OnionRequestResponseInfoType, Data?)>]> = Atomic([])
    
    public static func sendRequest(_ db: Database, to snode: Snode, invoking method: SnodeAPIEndpoint, with parameters: JSON, associatedWith publicKey: String? = nil) -> Promise<Data> {
        let payloadJson: JSON = [ "method" : method.rawValue, "params" : parameters ]
        
        guard let payload: Data = try? JSONSerialization.data(withJSONObject: payloadJson, options: []) else {
            return Promise(error: HTTP.Error.invalidJSON)
        }
        
        /// **Note:** Currently the service nodes only support V3 Onion Requests
        return sendRequest(
            db,
            method: .post,
            headers: [:],
            endpoint: "storage_rpc/v1",
            body: (onion: payload, loki: payload),
            to: OnionRequestAPIDestination.snode(snode),
            version: .v3
        )
        .map { _, maybeData in
            guard let data: Data = maybeData else { throw HTTP.Error.invalidResponse }

            return data
        }
        .recover2 { error -> Promise<Data> in
            let layer: NetworkLayer = Storage.shared[.debugNetworkLayer].defaulting(to: .defaultLayer)
            
            guard
                layer == .onionRequest,
                case OnionRequestAPIError.httpRequestFailedAtDestination(let statusCode, let data, _) = error
            else { throw error }
            
            throw SnodeAPI.handleError(withStatusCode: statusCode, data: data, forSnode: snode, associatedWith: publicKey) ?? error
        }
    }
    
    /// Sends an onion request to `server`. Builds new paths as needed.
    public static func sendRequest(
        _ db: Database,
        request: URLRequest,
        to server: String,
        using version: OnionRequestAPIVersion = .v4,
        with x25519PublicKey: String,
        timeout: TimeInterval = HTTP.timeout
    ) -> Promise<(OnionRequestResponseInfoType, Data?)> {
        guard let url = request.url, let host = request.url?.host else {
            return Promise(error: OnionRequestAPIError.invalidURL)
        }
        
        var endpoint = url.path.removingPrefix("/")
        if let query = url.query { endpoint += "?\(query)" }
        let scheme = url.scheme
        let port = url.port.map { UInt16($0) }
        let headers: [String: String] = (request.allHTTPHeaderFields ?? [:])
            .setting(
                "Content-Type",
                (request.httpBody == nil ? nil :
                    // Default to JSON if not defined
                    ((request.allHTTPHeaderFields ?? [:])["Content-Type"] ?? "application/json")
                )
            )
            .removingValue(forKey: "User-Agent")
        
        let layer: NetworkLayer = db[.debugNetworkLayer].defaulting(to: .defaultLayer)
        let destination = OnionRequestAPIDestination.server(
            host: host,
            target: version.rawValue,
            x25519PublicKey: x25519PublicKey,
            scheme: scheme,
            port: port
        )
        let body: (onion: Data?, loki: Data?)?
        
        switch layer {
            case .onionRequest:
                guard let payload: Data = OnionRequestAPI.generatePayload(for: request, with: version) else {
                    return Promise(error: OnionRequestAPIError.invalidRequestInfo)
                }
                
                body = (onion: payload, loki: nil)
                break
                
            case .onionAndLokiComparison:
                guard let payload: Data = OnionRequestAPI.generatePayload(for: request, with: version) else {
                    return Promise(error: OnionRequestAPIError.invalidRequestInfo)
                }
                
                body = (onion: payload, loki: request.httpBody)
                break
            
            default: body = (onion: nil, loki: request.httpBody)
        }
        
        return sendRequest(
            db,
            method: (HTTP.Verb.from(request.httpMethod) ?? .get),   // The default (if nil) is 'GET'
            headers: headers,
            endpoint: endpoint,
            body: body,
            to: destination,
            version: version
        )
    }
    
    public static func printTimingComparison() {
        enum RequestCategory {
            case snode
            case sogs
            case file
        }
        struct Stats {
            let label: String
            let successes: Int
            let errors: Int
            let timeouts: Int
            let incomplete: Int
            let averageMs: Double
            
            var durationString: String { (averageMs == -1 ? "`N/A`" : "`\(label) \(averageMs)ms`") }
            var overviewString: String {
                guard successes > 0 || errors > 0 || timeouts > 0 else { return "\(label) - N/A" }
                
                return "\(label) `\(successes)/\(successes + errors)` requests successful, avg. response time: \(averageMs == -1 ? "`N/A`" : "`\(averageMs)ms`")"
            }
            var detailedOverviewString: String {
                guard successes > 0 || errors > 0 || timeouts > 0 else { return "\(label) - No Stats" }
                
                return "\(label) Successful: \(successes), Errors: \(errors), Avg: \(averageMs == -1 ? "N/A" : "\(averageMs)ms")"
            }
            
            init(label: String) {
                self.label = label
                self.successes = 0
                self.errors = 0
                self.timeouts = 0
                self.incomplete = 0
                self.averageMs = -1
            }
            
            init(
                label: String,
                successes: Int,
                errors: Int,
                timeouts: Int,
                incomplete: Int,
                averageMs: Double
            ) {
                self.label = label
                self.successes = successes
                self.errors = errors
                self.timeouts = timeouts
                self.incomplete = incomplete
                self.averageMs = averageMs
            }
        }
        
        
        let onionRequestTiming: [String: Timing] = RequestAPI.onionRequestTiming.wrappedValue
        let lokinetRequestTiming: [String: Timing] = RequestAPI.lokinetRequestTiming.wrappedValue
        let requestsToTrack: [(type: String, category: RequestCategory)] = [
            ("Snode: retrieve", .snode),
            ("Snode: store", .snode),
            ("chat.lokinet.dev: batch", .sogs),
            ("chat.lokinet.dev: sequence", .sogs),
            ("chat.lokinet.dev: room/", .sogs),  // Don't split between rooms
            ("open.getsession.org: batch", .sogs),
            ("open.getsession.org: sequence", .sogs),
            ("open.getsession.org: room/", .sogs),  // Don't split between rooms
            ("dan.lokinet.dev: batch", .sogs),
            ("dan.lokinet.dev: sequence", .sogs),
            ("dan.lokinet.dev: room/", .sogs),  // Don't split between rooms
            ("filev2.getsession.org: file/", .file)  // Don't split between files
        ]
        
        func stats(label: String, data: [String: Timing], filters: [String] = []) -> Stats {
            let filteredData: [String: Timing] = (filters.isEmpty ? data :
                data.filter { _, value in
                    filters.contains(where: { filter in
                        value.requestType.starts(with: filter.replacingOccurrences(of: "%", with: ""))
                    })
                }
            )
            
            guard !filteredData.isEmpty else { return Stats(label: label) }
            
            let numComplete: Int = filteredData
                .filter { !$0.value.didError && !$0.value.didTimeout && $0.value.endTime != -1 }
                .count
            let totalDuration: TimeInterval = filteredData
                .filter { !$0.value.didError && !$0.value.didTimeout && $0.value.endTime != -1 }
                .map { ($0.value.endTime - $0.value.startTime) }
                .reduce(0, +)
            
            return Stats(
                label: label,
                successes: filteredData
                    .filter { !$0.value.didError && !$0.value.didTimeout && $0.value.endTime != -1 }
                    .count,
                errors: filteredData
                    .filter { $0.value.didError }
                    .count,
                timeouts: filteredData
                    .filter { $0.value.didTimeout }
                    .count,
                incomplete: filteredData
                    .filter { !$0.value.didError && !$0.value.didTimeout && $0.value.endTime == -1 }
                    .count,
                averageMs: (numComplete > 0 ? ((totalDuration / TimeInterval(numComplete)) * 1000) : -1)
            )
        }
        func get(requestType: String, from data: [String: Timing], with index: Int? = nil) -> String {
            let indexStr: String? = index.map { String(format: " %02d", $0) }
            
            guard let item: Timing = data[requestType] else { return "\(requestType)\(indexStr ?? ""): Incomplete" }
            guard !item.didTimeout else { return "\(item.requestType)\(indexStr ?? ""): Timeout" }
            guard !item.didError else { return "\(item.requestType)\(indexStr ?? ""): Error" }
            guard item.endTime != -1 else { return "\(item.requestType)\(indexStr ?? ""): Incomplete" }
            
            return "\(item.requestType)\(indexStr ?? ""): \((item.endTime - item.startTime) * 1000)ms"
        }
        
        let results: [String: (onion: [String], loki: [String])] = requestsToTrack
            .reduce(into: [:]) { result, requestInfo in
                let onionTimingForRequestType: [String: Timing] = onionRequestTiming
                    .filter { $0.value.requestType.starts(with: requestInfo.type.replacingOccurrences(of: "%", with: "")) }
                let lokiTimingForRequestType: [String: Timing] = lokinetRequestTiming
                    .filter { $0.value.requestType.starts(with: requestInfo.type.replacingOccurrences(of: "%", with: "")) }
                
                // Add the overall stats
                if !onionTimingForRequestType.isEmpty || !lokiTimingForRequestType.isEmpty {
                    let updatedOnion: [String] = (result[requestInfo.type]?.onion ?? [])
                        .appending(stats(label: "\(requestInfo.type) -", data: onionTimingForRequestType).detailedOverviewString)
                    let updatedLoki: [String] = (result[requestInfo.type]?.loki ?? [])
                        .appending(stats(label: "\(requestInfo.type) -", data: lokiTimingForRequestType).detailedOverviewString)
                    result[requestInfo.type] = (updatedOnion, updatedLoki)
                }
                
                // Add the specific timing
                onionTimingForRequestType
                    .enumerated()
                    .forEach { index, item in
                        guard lokinetRequestTiming[item.key] != nil else { return }
                        
                        let updatedOnion: [String] = (result[requestInfo.type]?.onion ?? [])
                            .appending(get(requestType: item.key, from: onionRequestTiming, with: index))
                        let updatedLoki: [String] = (result[requestInfo.type]?.loki ?? [])
                            .appending(get(requestType: item.key, from: lokinetRequestTiming, with: index))
                        result[requestInfo.type] = (updatedOnion, updatedLoki)
                    }
            }
        
        let snodeFilters: [String] = requestsToTrack.filter { $0.category == .snode }.map { $0.type }
        let sogsFilters: [String] = requestsToTrack.filter { $0.category == .sogs }.map { $0.type }
        var outputString: String = ""
        outputString += "\n    **Overview:**"
        outputString += "\n        **Onion Requests:**"
        outputString += "\n            \(stats(label: "Startup -", data: onionRequestTiming, filters: ["Startup"]).durationString)"
        outputString += "\n            \(stats(label: "Snode   -", data: onionRequestTiming, filters: snodeFilters).overviewString)"
        outputString += "\n            \(stats(label: "SOGS    -", data: onionRequestTiming, filters: sogsFilters).overviewString)"
        
        outputString += "\n"
        outputString += "\n        **Loki Requests:**"
        outputString += "\n            \(stats(label: "Startup -", data: lokinetRequestTiming, filters: ["Startup"]).durationString)"
        outputString += "\n            \(stats(label: "Snode   -", data: lokinetRequestTiming, filters: snodeFilters).overviewString)"
        outputString += "\n            \(stats(label: "SOGS    -", data: lokinetRequestTiming, filters: sogsFilters).overviewString)"
        
        _ = onionRequestTiming
            .filter { $0.value.requestType.starts(with: "GetSnodePool") }
            .filter { !$0.value.didError && !$0.value.didTimeout && $0.value.endTime != -1 }
            .enumerated()
            .map { index, item in get(requestType: item.key, from: onionRequestTiming, with: index) }
            .sorted()
            .first
            .map { value in
                outputString += "\n"
                outputString += "\n    Shared:"
                outputString += "\n      \(value)"
                
                return ()
            }
        
        outputString += "\n"
        outputString += "\n    Onion Requests:"
        outputString += "\n      \(get(requestType: "Startup", from: onionRequestTiming))"
        results.forEach { _, value in
            outputString += "\n"
            
            value.onion.sorted().forEach { result in outputString += "\n      \(result)" }
        }
        
        outputString += "\n"
        outputString += "\n    Loki Requests:"
        outputString += "\n      \(get(requestType: "Startup", from: lokinetRequestTiming))"
        results.forEach { _, value in
            outputString += "\n"
            
            value.loki.sorted().forEach { result in outputString += "\n      \(result)" }
        }
        
        let untrackedRequests = onionRequestTiming
            .filter { item in !requestsToTrack.map { $0.type }.contains(where: { item.value.requestType.starts(with: $0) }) }
            .filter { item in !item.key.starts(with: "Startup") && !item.key.starts(with: "GetSnodePool") }
        
        outputString += "\n\n    Excluded \(untrackedRequests.count) request(s)"
        
        print(outputString)
    }
    
    private static func sendRequest(
        _ db: Database,
        method: HTTP.Verb,
        headers: [String: String],
        endpoint: String,
        body: (
            onion: Data?,
            loki: Data?
        )?,
        to destination: OnionRequestAPIDestination,
        version: OnionRequestAPIVersion = .v4,
        timeout: TimeInterval = HTTP.timeout
    ) -> Promise<(OnionRequestResponseInfoType, Data?)> {
        let layer: NetworkLayer = db[.debugNetworkLayer].defaulting(to: .defaultLayer)
        
        switch layer {
            case .onionRequest: break
            case .nativeLokinet: break
            case .direct: break
                
            case .lokinet:
                guard LokinetWrapper.isReady else {
                    return Promise(error: RequestAPI.RequestAPIError.networkWrappersNotReady)
                }
                
                break
                
            case .onionAndLokiComparison:
                guard LokinetWrapper.isReady && !OnionRequestAPI.paths(db).isEmpty else {
                    return Promise(error: RequestAPI.RequestAPIError.networkWrappersNotReady)
                }
                
                break
        }
        
        let containers: [RequestContainer<(OnionRequestResponseInfoType, Data?)>] = {
            let layer: NetworkLayer = db[.debugNetworkLayer].defaulting(to: .defaultLayer)

            switch layer {
                case .onionRequest:
                    guard let payload: Data = body?.onion else {
                        return [RequestContainer(promise: Promise(error: OnionRequestAPIError.invalidRequestInfo))]
                    }
                    
                    return [
                        OnionRequestAPI
                            .sendOnionRequest(
                                with: payload,
                                to: destination,
                                version: version,
                                timeout: timeout
                            )
                    ]
                    
                case .lokinet:
                    return [
                        LokinetRequestAPI
                            .sendLokinetRequest(
                                method,
                                endpoint: endpoint,
                                headers: headers,
                                body: body?.loki,
                                destination: destination,
                                timeout: timeout
                            )
                    ]
                    
                case .nativeLokinet:
                    return [
                        NativeLokinetRequestAPI
                            .sendNativeLokinetRequest(
                                method,
                                endpoint: endpoint,
                                headers: headers,
                                body: body?.loki,
                                destination: destination,
                                timeout: timeout
                            )
                    ]
                    
                case .direct:
                    return [
                        DirectRequestAPI
                            .sendDirectRequest(
                                method,
                                endpoint: endpoint,
                                headers: headers,
                                body: body?.loki,
                                destination: destination,
                                timeout: timeout
                            )
                    ]
                    
                case .onionAndLokiComparison:
                    guard let payload: Data = body?.onion else {
                        return [RequestContainer(promise: Promise(error: OnionRequestAPIError.invalidRequestInfo))]
                    }
                    
                    let requestId: UUID = UUID()
                    let requestType: String = {
                        let payload: Any? = body?.onion
                            .map { try? JSONSerialization.jsonObject(with: $0) }
                        let fallback: String = {
                            switch destination {
                                case .snode: return "Snode: \(endpoint)"
                                case .server(let host, _, _, _, _): return "\(host): \(endpoint)"
                            }
                        }()
                        
                        return (
                            ((payload as? [String: Any])?["method"] as? String).map { "Snode: \($0)" } ??
                            fallback
                        )
                    }()
                    let startTime: TimeInterval = CACurrentMediaTime()
                    RequestAPI.onionRequestTiming.mutate {
                        $0[requestId.uuidString] = Timing(
                            requestType: requestType,
                            startTime: startTime,
                            endTime: -1,
                            didError: false,
                            didTimeout: false
                        )
                    }
                    RequestAPI.lokinetRequestTiming.mutate {
                        $0[requestId.uuidString] = Timing(
                            requestType: requestType,
                            startTime: startTime,
                            endTime: -1,
                            didError: false,
                            didTimeout: false
                        )
                    }
                    
                    let container1 = OnionRequestAPI
                        .sendOnionRequest(
                            with: payload,
                            to: destination,
                            version: version,
                            timeout: timeout
                        )
                        .map { result in
                            let endTime: TimeInterval = CACurrentMediaTime()
                            RequestAPI.onionRequestTiming.mutate {
                                $0[requestId.uuidString] = $0[requestId.uuidString]?.with(endTime: endTime)
                            }
                            return result
                        }
                    container1.promise.catch2 { error in
                        print("[Lokinet] RAWR \(error)")
                        let isTimeout: Bool = {
                            switch error {
                                case HTTP.Error.timeout: return true
                                default: return false
                            }
                        }()
                        RequestAPI.onionRequestTiming.mutate {
                            $0[requestId.uuidString] = $0[requestId.uuidString]?
                                .with(
                                    didError: !isTimeout,
                                    didTimeout: isTimeout
                                )
                        }
                    }
                    
                    let container2 = LokinetRequestAPI
                        .sendLokinetRequest(
                            method,
                            endpoint: endpoint,
                            headers: headers,
                            body: body?.loki,
                            destination: destination,
                            timeout: timeout
                        )
                        .map { result in
                            let endTime: TimeInterval = CACurrentMediaTime()
                            RequestAPI.lokinetRequestTiming.mutate {
                                $0[requestId.uuidString] = $0[requestId.uuidString]?.with(endTime: endTime)
                            }
                            return result
                        }
                    container2.promise.catch2 { _ in
                        RequestAPI.lokinetRequestTiming.mutate {
                            $0[requestId.uuidString] = $0[requestId.uuidString]?.with(didError: true)
                        }
                    }
                    
                    return [container1, container2]
            }
        }()
        
        // Add the request from the cache
        RequestAPI.currentRequests.mutate { requests in
            requests = requests.appending(contentsOf: containers)
        }
        
        // Handle `clockOffset` setting
        return when(resolved: containers.map { $0.promise })
            .then2 { results in
                guard
                    let result = results.first(where: { $0.isFulfilled }),
                    case let .fulfilled(response) = result,
                    let data: Data = response.1,
                    let json: JSON = try? JSONSerialization.jsonObject(with: data, options: [ .fragmentsAllowed ]) as? JSON,
                    let timestamp: Int64 = json["t"] as? Int64
                else {
                    switch results[0] {
                        case .fulfilled(let result): return Promise.value(result)
                        case .rejected(let error): return Promise(error: error)
                    }
                }
                    
                let offset = timestamp - Int64(floor(Date().timeIntervalSince1970 * 1000))
                SnodeAPI.clockOffsetMs.mutate { $0 = offset }
                
                return Promise.value(response)
            }
            .ensure {
                // Remove the request from the cache
                RequestAPI.currentRequests.mutate { requests in
                    requests = requests.filter { !containers.map { $0.uuid }.contains($0.uuid) }
                }
            }
    }
}

public class RequestContainer<T> {
    public let uuid: UUID = UUID()
    public let promise: Promise<T>
    public var task: URLSessionDataTask?
    
    init(promise: Promise<T>, task: URLSessionDataTask? = nil) {
        self.promise = promise
        self.task = task
    }
    
    public func map<U>(_ transform: @escaping(T) throws -> U) -> RequestContainer<U> {
        return RequestContainer<U>(promise: promise.map(transform), task: task)
    }
    
    public func recover2<U: Thenable>(_ body: @escaping(Error) throws -> U) -> RequestContainer<T> where U.T == T {
        return RequestContainer(promise: promise.recover2(body), task: task)
    }
}
