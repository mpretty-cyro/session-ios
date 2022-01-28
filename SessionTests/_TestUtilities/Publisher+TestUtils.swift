import Combine
import CombineExpectations

extension Publisher {
    public var all: [Output] {
        return ((try? self.record().availableElements.get()) ?? [])
    }
    
    public var first: Output? {
        return all.first
    }
    
    public var newest: Output? {
        return all.last
    }
}
