
public extension Dictionary {
    
    func setting(_ key: Key, value: Value) -> [Key: Value] {
        var updatedDict = self
        updatedDict[key] = value
        
        return updatedDict
    }

    func setting(contentsOf array: [Element]) -> [Key: Value] {
        var updatedDict = self
        array.forEach { key, value in
            updatedDict[key] = value
        }
        
        return updatedDict
    }
}
