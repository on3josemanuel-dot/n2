import SwiftUI

@main
struct N2MotoApp: App {
    @StateObject private var store = Store()
    @StateObject private var tracker = Tracker()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(tracker)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tracker: Tracker
    @State private var path: [Day] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(store.trip.days) { d in
                        NavigationLink(value: d) { DayRow(day: d, today: store.todayDay?.n == d.n, active: tracker.activeDay == d.n) }
                    }
                } header: {
                    Text("18–23 de octubre · 9 motos")
                }
                if !store.trip.remind.isEmpty {
                    Section("No se os olvide") {
                        ForEach(store.trip.remind, id: \.self) { Text($0).font(.subheadline) }
                    }
                }
                Section {
                    Text("Emergencias en España y Portugal: 112").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("La N2 entera")
            .navigationDestination(for: Day.self) { DayView(day: $0) }
        }
        .onAppear {
            if path.isEmpty, let d = store.todayDay { path = [d] }
        }
    }
}

struct DayRow: View {
    let day: Day
    let today: Bool
    let active: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3).fill(day.tint).frame(width: 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Día \(day.n) · \(day.label)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if today { Badge(text: "HOY", color: .green) }
                    if active { Badge(text: "EN RUTA", color: .orange) }
                }
                Text("\(day.from) → \(day.to)").font(.headline)
                Text("\(day.km) km · sale \(day.sal) · llega \(day.lle)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.heavy)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(color, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.black)
    }
}

struct DayView: View {
    let day: Day
    @EnvironmentObject var store: Store
    @EnvironmentObject var tracker: Tracker

    private var pts: [RoutePoint] { store.points(day) }
    private var alerts: [RoutePoint] { pts.filter { $0.alert != nil } }
    private var isActive: Bool { tracker.activeDay == day.n }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Día \(day.n) · \(day.label) · \(day.km) km").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(day.from) → \(day.to)").font(.title2.bold())
                    Text("Salida \(day.sal) · llegada \(day.lle)").font(.subheadline)
                    Text(day.roads).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Text(day.desc).font(.subheadline)
            }

            Section {
                Button {
                    if isActive { tracker.stop() } else { tracker.start(day: day, points: pts) }
                } label: {
                    Label(isActive ? "Parar los avisos" : "Empezar los avisos en ruta",
                          systemImage: isActive ? "stop.circle.fill" : "location.circle.fill")
                        .font(.headline)
                }
                .tint(isActive ? .red : day.tint)
                if isActive, !tracker.status.isEmpty {
                    Text(tracker.status).font(.footnote).foregroundStyle(.secondary)
                }
                Button { tracker.testVoice() } label: { Label("Probar la voz", systemImage: "speaker.wave.2.fill") }
                if let url = day.routeURL {
                    Link(destination: url) { Label("Abrir la ruta del día en Google Maps", systemImage: "map.fill") }
                }
            } footer: {
                Text("Los avisos siguen funcionando con la pantalla bloqueada y con Mapy o Google Maps delante. Abre la etapa con cobertura antes de salir para guardar la previsión.")
            }

            Section {
                if store.loading.contains(day.n) {
                    HStack { ProgressView(); Text("Cargando la previsión…").foregroundStyle(.secondary) }
                }
                if let e = store.errors[day.n] {
                    Text(e).font(.footnote).foregroundStyle(.orange)
                }
                if alerts.isEmpty, pts.contains(where: { $0.wx != nil }) {
                    Label("Sin avisos de tiempo para esta etapa", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                ForEach(alerts) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(p.etaText) · \(p.title)").font(.subheadline.weight(.semibold))
                        Text(p.alert ?? "").font(.subheadline).foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Avisos de tiempo")
            } footer: {
                if let t = store.updated[day.n] {
                    Text("Previsión actualizada \(t.formatted(.relative(presentation: .named)))")
                }
            }

            Section("Tiempo a la hora de paso") {
                ForEach(pts) { p in WxRow(p: p) }
            }

            if !day.notes.isEmpty {
                Section("Lo que hay que saber") {
                    ForEach(day.notes, id: \.self) { Text($0).font(.subheadline) }
                }
            }

            Section("Horario del roadbook") {
                ForEach(day.stops, id: \.self) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(s.t ?? "").font(.subheadline.monospacedDigit().weight(.bold)).foregroundStyle(day.tint).frame(width: 48, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.n).font(.subheadline.weight(.semibold))
                            if let n = s.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }

            Section("Comer, dormir, cenar") {
                ForEach(day.eat, id: \.self) { e in
                    PlaceRow(kind: e.k, name: e.n, place: e.p, tel: e.tel, note: e.note)
                }
                if let s = day.sleep {
                    PlaceRow(kind: "Hotel", name: s.n, place: nil, tel: s.tel, note: s.note)
                }
            }
        }
        .navigationTitle("Día \(day.n)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load(day) }
        .refreshable { await store.load(day, force: true) }
        .onChange(of: store.forecasts[day.n]) { _, new in
            if isActive, let new { tracker.update(points: new) }
        }
    }
}

struct WxRow: View {
    let p: RoutePoint
    var body: some View {
        HStack(spacing: 10) {
            Text(p.etaText).font(.subheadline.monospacedDigit().weight(.semibold)).frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title).font(p.name == nil ? .subheadline : .subheadline.weight(.semibold))
                    .foregroundStyle(p.name == nil ? .secondary : .primary)
                if let w = p.wx {
                    Text(details(w)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let w = p.wx {
                Text(WMO.info(w.code).0).font(.title3)
                Text("\(Int(w.temp.rounded()))°").font(.headline.monospacedDigit())
            }
            if p.alert != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }

    private func details(_ w: Wx) -> String {
        var s = "Viento \(Int(w.wind)) · ráfagas \(Int(w.gust)) km/h"
        if let pp = w.pp { s += " · lluvia \(Int(pp)) %" }
        if w.night { s += " · de noche" }
        return s
    }
}

struct PlaceRow: View {
    let kind: String
    let name: String
    let place: String?
    let tel: String?
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(kind.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(place.map { "\(name) · \($0)" } ?? name).font(.subheadline.weight(.semibold))
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            if let tel, let url = Fmt.telURL(tel) {
                Link(destination: url) { Label(tel, systemImage: "phone.fill").font(.subheadline.monospacedDigit()) }
            }
        }
        .padding(.vertical, 2)
    }
}
