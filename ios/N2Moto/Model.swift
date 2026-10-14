import Foundation
import CoreLocation
import SwiftUI

// MARK: - Roadbook (trip.json, generado desde la web)

struct Trip: Codable {
    let remind: [String]
    let days: [Day]

    static func load() -> Trip {
        guard let url = Bundle.main.url(forResource: "trip", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let trip = try? JSONDecoder().decode(Trip.self, from: data) else {
            return Trip(remind: [], days: [])
        }
        return trip
    }
}

struct Day: Codable, Hashable, Identifiable {
    let n: Int
    let date: String
    let label: String
    let from: String
    let to: String
    let km: Int
    let sal: String
    let lle: String
    let roads: String
    let color: String
    let avoid: Bool
    let lo: Int
    let o: Int?
    let desc: String
    let notes: [String]
    let stops: [Stop]
    let sleep: Sleep?
    let eat: [Eat]
    var id: Int { n }

    var tint: Color { Color(hex: color) }

    /// Ruta del día en Google Maps con hasta 8 paradas intermedias.
    var routeURL: URL? {
        guard let o = stops.first, let z = stops.last else { return nil }
        var mid = Array(stops.dropFirst().dropLast())
        if mid.count > 8 {
            let timed = mid.filter { $0.t != nil }
            if timed.count <= 8 { mid = timed } else {
                let step = Int((Double(timed.count) / 8).rounded(.up))
                mid = timed.enumerated().filter { $0.offset % step == 0 }.map { $0.element }.prefix(8).map { $0 }
            }
        }
        var s = "https://www.google.com/maps/dir/?api=1&origin=\(o.lat),\(o.lon)&destination=\(z.lat),\(z.lon)&travelmode=driving"
        if !mid.isEmpty { s += "&waypoints=" + mid.map { "\($0.lat),\($0.lon)" }.joined(separator: "%7C") }
        if avoid { s += "&avoid=highways" }
        return URL(string: s)
    }
}

struct Stop: Codable, Hashable {
    let n: String
    let lat: Double
    let lon: Double
    let t: String?
    let note: String?
    let lo: Int?
    let o: Int?
}

struct Sleep: Codable, Hashable {
    let n: String
    let q: String
    let tel: String
    let note: String
}

struct Eat: Codable, Hashable {
    let k: String
    let n: String
    let p: String?
    let tel: String?
    let note: String?
}

// MARK: - Puntos de la ruta con su previsión

struct Wx: Codable, Hashable {
    var temp: Double
    var wind: Double
    var gust: Double
    var dir: Double
    var pp: Double?
    var code: Int
    var vis: Double      // km
    var night: Bool
}

struct RoutePoint: Codable, Hashable, Identifiable {
    let id: Int
    let name: String?
    let lat: Double
    let lon: Double
    let km: Double
    let lo: Int          // huso horario del sitio (1 Portugal, 2 España)
    var eta: Date?
    var wx: Wx?
    var alert: String?

    var title: String { name ?? "km \(Int(km.rounded()))" }
    var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }
    var etaText: String { eta.map { Fmt.time($0, offset: lo) } ?? "" }
}

enum Route {
    static func date(_ day: String, _ hm: String, offset: Int) -> Date? {
        let d = day.split(separator: "-").compactMap { Int($0) }
        let t = hm.split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count == 2 else { return nil }
        var c = DateComponents()
        c.year = d[0]; c.month = d[1]; c.day = d[2]; c.hour = t[0]; c.minute = t[1]
        c.timeZone = TimeZone(secondsFromGMT: offset * 3600)
        return Calendar(identifier: .gregorian).date(from: c)
    }

    /// Paradas del roadbook más puntos intermedios cada ~20 km, con la hora estimada de paso.
    static func build(_ day: Day) -> [RoutePoint] {
        let s = day.stops
        guard s.count >= 2 else { return [] }
        var straight: [Double] = [0]
        for i in 1..<s.count {
            let a = CLLocation(latitude: s[i-1].lat, longitude: s[i-1].lon)
            let b = CLLocation(latitude: s[i].lat, longitude: s[i].lon)
            straight.append(straight[i-1] + a.distance(from: b) / 1000)
        }
        let total = straight.last ?? 1
        let factor = total > 0 ? Double(day.km) / total : 1
        let cum = straight.map { $0 * factor }

        // Horas del roadbook que avanzan en km y en tiempo
        var timed: [(km: Double, t: Date)] = []
        for (i, st) in s.enumerated() {
            guard let t = st.t else { continue }
            let off = st.o ?? day.o ?? (st.lo ?? day.lo)
            if let d = date(day.date, t, offset: off) { timed.append((cum[i], d)) }
        }
        var anchors = timed
        if timed.count >= 2, let first = timed.first, let last = timed.last {
            var out = [first]
            for a in timed.dropFirst().dropLast() {
                if let p = out.last, a.t > p.t, a.t < last.t, a.km > p.km, a.km < last.km { out.append(a) }
            }
            out.append(last)
            anchors = out
        }

        func eta(_ km: Double) -> Date? {
            guard let f = anchors.first else { return nil }
            if km <= f.km { return f.t }
            for i in 1..<anchors.count where km <= anchors[i].km {
                let a = anchors[i-1], b = anchors[i]
                let fr = b.km > a.km ? (km - a.km) / (b.km - a.km) : 0
                let raw = a.t.timeIntervalSince1970 + fr * b.t.timeIntervalSince(a.t)
                return Date(timeIntervalSince1970: (raw / 300).rounded() * 300)
            }
            return anchors.last?.t
        }

        var pts: [RoutePoint] = []
        for i in 0..<s.count {
            let st = s[i]
            let lo = st.lo ?? day.lo
            pts.append(RoutePoint(id: pts.count, name: st.n, lat: st.lat, lon: st.lon, km: cum[i], lo: lo, eta: eta(cum[i])))
            guard i < s.count - 1 else { break }
            let seg = cum[i+1] - cum[i]
            let n = Int(seg / 20)
            if n > 0 {
                for j in 1...n {
                    let f = Double(j) / Double(n + 1)
                    let km = cum[i] + seg * f
                    pts.append(RoutePoint(id: pts.count, name: nil,
                                          lat: st.lat + (s[i+1].lat - st.lat) * f,
                                          lon: st.lon + (s[i+1].lon - st.lon) * f,
                                          km: km, lo: lo, eta: eta(km)))
                }
            }
        }
        return pts
    }
}

// MARK: - Códigos de tiempo y avisos

enum WMO {
    static let table: [Int: (String, String, String?)] = [
        0: ("☀️", "Despejado", nil), 1: ("🌤️", "Mayormente despejado", nil), 2: ("⛅", "Parcialmente nublado", nil), 3: ("☁️", "Nublado", nil),
        45: ("🌫️", "Niebla", "Niebla densa"), 48: ("🌫️", "Niebla con escarcha", "Niebla con hielo en calzada"),
        51: ("🌦️", "Llovizna ligera", nil), 53: ("🌦️", "Llovizna", nil), 55: ("🌧️", "Llovizna intensa", nil),
        61: ("🌧️", "Lluvia ligera", nil), 63: ("🌧️", "Lluvia", "Lluvia"), 65: ("🌧️", "Lluvia intensa", "Lluvia intensa"),
        71: ("🌨️", "Nevada ligera", nil), 73: ("❄️", "Nevada", "Nieve, posible hielo"), 75: ("❄️", "Nevada intensa", "Nevada intensa"),
        80: ("🌦️", "Chubascos ligeros", nil), 81: ("🌧️", "Chubascos", "Chubascos"), 82: ("⛈️", "Chubascos fuertes", "Chubascos fuertes"),
        95: ("⛈️", "Tormenta", "Tormenta eléctrica"), 96: ("⛈️", "Tormenta con granizo", "Granizo"), 99: ("⛈️", "Tormenta con granizo", "Granizo")
    ]
    static func info(_ c: Int) -> (String, String, String?) {
        table[c] ?? table[(c / 10) * 10] ?? ("🌡️", "Variable", nil)
    }
    static let rainy: Set<Int> = [51, 53, 55, 61, 63, 65, 80, 81, 82, 95, 96, 99]

    static func alert(_ w: Wx) -> String? {
        var o: [String] = []
        if let a = info(w.code).2 { o.append(a) }
        if w.temp <= 2 { o.append("\(Int(w.temp.rounded())) grados, posible hielo") }
        if w.gust >= 75 { o.append("ráfagas muy fuertes de \(Int(w.gust)) kilómetros por hora") }
        else if w.gust >= 50 { o.append("ráfagas de \(Int(w.gust)) kilómetros por hora") }
        else if w.wind >= 50 { o.append("viento fuerte de \(Int(w.wind)) kilómetros por hora") }
        if info(w.code).2 == nil, let pp = w.pp, pp >= 70 { o.append("\(Int(pp)) por ciento de probabilidad de lluvia") }
        if w.vis < 1 { o.append("visibilidad por debajo de un kilómetro") }
        guard !o.isEmpty else { return nil }
        let s = o.joined(separator: ", ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

// MARK: - Utilidades

enum Fmt {
    static func time(_ d: Date, offset: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.timeZone = TimeZone(secondsFromGMT: offset * 3600)
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    static let gmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()
    static func telURL(_ t: String) -> URL? { URL(string: "tel:" + t.filter { !$0.isWhitespace }) }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
