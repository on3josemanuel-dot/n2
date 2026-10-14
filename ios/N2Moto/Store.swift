import Foundation

/// Carga el roadbook y la previsión de cada etapa, y la guarda en el teléfono
/// para poder consultarla en ruta sin cobertura.
@MainActor
final class Store: ObservableObject {
    let trip = Trip.load()
    @Published var forecasts: [Int: [RoutePoint]] = [:]
    @Published var updated: [Int: Date] = [:]
    @Published var loading: Set<Int> = []
    @Published var errors: [Int: String] = [:]

    init() {
        for d in trip.days {
            if let data = UserDefaults.standard.data(forKey: "wx-\(d.n)"),
               let pts = try? JSONDecoder().decode([RoutePoint].self, from: data) {
                forecasts[d.n] = pts
                updated[d.n] = UserDefaults.standard.object(forKey: "wx-\(d.n)-t") as? Date
            }
        }
    }

    var todayDay: Day? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let t = f.string(from: Date())
        return trip.days.first { $0.date == t }
    }

    func points(_ day: Day) -> [RoutePoint] { forecasts[day.n] ?? Route.build(day) }

    func load(_ day: Day, force: Bool = false) async {
        if !force, let t = updated[day.n], Date().timeIntervalSince(t) < 3 * 3600 { return }
        if loading.contains(day.n) { return }
        loading.insert(day.n)
        defer { loading.remove(day.n) }
        var pts = Route.build(day)
        do {
            let blocks = try await WeatherAPI.fetch(pts, date: day.date)
            for i in pts.indices where i < blocks.count {
                pts[i].wx = blocks[i].wx(at: pts[i].eta ?? Date())
                pts[i].alert = pts[i].wx.flatMap { WMO.alert($0) }
            }
            forecasts[day.n] = pts
            updated[day.n] = Date()
            errors[day.n] = nil
            if let data = try? JSONEncoder().encode(pts) {
                UserDefaults.standard.set(data, forKey: "wx-\(day.n)")
                UserDefaults.standard.set(Date(), forKey: "wx-\(day.n)-t")
            }
        } catch {
            errors[day.n] = forecasts[day.n]?.contains(where: { $0.wx != nil }) == true
                ? "Sin cobertura: se muestra la última previsión guardada."
                : "Todavía no hay previsión para esta fecha o falta cobertura. Desliza hacia abajo para reintentar."
            if forecasts[day.n] == nil { forecasts[day.n] = pts }
        }
    }
}

// MARK: - Open-Meteo

struct HourlyBlock {
    var times: [Date] = []
    var temp: [Double?] = []
    var code: [Double?] = []
    var wind: [Double?] = []
    var dir: [Double?] = []
    var gust: [Double?] = []
    var vis: [Double?] = []
    var pp: [Double?] = []
    var sunrise: Date?
    var sunset: Date?

    func wx(at date: Date) -> Wx? {
        guard !times.isEmpty else { return nil }
        var best = 0
        var bd = Double.infinity
        for (i, t) in times.enumerated() {
            let d = abs(t.timeIntervalSince(date))
            if d < bd { bd = d; best = i }
        }
        func v(_ a: [Double?], _ def: Double) -> Double { best < a.count ? (a[best] ?? def) : def }
        let night: Bool = {
            guard let sr = sunrise, let ss = sunset else { return false }
            return date < sr || date > ss
        }()
        return Wx(temp: v(temp, 0), wind: v(wind, 0), gust: v(gust, v(wind, 0)), dir: v(dir, 0),
                  pp: best < pp.count ? pp[best] : nil, code: Int(v(code, 0)),
                  vis: v(vis, 30000) / 1000, night: night)
    }
}

enum WeatherAPI {
    struct Failure: Error {}

    static func fetch(_ pts: [RoutePoint], date: String) async throws -> [HourlyBlock] {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: pts.map { String(format: "%.4f", $0.lat) }.joined(separator: ",")),
            .init(name: "longitude", value: pts.map { String(format: "%.4f", $0.lon) }.joined(separator: ",")),
            .init(name: "hourly", value: "temperature_2m,weathercode,windspeed_10m,winddirection_10m,windgusts_10m,visibility,precipitation_probability"),
            .init(name: "daily", value: "sunrise,sunset"),
            .init(name: "timezone", value: "GMT"),
            .init(name: "start_date", value: date),
            .init(name: "end_date", value: date)
        ]
        guard let url = c.url else { throw Failure() }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure() }
        let json = try JSONSerialization.jsonObject(with: data)
        let list: [[String: Any]]
        if let a = json as? [[String: Any]] { list = a }
        else if let o = json as? [String: Any] { list = [o] }
        else { throw Failure() }
        return list.map(parse)
    }

    private static func parse(_ d: [String: Any]) -> HourlyBlock {
        var b = HourlyBlock()
        guard let h = d["hourly"] as? [String: Any] else { return b }
        func arr(_ k: String) -> [Double?] { (h[k] as? [Any])?.map { ($0 as? NSNumber)?.doubleValue } ?? [] }
        b.times = (h["time"] as? [String] ?? []).compactMap { Fmt.gmt.date(from: $0) }
        b.temp = arr("temperature_2m")
        b.code = arr("weathercode")
        b.wind = arr("windspeed_10m")
        b.dir = arr("winddirection_10m")
        b.gust = arr("windgusts_10m")
        b.vis = arr("visibility")
        b.pp = arr("precipitation_probability")
        if let daily = d["daily"] as? [String: Any] {
            b.sunrise = (daily["sunrise"] as? [String])?.first.flatMap { Fmt.gmt.date(from: $0) }
            b.sunset = (daily["sunset"] as? [String])?.first.flatMap { Fmt.gmt.date(from: $0) }
        }
        return b
    }
}
