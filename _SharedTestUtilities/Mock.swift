// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

// MARK: - MockError

public enum MockError: Error {
    case mockedData
}

// MARK: - Mock<T>

public class Mock<T>: DependenciesSettable, InitialSetupable {
    private var _dependencies: Dependencies!
    private let functionHandler: MockFunctionHandler
    internal let functionConsumer: FunctionConsumer
    
    public var dependencies: Dependencies { _dependencies }
    private var initialSetup: ((Mock<T>) -> ())?
    
    // MARK: - Initialization
    
    internal required init(
        functionHandler: MockFunctionHandler? = nil,
        initialSetup: ((Mock<T>) -> ())? = nil
    ) {
        self.functionConsumer = FunctionConsumer()
        self.functionHandler = (functionHandler ?? self.functionConsumer)
        self.initialSetup = initialSetup
    }
    
    // MARK: - DependenciesSettable
    
    public func setDependencies(_ dependencies: Dependencies?) {
        self._dependencies = dependencies
    }
    
    // MARK: - InitialSetupable
    
    func performInitialSetup() {
        self.initialSetup?(self)
        self.initialSetup = nil
    }
    
    // MARK: - MockFunctionHandler
    
    @discardableResult internal func mock<Output>(funcName: String = #function, generics: [Any.Type] = [], args: [Any?] = [], untrackedArgs: [Any?] = []) -> Output {
        return functionHandler.mock(
            funcName,
            parameterCount: args.count,
            parameterSummary: summary(for: args),
            allParameterSummaryCombinations: summaries(for: args),
            generics: generics,
            args: args,
            untrackedArgs: untrackedArgs
        )
    }
    
    internal func mockNoReturn(funcName: String = #function, generics: [Any.Type] = [], args: [Any?] = [], untrackedArgs: [Any?] = []) {
        functionHandler.mockNoReturn(
            funcName,
            parameterCount: args.count,
            parameterSummary: summary(for: args),
            allParameterSummaryCombinations: summaries(for: args),
            generics: generics,
            args: args,
            untrackedArgs: untrackedArgs
        )
    }
    
    @discardableResult internal func mockThrowing<Output>(funcName: String = #function, generics: [Any.Type] = [], args: [Any?] = [], untrackedArgs: [Any?] = []) throws -> Output {
        return try functionHandler.mockThrowing(
            funcName,
            parameterCount: args.count,
            parameterSummary: summary(for: args),
            allParameterSummaryCombinations: summaries(for: args),
            generics: generics,
            args: args,
            untrackedArgs: untrackedArgs
        )
    }
    
    internal func mockThrowingNoReturn(funcName: String = #function, generics: [Any.Type] = [], args: [Any?] = [], untrackedArgs: [Any?] = []) throws {
        try functionHandler.mockThrowingNoReturn(
            funcName,
            parameterCount: args.count,
            parameterSummary: summary(for: args),
            allParameterSummaryCombinations: summaries(for: args),
            generics: generics,
            args: args,
            untrackedArgs: untrackedArgs
        )
    }
    
    internal func getExpectation(funcName: String = #function, generics: [Any.Type] = [], args: [Any?] = [], untrackedArgs: [Any?] = []) -> MockFunction {
        return functionConsumer.getExpectation(
            funcName,
            parameterCount: args.count,
            parameterSummary: summary(for: args),
            allParameterSummaryCombinations: summaries(for: args),
            generics: generics,
            args: args,
            untrackedArgs: untrackedArgs
        )
    }
    
    // MARK: - Functions
    
    internal func reset() {
        functionConsumer.reset()
    }
    
    internal func removeMocksFor<R>(_ callBlock: @escaping (inout T) throws -> R) async {
        let builder: MockFunctionBuilder<T, R> = MockFunctionBuilder(
            consumer: functionConsumer,
            callBlock: callBlock,
            mockInit: type(of: self).init
        )
        
        let oldTrackCalls: Bool = functionConsumer.trackCalls
        functionConsumer.trackCalls = false
        
        guard let builtFunction: MockFunction = try? await builder.build() else {
            functionConsumer.trackCalls = oldTrackCalls
            return
        }
        
        functionConsumer.removeStubs(for: builtFunction)
        functionConsumer.trackCalls = oldTrackCalls
    }
    
    internal func when<R>(_ callBlock: @escaping (inout T) throws -> R) -> MockFunctionBuilder<T, R> {
        let builder: MockFunctionBuilder<T, R> = MockFunctionBuilder(
            consumer: functionConsumer,
            callBlock: callBlock,
            mockInit: type(of: self).init
        )
        
        return builder
    }
    
    internal func when<R>(_ callBlock: @escaping (inout T) async throws -> R) -> MockFunctionBuilder<T, R> {
        let builder: MockFunctionBuilder<T, R> = MockFunctionBuilder(
            consumer: functionConsumer,
            callBlock: callBlock,
            mockInit: type(of: self).init
        )
        
        return builder
    }
    
    internal func allCalls<R>(_ functionBlock: @escaping (inout T) async throws -> R) async throws -> [CallDetails]? {
        let maybeTargetFunction: MockFunction? = try? await MockFunctionBuilder.mockFunctionWith(self, functionBlock)
        let key: FunctionConsumer.Key = FunctionConsumer.Key(
            name: (maybeTargetFunction?.name ?? ""),
            generics: (maybeTargetFunction?.generics ?? []),
            paramCount: (maybeTargetFunction?.parameterCount ?? 0)
        )
        
        return functionConsumer.calls[key]
    }
    
    // MARK: - Convenience
    
    private func summaries(for argument: Any) -> [ParameterCombination] {
        switch argument {
            case let array as [Any]:
                return array.allCombinations()
                    .map { ParameterCombination(count: $0.count, summary: summary(for: $0)) }
                
            default: return [ParameterCombination(count: 1, summary: summary(for: argument))]
        }
    }
    
    private func summary(for argument: Any) -> String {
        if
            let customDescribable: CustomArgSummaryDescribable = argument as? CustomArgSummaryDescribable,
            let customArgSummaryDescribable: String = customDescribable.customArgSummaryDescribable
        { return customArgSummaryDescribable }
        
        switch argument {
            case let string as String: return string
            case let array as [Any]: return "[\(array.map { summary(for: $0) }.joined(separator: ", "))]"
                
            case let dict as [String: Any]:
                if dict.isEmpty { return "[:]" }
                
                let sortedValues: [String] = dict
                    .map { key, value in "\(summary(for: key)):\(summary(for: value))" }
                    .sorted()
                return "[\(sortedValues.joined(separator: ", "))]"
                
            case let data as Data: return "Data(base64Encoded: \(data.base64EncodedString()))"
                
            default:
                // Default to the `debugDescription` if available but sort any dictionary content by keys
                return sortDictionariesInReflectedString(String(reflecting: argument))
        }
    }
    
    private func sortDictionariesInReflectedString(_ input: String) -> String {
        // Regular expression to match the headers dictionary
        let pattern = "\\[(.+?)\\]"
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        
        var result = ""
        var lastRange = input.startIndex..<input.startIndex
        
        regex.enumerateMatches(in: input, options: [], range: NSRange(input.startIndex..<input.endIndex, in: input)) { match, _, _ in
            guard let match = match, let range = Range(match.range, in: input) else { return }
            
            // Append the text before this match
            result += input[lastRange.upperBound..<range.lowerBound]
            
            // Extract the dictionary string
            if let innerRange = Range(match.range(at: 1), in: input) {
                let dictionaryString = String(input[innerRange])
                let sortedDictionaryString = sortDictionaryString(dictionaryString)
                result += (sortedDictionaryString.isEmpty ? "[:]" : "[\(sortedDictionaryString)]")
            } else {
                // If we can't extract the inner part, just use the original matched text
                result += input[range]
            }
            
            lastRange = range
        }

        // Append any remaining text after the last match
        result += input[lastRange.upperBound..<input.endIndex]
        
        return result
    }
    
    private func sortDictionaryString(_ dictionaryString: String) -> String {
        var pairs: [(String, String)] = []
        var currentKey = ""
        var currentValue = ""
        var inQuotes = false
        var parsingKey = true
        var nestedLevel = 0
        
        for char in dictionaryString {
            switch char {
                case "\"":
                    inQuotes.toggle()
                    if nestedLevel > 0 {
                        currentKey.append(char)
                        continue
                    }
                
                case ":":
                    if !inQuotes && nestedLevel == 0 {
                        parsingKey = false
                        continue
                    }
                
                case ",":
                    if !inQuotes && nestedLevel == 0 {
                        pairs.append((currentKey.trimmingCharacters(in: .whitespaces), currentValue.trimmingCharacters(in: .whitespaces)))
                        currentKey = ""
                        currentValue = ""
                        parsingKey = true
                        continue
                    }
                
                case "[", "{": nestedLevel += (parsingKey ? 0 : 1)
                case "]", "}": nestedLevel -= (parsingKey ? 0 : 1)
                default: break
            }
            
            switch parsingKey {
                case true: currentKey.append(char)
                case false: currentValue.append(char)
            }
        }
        
        // Add the last pair if exists
        if !currentKey.isEmpty || !currentValue.isEmpty {
            pairs.append((currentKey.trimmingCharacters(in: .whitespaces), currentValue.trimmingCharacters(in: .whitespaces)))
        }
        
        // Sort pairs by key
        let sortedPairs = pairs.sorted { $0.0 < $1.0 }
        
        // Join sorted pairs back into a string
        return sortedPairs.map { "\($0): \($1)" }.joined(separator: ", ")
    }
}

// MARK: - MockFunctionHandler

protocol MockFunctionHandler {
    func mock<Output>(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?]
    ) -> Output
    
    func mockNoReturn(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?]
    )
    
    func mockThrowing<Output>(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?]
    ) throws -> Output
    
    func mockThrowingNoReturn(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?]
    ) throws
}

// MARK: - CallDetails

internal struct CallDetails: Equatable, Hashable {
    let parameterSummary: String
    let allParameterSummaryCombinations: [ParameterCombination]
    
    internal init(parameterSummary: String, allParameterSummaryCombinations: [ParameterCombination]) {
        self.parameterSummary = parameterSummary
        self.allParameterSummaryCombinations = allParameterSummaryCombinations
    }
}

// MARK: - ParameterCombination

internal struct ParameterCombination: Equatable, Hashable {
    let count: Int
    let summary: String
}

// MARK: - MockFunction

internal class MockFunction {
    var name: String
    var parameterCount: Int
    var parameterSummary: String
    var allParameterSummaryCombinations: [ParameterCombination]
    var generics: [Any.Type]
    var args: [Any?]
    var untrackedArgs: [Any?]
    var actions: [([Any?], [Any?]) -> Void]
    var asyncActions: [([Any?], [Any?]) async -> Void]
    var returnError: (any Error)?
    var closureCallArgs: [Any?]
    var returnValue: Any?
    var dynamicReturnValueRetriever: (([Any?], [Any?]) -> Any?)?
    
    init(
        name: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?],
        actions: [([Any?], [Any?]) -> Void],
        asyncActions: [([Any?], [Any?]) async -> Void],
        returnError: (any Error)?,
        closureCallArgs: [Any?],
        returnValue: Any?,
        dynamicReturnValueRetriever: (([Any?], [Any?]) -> Any?)?
    ) {
        self.name = name
        self.parameterCount = parameterCount
        self.parameterSummary = parameterSummary
        self.allParameterSummaryCombinations = allParameterSummaryCombinations
        self.generics = generics
        self.args = args
        self.untrackedArgs = untrackedArgs
        self.asyncActions = asyncActions
        self.actions = actions
        self.returnError = returnError
        self.closureCallArgs = closureCallArgs
        self.returnValue = returnValue
        self.dynamicReturnValueRetriever = dynamicReturnValueRetriever
    }
}

// MARK: - MockFunctionBuilder

internal class MockFunctionBuilder<T, R>: MockFunctionHandler {
    private let consumer: FunctionConsumer
    private let callBlock: (inout T) async throws -> R
    private let mockInit: (MockFunctionHandler?, ((Mock<T>) -> ())?) -> Mock<T>
    
    private var capturedFunctionName: String?
    private var capturedGenerics: [Any.Type] = []
    private var capturedArguments: [Any?] = []
    
    private var parameterCount: Int?
    private var parameterSummary: String?
    private var allParameterSummaryCombinations: [ParameterCombination]?
    
    private var untrackedArgs: [Any?]?
    private var actions: [([Any?], [Any?]) -> Void] = []
    private var asyncActions: [([Any?], [Any?]) async -> Void] = []
    private var closureCallArgs: [Any?] = []
    private var returnValue: R?
    private var dynamicReturnValueRetriever: (([Any?], [Any?]) -> R?)?
    private var returnError: Error?
    
    /// This value should only ever be set via the `NimbleExtensions` `generateCallInfo` function, in order to use a closure to
    /// generate the return value the `dynamicReturnValueRetriever` value should be used instead
    internal var returnValueGenerator: ((String, [Any.Type], Int, String, [ParameterCombination]) -> R?)?
    
    // MARK: - Initialization
    
    init(
        consumer: FunctionConsumer,
        callBlock: @escaping (inout T) async throws -> R,
        mockInit: @escaping (MockFunctionHandler?, ((Mock<T>) -> ())?) -> Mock<T>
    ) {
        self.consumer = consumer
        self.callBlock = callBlock
        self.mockInit = mockInit
    }
    
    static func mockFunctionWith<M>(
        _ validInstance: M,
        _ functionBlock: @escaping (inout T) async throws -> R
    ) async throws -> MockFunction? where M: Mock<T> {
        let builder: MockFunctionBuilder<T, R> = MockFunctionBuilder(
            consumer: validInstance.functionConsumer,
            callBlock: functionBlock,
            mockInit: type(of: validInstance).init
        )
        builder.returnValueGenerator = { name, generics, parameterCount, parameterSummary, allParameterSummaryCombinations in
            validInstance.functionConsumer
                .firstFunction(
                    for: FunctionConsumer.Key(name: name, generics: generics, paramCount: parameterCount),
                    matchingParameterSummaryIfPossible: parameterSummary,
                    allParameterSummaryCombinations: allParameterSummaryCombinations
                )?
                .returnValue as? R
        }
        
        return try await builder.build()
    }
    
    // MARK: - Behaviours
    
    /// Closure parameter is an array of arguments called by the function
    @discardableResult func then(_ action: @escaping ([Any?]) -> Void) -> Self {
        actions.append({ args, _ in action(args) })
        return self
    }
    
    /// Closure parameter is an array of arguments called by the function
    @discardableResult func then(_ action: @escaping ([Any?]) async -> Void) -> Self {
        asyncActions.append({ args, _ in await action(args) })
        return self
    }
    
    /// Closure parameters are an array of arguments, followed by an array of "untracked" arguments called by the function
    @discardableResult func then(_ action: @escaping ([Any?], [Any?]) -> Void) -> Self {
        actions.append(action)
        return self
    }
    
    /// Closure parameters are an array of arguments, followed by an array of "untracked" arguments called by the function
    @discardableResult func then(_ action: @escaping ([Any?], [Any?]) async -> Void) -> Self {
        asyncActions.append(action)
        return self
    }
    
    func withClosureCallArgs(_ values: [Any?]) {
        closureCallArgs = values
    }
    
    func thenReturn(_ value: R?) async throws {
        (value as? (any InitialSetupable))?.performInitialSetup()
        returnValue = value
        try await finalize()
    }
    
    func thenReturn(_ closure: @escaping (([Any?], [Any?]) -> R?)) async throws {
        dynamicReturnValueRetriever = { args, untrackedArgs in
            let result = closure(args, untrackedArgs)
            (result as? (any InitialSetupable))?.performInitialSetup()
            return result
        }
        try await finalize()
    }
    
    func thenThrow(_ error: Error) async throws {
        returnError = error
        try await finalize()
    }
    
    // MARK: - MockFunctionHandler
    
    func mock<Output>(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?]
    ) -> Output {
        self.capturedFunctionName = functionName
        self.parameterCount = parameterCount
        self.parameterSummary = parameterSummary
        self.allParameterSummaryCombinations = allParameterSummaryCombinations
        self.capturedGenerics = generics
        self.capturedArguments = args
        self.untrackedArgs = untrackedArgs
        
        let result: Any? = (
            returnValue ??
            dynamicReturnValueRetriever?(args, untrackedArgs) ??
            returnValueGenerator?(functionName, generics, parameterCount, parameterSummary, allParameterSummaryCombinations)
        )
        
        switch result {
            case .some(let value as Output): return value
            case .some(let value as (any Numeric)):
                guard
                    let numericType: (any Numeric.Type) = Output.self as? any Numeric.Type,
                    let convertedValue: Output = convertNumeric(value, to: numericType) as? Output
                else { return (result as! Output) }
                
                return convertedValue
                
            default: return (result as! Output)
        }
    }
    
    func mockNoReturn(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?]
    ) {
        self.capturedFunctionName = functionName
        self.parameterCount = parameterCount
        self.parameterSummary = parameterSummary
        self.allParameterSummaryCombinations = allParameterSummaryCombinations
        self.capturedGenerics = generics
        self.capturedArguments = args
        self.untrackedArgs = untrackedArgs
    }
    
    func mockThrowing<Output>(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?]
    ) throws -> Output {
        self.capturedFunctionName = functionName
        self.parameterCount = parameterCount
        self.parameterSummary = parameterSummary
        self.allParameterSummaryCombinations = allParameterSummaryCombinations
        self.capturedGenerics = generics
        self.capturedArguments = args
        self.untrackedArgs = untrackedArgs
        
        if let returnError: Error = returnError { throw returnError }
        
        let result: Any? = (
            returnValue ??
            dynamicReturnValueRetriever?(args, untrackedArgs) ??
            returnValueGenerator?(functionName, generics, parameterCount, parameterSummary, allParameterSummaryCombinations)
        )
        
        switch result {
            case .some(let value as Output): return value
            case .some(let value as (any Numeric)):
                guard
                    let numericType: (any Numeric.Type) = Output.self as? any Numeric.Type,
                    let convertedValue: Output = convertNumeric(value, to: numericType) as? Output
                else { throw MockError.mockedData }
                
                return convertedValue
                
            default: return try Optional<Any>.none as? Output ?? { throw MockError.mockedData }()
        }
    }
    
    func mockThrowingNoReturn(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?]
    ) throws {
        self.capturedFunctionName = functionName
        self.parameterCount = parameterCount
        self.parameterSummary = parameterSummary
        self.allParameterSummaryCombinations = allParameterSummaryCombinations
        self.capturedGenerics = generics
        self.capturedArguments = args
        self.untrackedArgs = untrackedArgs
        
        if let returnError: Error = returnError { throw returnError }
    }
    
    // MARK: - Internal Functions
    
    private func finalize() async throws {
        let function = try await self.build()
        consumer.register(stub: function)
    }
    
    private func captureDetails() async {
        /// Only run capture once
        guard capturedFunctionName == nil else { return }
        
        var dummy: T = mockInit(self, nil) as! T
        _ = try? await callBlock(&dummy)
    }
}

extension MockFunctionBuilder {
    func build() async throws -> MockFunction {
        await captureDetails()
        
        guard
            let name: String = capturedFunctionName,
            let parameterCount: Int = parameterCount,
            let parameterSummary: String = parameterSummary,
            let allParameterSummaryCombinations: [ParameterCombination] = allParameterSummaryCombinations,
            let untrackedArgs: [Any?] = untrackedArgs
        else { preconditionFailure("Attempted to build the MockFunction before it was called") }
        
        return MockFunction(
            name: name,
            parameterCount: parameterCount,
            parameterSummary: parameterSummary,
            allParameterSummaryCombinations: allParameterSummaryCombinations,
            generics: capturedGenerics,
            args: capturedArguments,
            untrackedArgs: untrackedArgs,
            actions: actions,
            asyncActions: asyncActions,
            returnError: returnError,
            closureCallArgs: closureCallArgs,
            returnValue: returnValue,
            dynamicReturnValueRetriever: dynamicReturnValueRetriever.map { closure in
                { args, untrackedArgs in closure(args, untrackedArgs) }
            }
        )
    }
}

// MARK: - Combine Convenience

extension MockFunctionBuilder {
    func thenReturn<Element>(_ value: [Element]) where R == AnyPublisher<[Element], Never> {
        returnValue = Just(value)
            .setFailureType(to: Never.self)
            .eraseToAnyPublisher()
    }
    
    func thenReturn<Element>(_ value: [Element]) where R == AnyPublisher<[Element], Error> {
        returnValue = Just(value)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    func thenReturn<Element>(_ value: Set<Element>) where R == AnyPublisher<Set<Element>, Never> {
        returnValue = Just(value)
            .setFailureType(to: Never.self)
            .eraseToAnyPublisher()
    }
    
    func thenReturn<Element>(_ value: Set<Element>) where R == AnyPublisher<Set<Element>, Error> {
        returnValue = Just(value)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
}

// MARK: - InitialSetupable

protocol InitialSetupable {
    func performInitialSetup()
}

// MARK: - FunctionConsumer

internal class FunctionConsumer: MockFunctionHandler {
    internal struct Key: Equatable, Hashable {
        let name: String
        let paramCount: Int
        
        internal init(name: String, generics: [Any.Type], paramCount: Int) {
            let splitName: [String] = name.split(separator: "(").map { String($0) }
            let genericsString: String = "<\(generics.map { "\($0)" }.joined(separator: ", "))>"
            
            switch (generics.count, splitName.count) {
                case (1..., 1): self.name = "\(splitName[0])\(genericsString)"
                case (1..., 2): self.name = "\(splitName[0])\(genericsString)(\(splitName[1])"
                default: self.name = name
            }
            self.paramCount = paramCount
        }
    }
    
    var trackCalls: Bool = true
    @ThreadSafeObject var stubs: [Key: [MockFunction]] = [:]
    @ThreadSafeObject var calls: [Key: [CallDetails]] = [:]
    
    fileprivate func getExpectation(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?]
    ) -> MockFunction {
        let key: Key = Key(name: functionName, generics: generics, paramCount: parameterCount)
        let maybeResult: MockFunction? = firstFunction(
            for: key,
            matchingParameterSummaryIfPossible: parameterSummary,
            allParameterSummaryCombinations: allParameterSummaryCombinations
        )
        
        guard let result: MockFunction = maybeResult else {
            preconditionFailure("No expectations found for \(key.name)")
        }
        
        return result
    }
    
    private func getAndTrackExpectation(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?]
    ) -> MockFunction {
        let key: Key = Key(name: functionName, generics: generics, paramCount: parameterCount)
        let expectation: MockFunction = getExpectation(
            functionName,
            parameterCount: parameterCount,
            parameterSummary: parameterSummary,
            allParameterSummaryCombinations: allParameterSummaryCombinations,
            generics: generics,
            args: args,
            untrackedArgs: untrackedArgs
        )
        
        // Record the call so it can be validated later (assuming we are tracking calls)
        if trackCalls {
            _calls.performUpdate {
                $0.setting(key, ($0[key] ?? []).appending(
                    CallDetails(
                        parameterSummary: parameterSummary,
                        allParameterSummaryCombinations: allParameterSummaryCombinations
                    )
                ))
            }
        }
        
        for action in expectation.actions {
            action(args, untrackedArgs)
        }
        
        if !expectation.asyncActions.isEmpty {
            let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
            Task {
                for action in expectation.asyncActions {
                    await action(args, untrackedArgs)
                }
                
                semaphore.signal()
            }
            semaphore.wait()
        }
        
        return expectation
    }
    
    func mock<Output>(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?]
    ) -> Output {
        let expectation: MockFunction = getAndTrackExpectation(
            functionName,
            parameterCount: parameterCount,
            parameterSummary: parameterSummary,
            allParameterSummaryCombinations: allParameterSummaryCombinations,
            generics: generics,
            args: args,
            untrackedArgs: untrackedArgs
        )
        
        switch (expectation.returnValue, expectation.dynamicReturnValueRetriever) {
            case (.some(let value as Output), _): return value
            case (.some(let value as (any Numeric)), _):
                guard
                    let numericType: (any Numeric.Type) = Output.self as? any Numeric.Type,
                    let convertedValue: Output = convertNumeric(value, to: numericType) as? Output
                else { return (value as! Output) }
                
                return convertedValue
            
            case (_, .some(let closure)): return closure(args, untrackedArgs) as! Output
            default: return (expectation.returnValue as! Output)
        }
    }
    
    func mockNoReturn(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?]
    ) {
        _ = getAndTrackExpectation(
            functionName,
            parameterCount: parameterCount,
            parameterSummary: parameterSummary,
            allParameterSummaryCombinations: allParameterSummaryCombinations,
            generics: generics,
            args: args,
            untrackedArgs: untrackedArgs
        )
    }
    
    func mockThrowing<Output>(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?]
    ) throws -> Output {
        let expectation: MockFunction = getAndTrackExpectation(
            functionName,
            parameterCount: parameterCount,
            parameterSummary: parameterSummary,
            allParameterSummaryCombinations: allParameterSummaryCombinations,
            generics: generics,
            args: args,
            untrackedArgs: untrackedArgs
        )

        switch (expectation.returnError, expectation.returnValue, expectation.dynamicReturnValueRetriever) {
            case (.some(let error), _, _): throw error
            case (_, .some(let value as Output), _): return value
            case (_, .some(let value as (any Numeric)), _):
                guard
                    let numericType: (any Numeric.Type) = Output.self as? any Numeric.Type,
                    let convertedValue: Output = convertNumeric(value, to: numericType) as? Output
                else { throw MockError.mockedData }
                
                return convertedValue
                
            case (_, _, .some(let closure)): return closure(args, untrackedArgs) as! Output
            default: return try Optional<Any>.none as? Output ?? { throw MockError.mockedData }()
        }
    }
    
    func mockThrowingNoReturn(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        generics: [Any.Type],
        args: [Any?],
        untrackedArgs: [Any?]
    ) throws {
        let expectation: MockFunction = getAndTrackExpectation(
            functionName,
            parameterCount: parameterCount,
            parameterSummary: parameterSummary,
            allParameterSummaryCombinations: allParameterSummaryCombinations,
            generics: generics,
            args: args,
            untrackedArgs: untrackedArgs
        )

        switch expectation.returnError {
            case .some(let error): throw error
            default: return
        }
    }
    
    func firstFunction(
        for key: Key,
        matchingParameterSummaryIfPossible parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination]
    ) -> MockFunction? {
        guard let possibleExpectations: [MockFunction] = _stubs.performMap({ $0[key] }) else { return nil }
        
        guard let expectation: MockFunction = possibleExpectations.first(where: { $0.parameterSummary == parameterSummary }) else {
            // We didn't find an exact match so try to find the match with the most matching parameters,
            // do this by sorting based on the largest param count and checking if there is a match
            let maybeExpectation: MockFunction? = allParameterSummaryCombinations
                .sorted(by: { lhs, rhs in lhs.count > rhs.count })
                .compactMap { combination in
                    possibleExpectations.first(where: { $0.parameterSummary == combination.summary })
                }
                .first
            
            if let expectation: MockFunction = maybeExpectation {
                return expectation
            }
            
            // A `nil` response might be value but in a lot of places we will need to force-cast
            // so try to find a non-nil response first
            return (
                possibleExpectations.first(where: { $0.returnValue != nil }) ??
                possibleExpectations.first(where: { $0.dynamicReturnValueRetriever != nil }) ??
                possibleExpectations.first
            )
        }
        
        return expectation
    }
    
    fileprivate func register(stub: MockFunction) {
        let key: Key = Key(
            name: stub.name,
            generics: stub.generics,
            paramCount: stub.parameterCount
        )
        
        _stubs.performUpdate { $0.setting(key, ($0[key] ?? []).appending(stub)) }
    }
    
    fileprivate func removeStubs(for function: MockFunction) {
        let key: Key = Key(
            name: function.name,
            generics: function.generics,
            paramCount: function.parameterCount
        )
        
        _stubs.performUpdate { $0.removingValue(forKey: key) }
    }
    
    fileprivate func removeStubs(_ build: @escaping () throws -> MockFunction) {
        let oldTrackCalls: Bool = trackCalls
        trackCalls = false
        
        guard let builtFunction: MockFunction = try? build() else {
            trackCalls = oldTrackCalls
            return
        }
        
        removeStubs(for: builtFunction)
        trackCalls = oldTrackCalls
    }
    
    fileprivate func reset() {
        trackCalls = true
        clearCalls()
        
        _stubs.performUpdate { _ in [:] }
    }
    
    fileprivate func clearCalls() {
        _calls.set(to: [:])
    }
}

// MARK: - Conversion Convenience

private extension MockFunctionHandler {
    func convertNumeric(_ value: Any, to type: any Numeric.Type) -> (any Numeric)? {
        switch (value, type) {
            case (let x as any BinaryInteger, is Int64.Type): return Int64(x)
            case (let x as any BinaryInteger, is Int32.Type): return Int32(x)
            case (let x as any BinaryInteger, is Int16.Type): return Int16(x)
            case (let x as any BinaryInteger, is Int8.Type): return Int8(x)
            case (let x as any BinaryInteger, is Int.Type): return Int(x)
            case (let x as any BinaryInteger, is UInt64.Type): return UInt64(x)
            case (let x as any BinaryInteger, is UInt32.Type): return UInt32(x)
            case (let x as any BinaryInteger, is UInt16.Type): return UInt16(x)
            case (let x as any BinaryInteger, is UInt8.Type): return UInt8(x)
            case (let x as any BinaryInteger, is UInt.Type): return UInt(x)
            case (let x as any BinaryInteger, is Float.Type): return Float(x)
            case (let x as any BinaryInteger, is Double.Type): return Double(x)
            case (let x as any BinaryInteger, is TimeInterval.Type): return TimeInterval(x)
                
            case (let x as any BinaryFloatingPoint, is Int64.Type): return Int64(x)
            case (let x as any BinaryFloatingPoint, is Int32.Type): return Int32(x)
            case (let x as any BinaryFloatingPoint, is Int16.Type): return Int16(x)
            case (let x as any BinaryFloatingPoint, is Int8.Type): return Int8(x)
            case (let x as any BinaryFloatingPoint, is Int.Type): return Int(x)
            case (let x as any BinaryFloatingPoint, is UInt64.Type): return UInt64(x)
            case (let x as any BinaryFloatingPoint, is UInt32.Type): return UInt32(x)
            case (let x as any BinaryFloatingPoint, is UInt16.Type): return UInt16(x)
            case (let x as any BinaryFloatingPoint, is UInt8.Type): return UInt8(x)
            case (let x as any BinaryFloatingPoint, is UInt.Type): return UInt(x)
            case (let x as any BinaryFloatingPoint, is Float.Type): return Float(x)
            case (let x as any BinaryFloatingPoint, is Double.Type): return Double(x)
            case (let x as any BinaryFloatingPoint, is TimeInterval.Type): return TimeInterval(x)
            
            default: return nil
        }
    }
}

// MARK: - CustomArgSummaryDescribable

protocol CustomArgSummaryDescribable {
    var customArgSummaryDescribable: String? { get }
}
