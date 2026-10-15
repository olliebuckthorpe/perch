import CoreML
import Foundation

/// Turns text into a vector of meaning with bge-small (BAAI's small English embedding model),
/// run on the Mac's Neural Engine. Two texts about the same thing land close together even
/// when they share no words. Everything stays on the Mac.
final class Embedder {
    static let shared = Embedder()

    private let model: MLModel?
    private var vocab: [String: Int32] = [:]
    private let lock = NSLock()
    private static let sizes = [64, 128, 256]

    private init() {
        let resources = Bundle.main.resourceURL
        if let url = resources?.appendingPathComponent("bge-small.mlmodelc") {
            let config = MLModelConfiguration()
            // The CPU on its own: this model is small enough that it runs in a few milliseconds
            // with about 20 MB of memory there, never touching the GPU. (Preparing it for the
            // Neural Engine instead took 16 seconds and gigabytes of memory, and ran slower.)
            config.computeUnits = .cpuOnly
            model = try? MLModel(contentsOf: url, configuration: config)
        } else {
            model = nil
        }
        if let url = resources?.appendingPathComponent("bge-vocab.txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                vocab[String(line)] = Int32(i)
            }
        }
    }

    var ready: Bool { model != nil && !vocab.isEmpty }

    /// A search, phrased the way the model expects a question to be.
    func query(_ text: String) -> [Float]? {
        embed("Represent this sentence for searching relevant passages: " + text)
    }

    func embed(_ text: String) -> [Float]? {
        autoreleasepool { run(text) }
    }

    private func run(_ text: String) -> [Float]? {
        guard let model else { return nil }
        let ids = tokens(text)
        let size = Self.sizes.first { $0 >= ids.count } ?? Self.sizes.last!
        guard let input = try? MLMultiArray(shape: [1, NSNumber(value: size)], dataType: .int32),
              let mask = try? MLMultiArray(shape: [1, NSNumber(value: size)], dataType: .int32) else { return nil }
        for i in 0..<size {
            input[i] = NSNumber(value: i < ids.count ? ids[i] : 0)
            mask[i] = NSNumber(value: i < ids.count ? 1 : 0)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let features = try? MLDictionaryFeatureProvider(dictionary: ["ids": input, "mask": mask]),
              let out = try? model.prediction(from: features),
              let vector = out.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        return (0..<vector.count).map { Float(truncating: vector[$0]) }
    }

    // MARK: Word pieces (BERT, lower-cased)

    private func tokens(_ text: String) -> [Int32] {
        let cls = vocab["[CLS]"] ?? 101, sep = vocab["[SEP]"] ?? 102, unk = vocab["[UNK]"] ?? 100
        var out: [Int32] = [cls]
        let limit = Self.sizes.last! - 1
        for word in basic(text) {
            guard out.count < limit else { break }
            let chars = Array(word)
            if chars.count > 100 { out.append(unk); continue }
            var pieces: [Int32] = []
            var start = 0
            var bad = false
            while start < chars.count {
                var end = chars.count
                var found: Int32?
                while start < end {
                    let piece = (start > 0 ? "##" : "") + String(chars[start..<end])
                    if let id = vocab[piece] { found = id; break }
                    end -= 1
                }
                guard let found else { bad = true; break }
                pieces.append(found)
                start = end
            }
            out.append(contentsOf: bad ? [unk] : pieces)
        }
        if out.count > limit { out = Array(out.prefix(limit)) }
        out.append(sep)
        return out
    }

    /// Lower-cased, accents removed, split on spaces and around punctuation.
    private func basic(_ text: String) -> [String] {
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var words: [String] = []
        var current = ""
        for ch in folded {
            if ch.isWhitespace {
                if !current.isEmpty { words.append(current); current = "" }
            } else if ch.isPunctuation || ch.isSymbol {
                if !current.isEmpty { words.append(current); current = "" }
                words.append(String(ch))
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
