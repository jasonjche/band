import Foundation

// SleepStageTrees.swift — the learned stage model's trees, read from plain text and evaluated here.
//
// Ported from denismanulov/reNOOP (PolyForm Noncommercial 1.0.0, same licence as this tree).
// reNOOP trained two Create ML boosted-tree classifiers and exported them as text
// (`Tools/SleepML/export_trees.py`) so a platform without Core ML can evaluate the same sums in the
// same order. This package ships those files under `SleepModel/` and evaluates them here, which is
// what `swift test` and `AnalyticsEngine` both run. The committed oracle
// (`Fixtures/sleep_stage_oracle.json`) is one invented night through every step.
//
// The arithmetic is spelled out because the two platforms must do the same sums in the same order:
// each class's sum starts at its base value and takes the leaves in the file's tree order; a branch
// goes to its first child when the row's value is LESS THAN the threshold, compared as doubles; the
// answer is exp(sum - largest sum) over the total of those four, added in class order.

/// One model's trees: a function from an input row to class probabilities.
public struct SleepStageTrees: Sendable {

    /// The first line of a file this reads.
    public static let format = "renoop-sleep-stage-trees 1"

    /// Input names, in the order of a row.
    public let columns: [String]
    /// The order of a row of probabilities as the file gives it.
    public let classes: [String]
    /// The model's own settings; the second model of a pair carries the decoder's.
    public let meta: [String: String]
    /// Hex SHA-256 of the `.mlmodel` the file was written from.
    public let source: String
    public var treeCount: Int { roots.count }

    private let base: [Double]
    /// Every tree's nodes end to end. A node is a branch (`column >= 0`: go to `yes` when the row's
    /// value is below `value`, else to `no`) or a leaf (`column < 0`: add `value` to class `yes`).
    private let column: [Int32]
    private let value: [Double]
    private let yes: [Int32]
    private let no: [Int32]
    /// Where each tree's root sits in the arrays above.
    private let roots: [Int32]

    /// Reads a file's text. nil for anything that is not a well-formed file of this format: a model
    /// half-read would stage nights wrongly without saying so.
    public init?(text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        if lines.last == "" { lines = lines.dropLast() }
        guard lines.popFirst().map(String.init) == Self.format else { return nil }
        var classes: [String] = [], base: [Double] = [], meta: [String: String] = [:], source = ""
        var columns: [String]?
        while let line = lines.popFirst() {
            if line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            switch parts.first {
            case "source":
                let words = line.split(separator: " ")
                guard words.count == 4, words[2] == "sha256" else { return nil }
                source = String(words[3])
            case "classes": classes = line.split(separator: " ").dropFirst().map(String.init)
            case "transform": guard line == "transform softmax" else { return nil }
            case "base":
                let numbers = line.split(separator: " ").dropFirst().map { Double($0) }
                guard numbers.allSatisfy({ $0?.isFinite == true }) else { return nil }
                base = numbers.compactMap { $0 }
            case "meta":
                guard parts.count == 3 else { return nil }
                meta[parts[1]] = parts[2]
            case "columns":
                guard parts.count == 2, let n = Int(parts[1]), n > 0, lines.count >= n else { return nil }
                columns = lines.prefix(n).map(String.init)
                lines = lines.dropFirst(n)
            default: return nil
            }
            if columns != nil { break }
        }
        guard let columns, !classes.isEmpty, base.count == classes.count, Set(columns).count == columns.count,
              Set(classes).count == classes.count,
              let header = lines.popFirst()?.split(separator: " "), header.count == 2, header[0] == "trees",
              let treeCount = Int(header[1]), treeCount > 0 else { return nil }

        var column: [Int32] = [], value: [Double] = [], yes: [Int32] = [], no: [Int32] = [], roots: [Int32] = []
        for _ in 0..<treeCount {
            guard let head = lines.popFirst()?.split(separator: " "), head.count == 2, head[0] == "tree",
                  let nodes = Int(head[1]), nodes > 0, lines.count >= nodes else { return nil }
            let root = column.count
            roots.append(Int32(root))
            for index in 0..<nodes {
                let f = lines.removeFirst().split(separator: " ")
                if f.count == 3, f[0] == "l", let c = Int(f[1]), let v = Double(f[2]), v.isFinite,
                   classes.indices.contains(c) {
                    column.append(-1); value.append(v); yes.append(Int32(c)); no.append(0)
                } else if f.count == 5, f[0] == "b", let c = Int(f[1]), let v = Double(f[2]), v.isFinite,
                          let y = Int(f[3]), let n = Int(f[4]), columns.indices.contains(c),
                          // A branch points only forward, so no walk can loop.
                          y > index, n > index, y < nodes, n < nodes {
                    column.append(Int32(c)); value.append(v); yes.append(Int32(root + y)); no.append(Int32(root + n))
                } else {
                    return nil
                }
            }
        }
        guard lines.isEmpty else { return nil }
        self.columns = columns
        self.classes = classes
        self.meta = meta
        self.source = source
        self.base = base
        self.column = column
        self.value = value
        self.yes = yes
        self.no = no
        self.roots = roots
    }

    /// One row's probabilities, in the file's class order. `row` holds one number per column.
    public func probabilities(_ row: [Double]) -> [Double] {
        precondition(row.count == columns.count, "a row carries one number per column")
        var out = [Double](repeating: 0, count: base.count)
        row.withUnsafeBufferPointer { rowBuf in
            fillProbabilities(rowBuf.baseAddress!, into: &out)
        }
        return out
    }

    /// A tree file shipped in this package. nil when the resource is missing or unreadable.
    public static func bundled(_ name: String) -> SleepStageTrees? {
        let url = Bundle.module.url(forResource: name, withExtension: "trees", subdirectory: "SleepModel")
            ?? Bundle.module.url(forResource: name, withExtension: "trees")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return SleepStageTrees(text: text)
    }

    /// A night's rows as probabilities in `order` (the decoder's stage order, say). nil when a row has
    /// the wrong width or `order` names a class this model does not have.
    public func probabilities(_ rows: [[Double]], order: [String]) -> [[Double]]? {
        let index = order.map { classes.firstIndex(of: $0) }
        guard index.allSatisfy({ $0 != nil }), rows.allSatisfy({ $0.count == columns.count }) else { return nil }
        let map = index.map { $0! }
        let nClass = base.count
        var raw = [Double](repeating: 0, count: nClass)
        var out: [[Double]] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            row.withUnsafeBufferPointer { rowBuf in
                fillProbabilities(rowBuf.baseAddress!, into: &raw)
            }
            var ordered = [Double](repeating: 0, count: map.count)
            for i in 0..<map.count { ordered[i] = raw[map[i]] }
            out.append(ordered)
        }
        return out
    }

    /// Walk every tree into `out` (file class order) and softmax in place. `row` is `columns.count` long.
    private func fillProbabilities(_ row: UnsafePointer<Double>, into out: inout [Double]) {
        let nClass = base.count
        out.replaceSubrange(0..<nClass, with: base)
        column.withUnsafeBufferPointer { col in
            value.withUnsafeBufferPointer { val in
                yes.withUnsafeBufferPointer { yesB in
                    no.withUnsafeBufferPointer { noB in
                        let colP = col.baseAddress!
                        let valP = val.baseAddress!
                        let yesP = yesB.baseAddress!
                        let noP = noB.baseAddress!
                        for r in roots {
                            var node = Int(r)
                            while colP[node] >= 0 {
                                node = Int(row[Int(colP[node])] < valP[node] ? yesP[node] : noP[node])
                            }
                            out[Int(yesP[node])] += valP[node]
                        }
                    }
                }
            }
        }
        var top = out[0]
        for i in 1..<nClass where out[i] > top { top = out[i] }
        var total = 0.0
        for i in 0..<nClass {
            let w = exp(out[i] - top)
            out[i] = w
            total += w
        }
        for i in 0..<nClass { out[i] = out[i] / total }
    }
}

public extension SleepStageModel {

    /// The pair as two tree files, with the decoder settings the second one carries. nil unless the
    /// files take exactly this build's columns and carry the decoder settings.
    init?(first: SleepStageTrees, second: SleepStageTrees, version: String) {
        let stages = SleepStageDecoder.stages
        guard first.columns == SleepStageContext.firstNames, second.columns == SleepStageContext.secondNames,
              Set(first.classes) == Set(stages), Set(second.classes) == Set(stages),
              second.meta["classes"] == stages.joined(separator: ","),      // the order `classPrior` is in
              let prior = second.meta["classPrior"]?.split(separator: ",").map({ Double($0) }),
              prior.count == stages.count, prior.allSatisfy({ $0 != nil }),
              let weight = second.meta["priorWeight"].flatMap({ Double($0) }),
              let smoothing = second.meta["smoothing"].flatMap({ Double($0) }) else { return nil }
        self.init(version: version, prior: prior.compactMap { $0 }, weight: weight, smoothing: smoothing,
                  first: { first.probabilities($0, order: stages) },
                  second: { second.probabilities($0, order: stages) })
    }
}
