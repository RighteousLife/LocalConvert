import Foundation

struct PageRangeParser {
    static func parse(_ input: String, maxPages: Int) -> [Int] {
        var pages = Set<Int>()
        var order = [Int]() // To preserve insertion order but remove duplicates
        
        let components = input.split(separator: ",")
        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if let single = Int(trimmed) {
                if single >= 1 && single <= maxPages {
                    if !pages.contains(single) {
                        pages.insert(single)
                        order.append(single)
                    }
                }
            } else if trimmed.contains("-") {
                let parts = trimmed.split(separator: "-")
                if parts.count == 2, let start = Int(parts[0].trimmingCharacters(in: .whitespaces)), let end = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    let rangeStart = max(1, min(start, end))
                    let rangeEnd = min(maxPages, max(start, end))
                    
                    if rangeStart <= rangeEnd {
                        for p in rangeStart...rangeEnd {
                            if !pages.contains(p) {
                                pages.insert(p)
                                order.append(p)
                            }
                        }
                    }
                }
            }
        }
        
        return order
    }
}
