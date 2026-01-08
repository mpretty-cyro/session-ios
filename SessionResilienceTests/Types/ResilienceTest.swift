// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Testing
import Foundation
import SessionUIKit
import SessionNetworkingKit

enum NetworkMode {
    case newNetworkPerRequest
    case shared
    
    var name: String {
        switch self {
            case .newNetworkPerRequest: return "New Network Per Request"
            case .shared: return "Single Network"
        }
    }
}

struct ResilienceTest {
    let name: String
    var totalRequests: Int = 0
    var retryCount: Int = 0
    var startTime: TimeInterval = 0
    var endTime: TimeInterval = 0
    var setupResult: Result<Void, Error> = .success(())
    
    var results: [Int: TestResult] = [:]
    var failedResults: [TestResult] = []
    
    private var latencies: [TimeInterval] = []
    private var totalLatency: TimeInterval = 0
    var averageLatency: TimeInterval = 0
    var medianLatency: TimeInterval = 0
    var minLatency: TimeInterval = .greatestFiniteMagnitude
    var maxLatency: TimeInterval = 0
    
    var successCount: Int { results.count - failedResults.count }
    var failureCount: Int { failedResults.count }
    
    init(name: String) {
        self.name = name
    }
    
    mutating func recordResult(attempt: Int, latency: TimeInterval, result: Result<Void, Error>) {
        let testResult: TestResult = TestResult(attempt: attempt, result: result)
        totalRequests += 1
        results[attempt] = testResult
        updateLatency(latency)
        
        switch result {
            case .failure: failedResults.append(testResult)
            default: break
        }
    }
    
    mutating func recordRetry() {
        retryCount += 1
    }
    
    mutating func recordTiming(startTime: TimeInterval, endTime: TimeInterval) {
        self.startTime = startTime
        self.endTime = endTime
    }
    
    private mutating func updateLatency(_ latency: TimeInterval) {
        latencies.append(latency)
        latencies.sort()
        
        if latency < minLatency { minLatency = latency }
        if latency > maxLatency { maxLatency = latency }
        
        let count: Int = latencies.count
        totalLatency += latency
        averageLatency = (totalLatency / Double(latencies.count))
        
        if count % 2 == 1 {
            medianLatency = latencies[count / 2]
        } else {
            let midIndex: Int = (count / 2)
            let middleValuesSum: TimeInterval = (latencies[midIndex - 1] + latencies[midIndex])
            medianLatency = (middleValuesSum / 2.0)
        }
    }
    
    var successRate: Double {
        guard totalRequests > 0 else { return 0 }
        return Double(successCount) / Double(totalRequests)
    }
    
    var failureRate: Double {
        guard totalRequests > 0 else { return 0 }
        return Double(failureCount) / Double(totalRequests)
    }
    
    var description: String {
        /// If the setup failed then just output the error
        switch setupResult {
            case .success: break
            case .failure(let error):
                return """
                
                \(name):
                ------------------------
                Failure during setup due to error: \(error)
                """
        }
        
        /// Otherwise, we want to output the stats
        let errorBreakdown: String = {
            guard failureCount > 0 else { return "" }
            
            return "\n" + failedResults
                .map { result in
                    guard let error: Error = result.error else {
                        return "No error"
                    }
                    
                    switch error {
                        case NetworkError.timeout: return "Timeout"
                        case NetworkError.requestFailed(let error, _):
                            if error.starts(with: "Decryption failed") {
                                return "Decryption failed"
                            }
                            
                            return error
                            
                        case NetworkError.badRequest(let error, _): return "400 Bad Request \(error)"
                        case NetworkError.unauthorised: return "401 Unauthorised"
                        case NetworkError.forbidden: return "403 Forbidden"
                        case NetworkError.notFound: return "404 Not found"
                        case SnodeAPIError.clockOutOfSync: return "406/425 Clock out of sync"
                        case SnodeAPIError.unassociatedPubkey: return "421 Pubkey not associated with swarm"
                        case SnodeAPIError.rateLimited: return "429 Rate limited"
                        case NetworkError.internalServerError: return "500 Internal server error"
                        case NetworkError.badGateway: return "502 Bad gateway"
                        case SnodeAPIError.nodeNotFound: return "502 Bad gateway (Node not found)"
                        case NetworkError.serviceUnavailable: return "503 Service Unavailable"
                        case NetworkError.gatewayTimeout: return "504 Gateway timeout"
                        default: return "Unknown error type: \(error)"
                    }
                }
                .reduce(into: [:]) { result, next in
                    result[next, default: []].append(next)
                }
                .map { key, values in "  - \(key): \(values.count)" }
                .joined(separator: "\n")
        }()
        
        return """
        
        \(name):
        ------------------------
        Successes: \(successCount) (\(String(format: "%.2f%%", successRate * 100)))
        Failures: \(failureCount) (\(String(format: "%.2f%%", failureRate * 100)))\(errorBreakdown)
        Retries: \(retryCount)
        Latency:
          - Average: \(String(format: "%.3fs", averageLatency))
          - Median: \(String(format: "%.3fs", medianLatency))
          - Min: \(String(format: "%.3fs", minLatency))
          - Max: \(String(format: "%.3fs", maxLatency))
          - Total: \(String(format: "%.3fs", endTime - startTime))
        """
    }
}

extension ResilienceTest {
    enum Variant {
        case sendMessage
        case sendAttachment(fileSize: UInt)
        case sendMessageWithAttachment(fileSize: UInt)
        case downloadAttachment(fileSize: UInt)
    }
    
    enum SendBehaviour {
        case concurrent(num: Int)
        case staggered(delayMs: Int)
        
        func description(with totalAttempts: Int) -> String {
            switch self {
                case .concurrent(let num):
                    return (num == 0 || num >= totalAttempts ?
                        "\(totalAttempts) at a time" :
                        "\(num) at a time"
                    )
                    
                case .staggered(let delay):
                    return "\(delay)ms between each"
            }
        }
    }
    
    struct Config: CustomTestStringConvertible {
        let mode: NetworkMode
        let numberOfAttempts: Int
        let variant: Variant
        let behaviour: SendBehaviour
        let numPaths: Int
        let simulateNetworkFailure: Bool
        let simulateStorageFailure: Bool
        let failureRate: Double // 0.0 to 1.0
        
        init(
            mode: NetworkMode,
            attempts: Int,
            variant: Variant,
            behaviour: SendBehaviour,
            numPaths: Int,
            fileSize: Int? = nil,
            simulateNetworkFailure: Bool = false,
            simulateStorageFailure: Bool = false,
            failureRate: Double = 0
        ) {
            self.mode = mode
            self.numberOfAttempts = attempts
            self.variant = variant
            self.behaviour = behaviour
            self.numPaths = numPaths
            self.simulateNetworkFailure = simulateNetworkFailure
            self.simulateStorageFailure = simulateStorageFailure
            self.failureRate = failureRate
        }
        
        var testDescription: String {
            let attemptString: String = {
                switch variant {
                    case .sendMessage where numberOfAttempts == 1: return "send 1 message"
                    case .sendMessage: return "send \(numberOfAttempts) messages"
                    case .sendAttachment(let fileSize) where numberOfAttempts == 1:
                        return "send 1 attachment (\(Format.fileSize(fileSize)))"
                        
                    case .sendAttachment(let fileSize):
                        return "send \(numberOfAttempts) attachments (\(Format.fileSize(fileSize)) each)"
                    
                    case .sendMessageWithAttachment(let fileSize) where numberOfAttempts == 1:
                        return "send 1 message with \(Format.fileSize(fileSize)) attachment"
                        
                    case .sendMessageWithAttachment(let fileSize):
                        return "send \(numberOfAttempts) messages (each with \(Format.fileSize(fileSize)) attachment)"
                        
                    case .downloadAttachment(let fileSize) where numberOfAttempts == 1:
                        return "download 1 attachment"
                        
                    case .downloadAttachment(let fileSize):
                        return "download \(numberOfAttempts) attachments (\(Format.fileSize(fileSize)) each)"
                }
            }()
            
            return [
                mode.name,
                (numPaths == 1 ? "1 path" : "\(numPaths) paths"),
                attemptString,
                behaviour.description(with: numberOfAttempts)
            ].joined(separator: ", ")
        }
    }
    
    struct TestResult {
        let attempt: Int
        let success: Bool
        let error: Error?
        let errorString: String?
        
        init(attempt: Int, result: Result<Void, Error>) {
            self.attempt = attempt
            
            switch result {
                case .success:
                    self.success = true
                    self.error = nil
                    self.errorString = nil
                    
                case .failure(let error):
                    self.success = false
                    self.error = error
                    self.errorString = "\(error)"
            }
        }
    }
}

extension ResilienceTest.Config {
    enum DirectVariant {
        case sendMessage
        case sendAttachment(fileSize: UInt)
        case downloadAttachment(fileSize: UInt)
        
        var variant: ResilienceTest.Variant {
            switch self {
                case .sendMessage: return .sendMessage
                case .sendAttachment(let fileSize): return .sendAttachment(fileSize: fileSize)
                case .downloadAttachment(let fileSize): return .downloadAttachment(fileSize: fileSize)
            }
        }
    }
    
    static func directVariations(
        variant: ResilienceTest.Config.DirectVariant,
        attempts: Int,
        networkModes: [NetworkMode],
        behaviours: [ResilienceTest.SendBehaviour],
        numPaths: [Int]
    ) -> [ResilienceTest.Config] {
        return variations(
            variant: variant.variant,
            attempts: attempts,
            networkModes: networkModes,
            behaviours: behaviours,
            numPaths: numPaths
        )
    }
    
    static func jobRunnerVariations(
        variant: ResilienceTest.Variant,
        attempts: Int,
        behaviours: [ResilienceTest.SendBehaviour],
        numPaths: [Int]
    ) -> [ResilienceTest.Config] {
        return variations(
            variant: variant,
            attempts: attempts,
            networkModes: [.shared],
            behaviours: behaviours,
            numPaths: numPaths
        )
    }
    
    private static func variations(
        variant: ResilienceTest.Variant,
        attempts: Int,
        networkModes: [NetworkMode],
        behaviours: [ResilienceTest.SendBehaviour],
        numPaths: [Int]
    ) -> [ResilienceTest.Config] {
        return networkModes.flatMap { mode in
            numPaths.flatMap { numPaths in
                behaviours.map { behaviour in
                    ResilienceTest.Config(
                        mode: mode,
                        attempts: attempts,
                        variant: variant,
                        behaviour: behaviour,
                        numPaths: numPaths
                    )
                }
            }
        }
    }
}
