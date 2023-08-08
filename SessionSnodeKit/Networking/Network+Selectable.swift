// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUtilitiesKit

// MARK: - Caches

internal extension Network {
    fileprivate static let currentRequests: Atomic<[String: Subscription]> = Atomic([:])
    static let requestTiming: Atomic<[Layers: [String: Timing]]> = Atomic([:])
}

// MARK: - RequestType

public extension Network.RequestType {
    static func selectedNetworkRequest(
        _ payload: Data,
        to snode: Snode,
        timeout: TimeInterval = HTTP.defaultTimeout
    ) -> Network.RequestType<Data?> {
        let requestId: UUID = UUID()
        
        return Network.RequestType(
            id: "selectedNetworkRequest",
            url: snode.address,
            method: "POST",
            body: payload,
            args: [payload, snode, timeout]
        ) {
            let layers: Network.Layers = (Storage.shared[.networkLayers]
                .map { Int8($0) }
                .map { Network.Layers(rawValue: $0) })
                .defaulting(to: .defaultLayers)
            
            return Publishers
                .MergeMany(
                    layers.compactMap { layer -> AnyPublisher<Result<(ResponseInfoType, Data?), Error>, Never>? in
                        switch layer {
                            case .onionRequest:
                                return Network.RequestType<Data?>
                                    .onionRequest(payload, to: snode, timeout: timeout)
                                    .trackingTiming(id: requestId, layer: layer, snode: snode, body: payload)
                                
                            case .lokinet:
                                return Network.RequestType<Data?>
                                    .lokinetRequest(payload, to: snode, timeout: timeout)
                                    .trackingTiming(id: requestId, layer: layer, snode: snode, body: payload)
                                
                            case .nativeLokinet:
                                return Network.RequestType<Data?>
                                    .nativeLokinetRequest(payload, to: snode, timeout: timeout)
                                    .trackingTiming(id: requestId, layer: layer, snode: snode, body: payload)
                                
                            case .direct:
                                return Network.RequestType<Data?>
                                    .directRequest(payload, to: snode, timeout: timeout)
                                    .trackingTiming(id: requestId, layer: layer, snode: snode, body: payload)
                                
                            default: return nil
                        }
                    }
                )
                .collectAndReturnFirstSuccessResponse(id: requestId)
        }
    }
    
    static func selectedNetworkRequest(
        _ request: URLRequest,
        to server: String,
        with x25519PublicKey: String,
        timeout: TimeInterval = HTTP.defaultTimeout
    ) -> Network.RequestType<Data?> {
        let requestId: UUID = UUID()
        
        return Network.RequestType(
            id: "selectedNetworkRequest",
            url: request.url?.absoluteString,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields,
            body: request.httpBody,
            args: [request, server, x25519PublicKey, timeout]
        ) {
            let layers: Network.Layers = (Storage.shared[.networkLayers]
                .map { Int8($0) }
                .map { Network.Layers(rawValue: $0) })
                .defaulting(to: .defaultLayers)
            
            return Publishers
                .MergeMany(
                    layers.compactMap { layer -> AnyPublisher<Result<(ResponseInfoType, Data?), Error>, Never>? in
                        switch layer {
                            case .onionRequest:
                                return Network.RequestType<Data?>
                                    .onionRequest(
                                        request,
                                        to: server,
                                        with: x25519PublicKey,
                                        timeout: timeout
                                    )
                                    .trackingTiming(id: requestId, layer: layer, request: request)
                                
                            case .lokinet:
                                return Network.RequestType<Data?>
                                    .lokinetRequest(
                                        request,
                                        to: server,
                                        with: x25519PublicKey,
                                        timeout: timeout
                                    )
                                    .trackingTiming(id: requestId, layer: layer, request: request)
                                
                            case .nativeLokinet:
                                return Network.RequestType<Data?>
                                    .nativeLokinetRequest(
                                        request,
                                        to: server,
                                        with: x25519PublicKey,
                                        timeout: timeout
                                    )
                                    .trackingTiming(id: requestId, layer: layer, request: request)
                                
                            case .direct:
                                return Network.RequestType<Data?>
                                    .directRequest(
                                        request,
                                        to: server,
                                        with: x25519PublicKey,
                                        timeout: timeout
                                    )
                                    .trackingTiming(id: requestId, layer: layer, request: request)
                                
                            default: return nil
                        }
                    }
                )
                .collectAndReturnFirstSuccessResponse(id: requestId)
        }
    }
}

// MARK: - Network.Layers

public extension Network {
    struct Layers: OptionSet, Equatable, Hashable, Differentiable {
        public let rawValue: Int8
        
        public init(rawValue: Int8) {
            self.rawValue = rawValue
        }
        
        public static let onionRequest: Layers = Layers(rawValue: 1 << 0)
        public static let lokinet: Layers = Layers(rawValue: 1 << 1)
        public static let nativeLokinet: Layers = Layers(rawValue: 1 << 2)
        public static let direct: Layers = Layers(rawValue: 1 << 3)
        
        // MARK: - Convenience
        
        public static let defaultLayers: Layers = [.onionRequest]
        public static let all: Layers = [.onionRequest, .lokinet, .nativeLokinet, .direct]
        
        // MARK: - Varaibles
        
        public var name: String {
            let individualLayerNames: [String] = [
                (self.contains(.onionRequest) ? "Onion Requests" : nil),
                (self.contains(.lokinet) ? "Lokinet" : nil),
                (self.contains(.nativeLokinet) ? "Native Lokinet" : nil),
                (self.contains(.direct) ? "Direct" : nil)
            ].compactMap { $0 }
            
            guard individualLayerNames.count > 1 else { return individualLayerNames[0] }
            
            return [
                individualLayerNames
                    .removing(index: individualLayerNames.count - 1)
                    .joined(separator: ", "),
                individualLayerNames[individualLayerNames.count - 1]
            ]
            .joined(separator: " and ")
        }
        
        public var description: String {
            switch self {
                case .onionRequest: return "Send requests over the original Onion Request mechanism"
                case .lokinet: return "Send requests over Lokinet"
                case .nativeLokinet: return "Send requests directly but using libLokinet to generate the target destination (designed to work with router-based Lokinet)"
                case .direct: return "Send requests directly over HTTPS"
                default: return "This is a combination of multiple network layers, requests will be sent over each layer (triggered at the same time)"
            }
        }
        
        // MARK: - Functions
        
        public static func didChangeNetworkLayer() {
            NotificationCenter.default.post(name: .networkLayerChanged, object: nil, userInfo: nil)
            
            LokinetWrapper.stop()
            GetSnodePoolJob.run()
            
            // Cancel and remove all current requests
            Network.currentRequests.mutate { requests in
                requests.forEach { _, value in value.cancel() }
                requests = [:]
            }
        }
        
        public func map<R>(_ transform: (Layers) -> R) -> [R] {
            return [
                (self.contains(.onionRequest) ? transform(.onionRequest) : nil),
                (self.contains(.lokinet) ? transform(.lokinet) : nil),
                (self.contains(.nativeLokinet) ? transform(.nativeLokinet) : nil),
                (self.contains(.direct) ? transform(.direct) : nil)
            ]
            .compactMap { $0 }
        }
        
        public func compactMap<R>(_ transform: (Layers) -> R?) -> [R] {
            return [
                (self.contains(.onionRequest) ? transform(.onionRequest) : nil),
                (self.contains(.lokinet) ? transform(.lokinet) : nil),
                (self.contains(.nativeLokinet) ? transform(.nativeLokinet) : nil),
                (self.contains(.direct) ? transform(.direct) : nil)
            ]
            .compactMap { $0 }
        }
    }
}

// MARK: - Settings

public extension Setting.IntKey {
    /// This is the currently selected network layers to use when making requests
    static let networkLayers: Setting.IntKey = "networkLayers"
}

// MARK: - Network.Timing

internal extension Network {
    struct Timing {
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
}

fileprivate extension Network.RequestType {
    func trackingTiming(
        id: UUID,
        layer: Network.Layers,
        snode: Snode? = nil,
        request: URLRequest? = nil,
        body: Data? = nil
    ) -> AnyPublisher<Result<(ResponseInfoType, T), Error>, Never> {
        let finalBody: Data? = (body ?? request?.httpBody)
        let requestType: String = {
            switch (snode, request) {
                case (.some(snode), _):
                    guard
                        let payload: Any? = finalBody.map({ try? JSONSerialization.jsonObject(with: $0) }),
                        let method: String = (payload as? [String: Any])?["method"] as? String
                    else { return "Snode: Unknown" }
                    
                    return "Snode: \(method)"
                    
                case (_, .some(request)):
                    guard let url: URL = request?.url, let host: String = url.host else { return "Invalid" }
                    
                    let endpoint = url.path.removingPrefix("/")
                    return "\(host): \(endpoint)"
                    
                default: return "Invalid"
            }
        }()
        
        return self
            .generatePublisher()
            .handleEvents(
                receiveSubscription: { _ in
                    Network.requestTiming.mutate { timing in
                        timing[layer] = (timing[layer] ?? [:]).setting(
                            id.uuidString,
                            Network.Timing(
                                requestType: requestType,
                                startTime: CACurrentMediaTime(),
                                endTime: -1,
                                didError: false,
                                didTimeout: false
                            )
                        )
                    }
                },
                receiveOutput: { _ in
                    Network.requestTiming.mutate { timing in
                        let updatedTiming: Network.Timing? = (timing[layer] ?? [:])?[id.uuidString]?
                            .with(endTime: CACurrentMediaTime())
                        timing[layer]?[id.uuidString] = updatedTiming
                    }
                },
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            let isTimeout: Bool = {
                                switch error {
                                    case HTTPError.timeout: return true
                                    default: return false
                                }
                            }()
                            
                            Network.requestTiming.mutate { timing in
                                let updatedTiming: Network.Timing? = (timing[layer] ?? [:])?[id.uuidString]?
                                    .with(
                                        endTime: CACurrentMediaTime(),
                                        didError: !isTimeout,
                                        didTimeout: isTimeout
                                    )
                                timing[layer]?[id.uuidString] = updatedTiming
                            }
                    }
                }
            )
            .eraseToAnyPublisher()
            .asResult()
    }
}

// MARK: - Printing

public extension Network {
    @discardableResult static func printTimingComparison() -> String {
        enum RequestCategory {
            case snode
            case sogs
            case file
            case notifications
        }
        struct Stats {
            let label: String
            let successes: Int
            let errors: Int
            let timeouts: Int
            let incomplete: Int
            let averageMs: Double
            
            var durationString: String { (averageMs == -1 ? "`N/A`" : "\(label) `\(averageMs)ms`") }
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
        
        let requestTiming: [Layers: [String: Timing]] = Network.requestTiming.wrappedValue
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
            ("filev2.getsession.org: file/", .file),  // Don't split between files
            ("live.apns.getsession.org: notify", .notifications),
            ("dev.apns.getsession.org: notify", .notifications)
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
        
        let results: [String: [Layers: [String]]] = requestsToTrack
            .reduce(into: [:]) { result, requestInfo in
                let requestInfoForLayers: [Layers: [String: Timing]] = requestTiming
                    .reduce(into: [:]) { result, next in
                        result[next.key] = next.value.filter { _, timing in
                            timing.requestType.starts(with: requestInfo.type.replacingOccurrences(of: "%", with: ""))
                        }
                    }
                
                // Ignore if there isn't timing info for the given request for each layer
                guard requestInfoForLayers.count == requestTiming.count else { return }
                
                // Add the stats
                result[requestInfo.type] = requestInfoForLayers.mapValues { timingData in
                    [
                        // Overall stats
                        [stats(label: "\(requestInfo.type) -", data: timingData).detailedOverviewString],
                        
                        // Specific timing
                        timingData
                            .enumerated()
                            .map { index, item in get(requestType: item.key, from: timingData, with: index) }
                    ].reduce([], +)
                }
            }
        
        let snodeFilters: [String] = requestsToTrack.filter { $0.category == .snode }.map { $0.type }
        let sogsFilters: [String] = requestsToTrack.filter { $0.category == .sogs }.map { $0.type }
        var outputString: String = ""
        outputString += "\n    **Overview:**"
        
        // Overview
        requestTiming.forEach { layers, timingData in
            outputString += "\n        **\(layers.name):**"
            outputString += "\n            \(stats(label: "Startup -", data: timingData, filters: ["Startup"]).durationString)"
            outputString += "\n            \(stats(label: "Snode   -", data: timingData, filters: snodeFilters).overviewString)"
            outputString += "\n            \(stats(label: "SOGS    -", data: timingData, filters: sogsFilters).overviewString)"
            outputString += "\n"
        }
        
        // Shared Info
        if let onionRequestTiming: [String: Timing] = requestTiming[.onionRequest] {
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
        }
        
        // Request Info
        requestTiming.forEach { layers, timingData in
            outputString += "\n"
            outputString += "\n    \(layers.name):"
            outputString += "\n      \(get(requestType: "Startup", from: timingData))"
            results
                .sorted(by: { lhs, rhs in lhs.key < rhs.key })
                .compactMap { _, value in value[layers] }
                .forEach { results in
                    outputString += "\n"
                    
                    results.sorted().forEach { result in outputString += "\n      \(result)" }
                }
        }
        
        // Untracked Request Info
        let untrackedRequestData: [Layers: [String: Timing]] = requestTiming
            .mapValues { timingData in
                timingData
                    .filter { item in
                        !requestsToTrack
                            .map { $0.type }
                            .contains(where: { item.value.requestType.starts(with: $0) })
                    }
                    .filter { item in !item.key.starts(with: "Startup") && !item.key.starts(with: "GetSnodePool") }
            }
            .filter { _, timingData in !timingData.isEmpty }
        
        if !untrackedRequestData.isEmpty {
            let untrackedCount: Int = untrackedRequestData.reduce(into: 0) { result, next in result += next.value.count }
            outputString += "\n\n    Excluded \(untrackedCount) request(s)"
        }
        
        print(outputString)
        return outputString
    }
}

// MARK: - Convenience

fileprivate extension Publishers.MergeMany where Upstream.Output == Result<(ResponseInfoType, Data?), Error> {
    func collectAndReturnFirstSuccessResponse(id: UUID) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        self
            .collect()
            .handleEvents(
                receiveSubscription: { subscription in
                    Network.currentRequests.mutate { $0[id.uuidString] = subscription }
                },
                receiveCompletion: { _ in
                    Network.currentRequests.mutate { $0[id.uuidString] = nil }
                }
            )
            .tryMap { (results: [Result<(ResponseInfoType, Data?), Error>]) -> (ResponseInfoType, Data?) in
                let results: [Result<(ResponseInfoType, Data?), Error>] = []
                guard
                    let result: Result<(ResponseInfoType, Data?), Error> = results.first(where: { result in
                        switch result {
                            case .success: return true
                            case .failure: return false
                        }
                    }),
                    case .success(let response) = result,
                    let data: Data = response.1,
                    let json: [String: Any] = try? JSONSerialization
                        .jsonObject(with: data, options: [ .fragmentsAllowed ]) as? [String: Any],
                    let timestamp: Int64 = json["t"] as? Int64
                else {
                    switch results.first {
                        case .success(let value): return value
                        case .failure(let error): throw error
                        default: throw HTTPError.networkWrappersNotReady
                    }
                }
                
                let offset: Int64 = timestamp - Int64(floor(Date().timeIntervalSince1970 * 1000))
                SnodeAPI.clockOffsetMs.mutate { $0 = offset }

                return response
            }
            .eraseToAnyPublisher()
    }
}
