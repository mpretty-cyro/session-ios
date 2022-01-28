// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Nimble

// MARK: - Element Comparison

public func valueAt<T>(_ index: Int, _ predicate: Predicate<T.Element>) -> Predicate<T> where T: Collection, T.Index == Int {
    return Predicate.define { actualExpression in
        if let actualValue = try actualExpression.evaluate() {
            guard actualValue.count > index else {
                return PredicateResult(
                    status: .fail,
                    message: ExpectationMessage
                        .expectedCustomValueTo(
                            "collection \(prettyCollectionType(actualValue)) with value at index \(index) \(stringify(index))",
                            actual: ""
                        )
                        .appended(details: "but had count: \(stringify(actualValue.count))")
                )
            }
            
            let expression: Expression<T.Element> = Expression(
                expression: { actualValue[index] },
                location: actualExpression.location
            )
            return try predicate.satisfies(expression)
        }
        else {
            return PredicateResult(status: .fail, message: .fail(""))
        }
    }
}

public func valueFor<T, V>(_ keyPath: KeyPath<T.Element, V>, at index: Int, to predicate: Predicate<V>) -> Predicate<T> where T: Collection, T.Index == Int {
    return Predicate.define { actualExpression in
        if let actualValue = try actualExpression.evaluate() {
            guard actualValue.count > index else {
                return PredicateResult(
                    status: .fail,
                    message: ExpectationMessage
                        .expectedCustomValueTo(
                            "keyPath value of \(stringify(T.Element.self)) at index \(index) but had count: \(stringify(actualValue.count))",
                            actual: ""
                        )
                )
            }
            
            let expression: Expression<V> = Expression(
                expression: { actualValue[index][keyPath: keyPath] },
                location: actualExpression.location
            )
            
            do {
                let result = try predicate.satisfies(expression)
                
                switch result.status {
                    case .matches:
                        return PredicateResult(
                            status: result.status,
                            message: ExpectationMessage
                                .expectedCustomValueTo(
                                    "keyPath value of \(stringify(T.Element.self)) at index \(index) should \(result.message.expectedMessage)",
                                    actual: ""
                                )
                        )
                    
                    default:
                        return PredicateResult(
                            status: .fail,
                            message: ExpectationMessage
                                .expectedCustomValueTo(
                                    "keyPath value of \(prettyCollectionType(actualValue[index])) at index \(index)",
                                    actual: ""
                                )
                                .appended(details: "to \(result.message)")
                        )
                }
            }
            catch _ {
                return PredicateResult(status: .fail, message: .fail(""))
            }
        }
        else {
            return PredicateResult(status: .fail, message: .fail(""))
        }
    }
}

// MARK: - Count Comparisons

public func haveCountGreaterThan<T: Collection>(_ expectedValue: Int) -> Predicate<T> {
    return Predicate.define { actualExpression in
        if let actualValue = try actualExpression.evaluate() {
            let message = ExpectationMessage
                .expectedCustomValueTo(
                    "have \(prettyCollectionType(actualValue)) with count greater than \(stringify(expectedValue))",
                    actual: "\(actualValue.count)"
                )
                .appended(details: "Actual Value: \(stringify(actualValue))")

            let result = (expectedValue < actualValue.count)
            return PredicateResult(bool: result, message: message)
        }
        else {
            return PredicateResult(status: .fail, message: .fail(""))
        }
    }
}

public func haveCountLessThan<T: Collection>(_ expectedValue: Int) -> Predicate<T> {
    return Predicate.define { actualExpression in
        if let actualValue = try actualExpression.evaluate() {
            let message = ExpectationMessage
                .expectedCustomValueTo(
                    "have \(prettyCollectionType(actualValue)) with count less than \(stringify(expectedValue))",
                    actual: "\(actualValue.count)"
                )
                .appended(details: "Actual Value: \(stringify(actualValue))")

            let result = (expectedValue > actualValue.count)
            return PredicateResult(bool: result, message: message)
        }
        else {
            return PredicateResult(status: .fail, message: .fail(""))
        }
    }
}
