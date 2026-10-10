import Foundation

/// RFC 5322 dates plus the obsolete and broken forms found in old archives:
/// optional weekday, 2-digit years, missing seconds, named zones, comments ("(CET)"),
/// asctime as used in mbox separators ("Thu Mar 14 10:00:00 2019"), and ISO 8601.
public enum MailDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let germanMonths = ["mär": 3, "mai": 5, "okt": 10, "dez": 12]
    private static let zones: [String: Int] = [
        "ut": 0, "utc": 0, "gmt": 0, "z": 0,
        "est": -300, "edt": -240, "cst": -360, "cdt": -300, "mst": -420, "mdt": -360, "pst": -480, "pdt": -420,
        "cet": 60, "cest": 120, "met": 60, "mest": 120, "eet": 120, "eest": 180, "bst": 60, "wet": 0, "west": 60,
    ]

    public static func parse(_ raw: String?) -> Date? {
        // A real date fits easily; capping keeps comment stripping cheap on hostile headers.
        guard var s = raw.map({ String($0.prefix(256)) })?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let iso = parseISO(s) { return iso }
        // drop comments
        while let open = s.firstIndex(of: "("), let close = s[open...].firstIndex(of: ")") {
            s.removeSubrange(open...close)
        }
        let tokens = s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map { String($0) }
        var day: Int?, month: Int?, year: Int?
        var hour = 0, minute = 0, second = 0
        var offsetMinutes: Int?
        var sawTime = false
        for t in tokens {
            let lower = t.lowercased()
            if t.contains(":"), !sawTime {
                let parts = t.split(separator: ":").map { Int($0) }
                guard parts.count >= 2, let h = parts[0], let m = parts[1] else { continue }
                hour = h; minute = m
                if parts.count >= 3, let sec = parts[2] { second = sec }
                sawTime = true
                continue
            }
            if (t.hasPrefix("+") || t.hasPrefix("-")), t.count >= 5, let v = Int(t.dropFirst().prefix(4)) {
                let mins = (v / 100) * 60 + v % 100
                offsetMinutes = t.hasPrefix("-") ? -mins : mins
                continue
            }
            if let m = months.firstIndex(where: { lower.hasPrefix($0) }), lower.count >= 3, month == nil {
                month = m + 1
                continue
            }
            if let m = germanMonths[String(lower.prefix(3))], month == nil {
                month = m
                continue
            }
            if let z = zones[lower] { offsetMinutes = offsetMinutes ?? z; continue }
            if lower.count == 1, lower.first!.isLetter { offsetMinutes = offsetMinutes ?? 0; continue }  // military
            if let n = Int(t) {
                if t.count >= 3 || n > 31 { year = year ?? n }
                else if day == nil { day = n }
                else if year == nil { year = n }
            }
        }
        guard let d = day, let mo = month, var y = year else { return nil }
        if y < 50 { y += 2000 } else if y < 100 { y += 1900 }
        guard (1...31).contains(d), (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second),
              (1900...2200).contains(y) else { return nil }
        var tm = tm()
        tm.tm_year = Int32(y - 1900)
        tm.tm_mon = Int32(mo - 1)
        tm.tm_mday = Int32(d)
        tm.tm_hour = Int32(hour)
        tm.tm_min = Int32(minute)
        tm.tm_sec = Int32(min(second, 59))
        let epoch = timegm(&tm)
        return Date(timeIntervalSince1970: TimeInterval(epoch) - TimeInterval((offsetMinutes ?? 0) * 60))
    }

    private static func parseISO(_ s: String) -> Date? {
        guard s.count >= 19, s.dropFirst(4).first == "-", s.dropFirst(10).first == "T" || s.dropFirst(10).first == " " else { return nil }
        var normalized = s.replacingOccurrences(of: " ", with: "T", options: [], range: s.index(s.startIndex, offsetBy: 10)..<s.index(s.startIndex, offsetBy: 11))
        if !(normalized.hasSuffix("Z") || normalized.dropFirst(19).contains("+") || normalized.dropFirst(19).contains("-")) {
            normalized += "Z"
        }
        return try? Date(normalized, strategy: .iso8601)
    }
}
