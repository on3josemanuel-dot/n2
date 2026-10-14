import Foundation
import CoreLocation
import AVFoundation
import UserNotifications

/// Sigue la posición en segundo plano y avisa por voz (y con una notificación)
/// cuando se acerca un tramo con mal tiempo. Funciona con la pantalla bloqueada
/// y con Mapy o Google Maps en primer plano.
@MainActor
final class Tracker: NSObject, ObservableObject {
    @Published var activeDay: Int?
    @Published var status = ""
    @Published var denied = false

    private let lm = CLLocationManager()
    private let synth = AVSpeechSynthesizer()
    private var points: [RoutePoint] = []
    private var spoken = Set<Int>()
    private var totalKm = 0

    override init() {
        super.init()
        lm.delegate = self
        synth.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyHundredMeters
        lm.distanceFilter = 150
        lm.activityType = .automotiveNavigation
        lm.pausesLocationUpdatesAutomatically = false
    }

    func start(day: Day, points: [RoutePoint]) {
        self.points = points
        spoken = []
        totalKm = day.km
        activeDay = day.n
        status = "Buscando tu posición…"
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if lm.authorizationStatus == .notDetermined {
            lm.requestWhenInUseAuthorization()
        }
        lm.allowsBackgroundLocationUpdates = true
        lm.showsBackgroundLocationIndicator = true
        lm.startUpdatingLocation()
        let n = points.filter { $0.alert != nil }.count
        speak(n == 0
              ? "Avisos activados. Hoy no hay avisos de tiempo en la ruta."
              : "Avisos activados. Hoy hay \(n) \(n == 1 ? "aviso" : "avisos") de tiempo en la ruta. Os iré avisando unos treinta kilómetros antes.")
    }

    func update(points: [RoutePoint]) {
        guard activeDay != nil else { return }
        self.points = points
    }

    func stop() {
        lm.stopUpdatingLocation()
        lm.allowsBackgroundLocationUpdates = false
        activeDay = nil
        status = ""
    }

    func testVoice() {
        speak("Prueba de sonido. Si me oís por el intercomunicador, los avisos llegarán bien.")
    }

    private func handle(_ loc: CLLocation) {
        guard !points.isEmpty else { return }
        var nearest = 0
        var nd = Double.infinity
        for (i, p) in points.enumerated() {
            let d = loc.distance(from: p.location)
            if d < nd { nd = d; nearest = i }
        }
        let done = Int(points[nearest].km.rounded())
        status = nd > 40_000
            ? "Estás lejos de la ruta de hoy."
            : "Vas por el km \(done) de \(totalKm) · cerca de \(points[nearest].title)"
        guard nd <= 40_000 else { return }
        for i in nearest..<min(nearest + 4, points.count) {
            guard let a = points[i].alert, !spoken.contains(i) else { continue }
            let km = loc.distance(from: points[i].location) / 1000
            guard km <= 30 else { continue }
            spoken.insert(i)
            let place = points[i].name.map { ", en \($0)" } ?? ""
            let msg = km < 3
                ? "Atención. \(a)\(place), ya muy cerca."
                : "Atención. \(a)\(place). En unos \(Int(km.rounded())) kilómetros."
            speak(msg)
            notify(msg)
            break
        }
    }

    private func speak(_ text: String) {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? s.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "es-ES")
        u.rate = 0.48
        u.volume = 1
        synth.speak(u)
    }

    private func notify(_ text: String) {
        let c = UNMutableNotificationContent()
        c.title = "Aviso de tiempo"
        c.body = text
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private func authChanged(_ status: CLAuthorizationStatus) {
        denied = status == .denied || status == .restricted
        if denied { self.status = "Sin permiso de ubicación: actívalo en Ajustes › N2 Moto › Ubicación." }
    }
}

extension Tracker: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in self.handle(l) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in self.authChanged(s) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

extension Tracker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
