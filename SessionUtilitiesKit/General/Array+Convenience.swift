
public extension Array {

    func appending(contentsOf other: [Element]) -> [Element] {
        var updatedArray = self
        updatedArray.append(contentsOf: other)
        
        return updatedArray
    }
}
