import Foundation

/// Years as the app writes them where the server sends no words of its own.
public enum YearText {
    /// "spring YV 1131": the season from the quarter of the year (the server's words are used
    /// wherever it sends them).
    public static func label(_ year: Double) -> String {
        let seasons = ["winter", "spring", "summer", "autumn"]
        let whole = floor(year)
        let q = Int(((year - whole) * 4).rounded()) % 4
        let y = Int(whole) + (((year - whole) * 4).rounded() >= 4 ? 1 : 0)
        return "\(seasons[q]) YV \(y)"
    }
}
