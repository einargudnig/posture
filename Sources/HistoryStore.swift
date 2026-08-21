import Foundation

/// One observed minute. Minutes where the sensor delivered nothing are simply
/// absent from the file — that absence is what keeps "% upright" honest, since
/// the denominator only ever counts time actually measured.
struct MinuteRecord: Codable, Equatable {
    var start: Date
    var observed: TimeInterval
    var slouched: TimeInterval
    var meanDrop: Double

    enum CodingKeys: String, CodingKey {
        case start = "t"
        case observed = "obs"
        case slouched = "slouch"
        case meanDrop = "drop"
    }
}

/// Append-only history, one JSON object per line.
///
/// JSONL rather than a database: the whole app is 776K with no dependencies,
/// and this answers two questions. A line is written once a minute, so the cost
/// of opening and closing the file each time is irrelevant, and a crash can
/// lose at most the minute in progress.
///
/// Every write is best-effort. A full disk or an unwritable directory must
/// never interrupt monitoring, so nothing here throws into the sensor path.
final class HistoryStore {
    /// 90 days of observed minutes is roughly 43k lines — small enough to parse
    /// on demand without needing a rollup index. Longer retention would.
    static let retentionDays = 90

    let url: URL
    private let retention: Int

    init(url: URL = HistoryStore.defaultURL, retentionDays: Int = HistoryStore.retentionDays) {
        self.url = url
        self.retention = retentionDays
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Posture", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    // MARK: - Writing

    func append(_ record: MinuteRecord) {
        guard var line = try? Self.encoder.encode(record) else { return }
        line.append(0x0A)

        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if !fm.fileExists(atPath: url.path) {
            try? line.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    // MARK: - Reading

    /// Tolerates a truncated final line, which is what a crash mid-write leaves
    /// behind, and skips anything else that fails to decode rather than
    /// discarding the whole file.
    func load() -> [MinuteRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap {
            try? Self.decoder.decode(MinuteRecord.self, from: Data($0))
        }
    }

    func trim(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(retention) * 86_400)
        let kept = load().filter { $0.start >= cutoff }
        guard !kept.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) { clear() }
            return
        }
        var data = Data()
        for record in kept {
            guard var line = try? Self.encoder.encode(record) else { continue }
            line.append(0x0A)
            data.append(line)
        }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Rollups

/// A day's worth of observed time.
struct DaySummary: Equatable, Identifiable {
    var day: Date
    var observed: TimeInterval
    var slouched: TimeInterval

    var id: Date { day }

    /// Below this, a percentage is noise dressed as insight — eleven observed
    /// minutes should not produce a confident "62% upright".
    static let minimumObserved: TimeInterval = 600

    var uprightFraction: Double? {
        guard observed >= Self.minimumObserved else { return nil }
        return 1 - (slouched / observed)
    }
}

/// An hour of the day, aggregated across every day in the window — this is what
/// answers "when does it go wrong", which daily totals cannot.
struct HourSummary: Equatable, Identifiable {
    var hour: Int
    var observed: TimeInterval
    var slouched: TimeInterval

    var id: Int { hour }

    var slouchFraction: Double? {
        guard observed >= 300 else { return nil }
        return slouched / observed
    }
}

enum HistoryRollup {
    static func days(
        _ records: [MinuteRecord], calendar: Calendar = .current, limit: Int? = nil
    ) -> [DaySummary] {
        var totals: [Date: DaySummary] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.start)
            var summary = totals[day] ?? DaySummary(day: day, observed: 0, slouched: 0)
            summary.observed += record.observed
            summary.slouched += record.slouched
            totals[day] = summary
        }
        let sorted = totals.values.sorted { $0.day < $1.day }
        guard let limit, sorted.count > limit else { return sorted }
        return Array(sorted.suffix(limit))
    }

    static func hours(_ records: [MinuteRecord], calendar: Calendar = .current) -> [HourSummary] {
        var totals = (0..<24).map { HourSummary(hour: $0, observed: 0, slouched: 0) }
        for record in records {
            let hour = calendar.component(.hour, from: record.start)
            guard totals.indices.contains(hour) else { continue }
            totals[hour].observed += record.observed
            totals[hour].slouched += record.slouched
        }
        return totals
    }

    static func day(
        _ records: [MinuteRecord], containing date: Date, calendar: Calendar = .current
    ) -> DaySummary {
        let target = calendar.startOfDay(for: date)
        var summary = DaySummary(day: target, observed: 0, slouched: 0)
        for record in records where calendar.isDate(record.start, inSameDayAs: target) {
            summary.observed += record.observed
            summary.slouched += record.slouched
        }
        return summary
    }
}
