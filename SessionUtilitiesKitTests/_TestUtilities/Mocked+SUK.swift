// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB

@testable import SessionUtilitiesKit

extension SessionId: Mocked {
    public static let mock: SessionId = SessionId(.standard, publicKey: [
        1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8,
        1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8
    ])
}

extension Dependencies {
    static var any: Dependencies {
        TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
    }
}

extension ObservingDatabase: Mocked {
    public static var mock: Self {
        var result: Database!
        try! DatabaseQueue().read { result = $0 }
        return ObservingDatabase.create(result!, id: .mock, using: .any) as! Self
    }
}

extension ObservableKey: Mocked {
    public static var mock: ObservableKey = "mockObservableKey"
}

extension ObservedEvent: Mocked {
    public static var mock: ObservedEvent = ObservedEvent(key: "mock", value: nil)
}

extension KeyPair: Mocked {
    public static var mock: KeyPair = KeyPair(
        publicKey: Data(hex: TestConstants.publicKey).bytes,
        secretKey: Data(hex: TestConstants.edSecretKey).bytes
    )
}

extension Job: Mocked {
    public static var mock: Job = Job(variant: .mock)
}

extension Job.Variant: Mocked {
    public static var mock: Job.Variant = .messageSend
}

extension JobRunner.JobResult: Mocked {
    public static var mock: JobRunner.JobResult = .succeeded
}

extension JobRunner.JobState: Mocked {
    public static var mock: JobRunner.JobState = .pending
}

extension Log.Category: Mocked {
    public static var mock: Log.Category = .create("mock", defaultLevel: .debug)
}

extension Setting.BoolKey: Mocked {
    public static var mock: Setting.BoolKey = "mockBool"
}

extension Setting.EnumKey: Mocked {
    public static var mock: Setting.EnumKey = "mockEnum"
}

// MARK: - Encodable Convenience

extension Mocked where Self: Encodable {
    func encoded(using dependencies: Dependencies) -> Data {
        try! JSONEncoder(using: dependencies).with(outputFormatting: .sortedKeys).encode(self)
    }
}

extension MockedGeneric where Self: Encodable {
    func encoded(using dependencies: Dependencies) -> Data {
        try! JSONEncoder(using: dependencies).with(outputFormatting: .sortedKeys).encode(self)
    }
}

extension Array where Element: Encodable {
    func encoded(using dependencies: Dependencies) -> Data {
        try! JSONEncoder(using: dependencies).with(outputFormatting: .sortedKeys).encode(self)
    }
}
