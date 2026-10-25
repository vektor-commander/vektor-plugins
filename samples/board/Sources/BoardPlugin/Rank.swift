import Foundation

// Order as a fractional index: every column, task, tag and board has a `rank`, a string of base-36 digits read as the
// fraction 0.<digits>. Records sort by rank (then by id, so two Macs that inserted at the same place agree on the order). A new
// rank between two others always exists, so a move changes only the record that moved: concurrent moves of different tasks
// merge without a conflict, which an array of ids could not do.
//
// There is no limit: a rank grows by about one character for every five insertions at the very same place, and a board of
// thousands of tasks keeps ranks of a few characters.

public enum Rank {
    static let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    private static let value: [Character: Int] = Dictionary(uniqueKeysWithValues: digits.enumerated().map { ($1, $0) })

    /// A rank strictly between `low` and `high` (nil: the start, the end). `low` must sort before `high`; equal or crossed
    /// bounds give a rank after `low`.
    public static func between(_ low: String?, _ high: String?) -> String {
        let a = (low ?? "").filter { value[$0] != nil }
        let b = high.map { $0.filter { value[$0] != nil } }
        if let b, !b.isEmpty, a < b { return midpoint(Array(a), Array(b)) }
        return midpoint(Array(a), nil)
    }

    /// `count` ranks in increasing order after `low` and before `high`, evenly spread.
    public static func spread(_ count: Int, after low: String? = nil, before high: String? = nil) -> [String] {
        var result: [String] = []
        var previous = low
        for _ in 0..<count {
            let next = between(previous, high)
            result.append(next)
            previous = next
        }
        return result
    }

    // The midpoint of two digit strings read as fractions (the "fractional indexing" method): strip the common prefix, then
    // take a digit halfway between the first differing digits, or recurse one digit further down when they are neighbours.
    // Results never end in "0", so there is always room before them.
    private static func midpoint(_ a: [Character], _ b: [Character]?) -> String {
        if let b {
            var n = 0
            while n < b.count, (n < a.count ? a[n] : "0") == b[n] { n += 1 }
            if n > 0 {
                return String(b[0..<n]) + midpoint(Array(a.dropFirst(min(n, a.count))), Array(b[n...]))
            }
        }
        let digitA = a.first.flatMap { value[$0] } ?? 0
        let digitB = b.flatMap { $0.first.flatMap { value[$0] } } ?? digits.count
        if digitB - digitA > 1 {
            return String(digits[(digitA + digitB + 1) / 2])
        }
        if let b, b.count > 1 { return String(b[0]) }
        return String(digits[digitA]) + midpoint(Array(a.dropFirst()), nil)
    }
}
