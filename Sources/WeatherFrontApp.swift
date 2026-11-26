import SwiftUI
import MapKit
import CoreLocation

// Weather Front — personal radar + models app for Rob.
// Data: RainViewer (US radar tiles), IEM single-site radar tiles (reflectivity + velocity),
// Open-Meteo (HRRR/GFS/NAM/NBM/ECMWF/ICON models), NWS api.weather.gov (alerts).
// No account, no API key, no ads.

let orangeCity = CLLocationCoordinate2D(latitude: 28.93472, longitude: -81.28806)

@main
struct WeatherFrontApp: App {
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup {
            TabView {
                RadarView().tabItem { Label("Radar", systemImage: "cloud.rain") }
                SitesView().tabItem { Label("Sites", systemImage: "antenna.radiowaves.left.and.right") }
                ModelsView().tabItem { Label("Models", systemImage: "chart.bar") }
                AlertsView().tabItem { Label("Alerts", systemImage: "exclamationmark.triangle") }
            }
            .environmentObject(state)
        }
    }
}

// MARK: - Radar sites

struct RadarSite: Identifiable, Hashable {
    var id: String          // IEM 3-char id, e.g. MLB
    var name: String
    var lat: Double
    var lon: Double
    var type: String        // NEXRAD or TDWR
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var displayID: String { type == "NEXRAD" ? "K" + id : id }
    func milesFrom(_ c: CLLocationCoordinate2D) -> Double {
        let a = CLLocation(latitude: lat, longitude: lon)
        let b = CLLocation(latitude: c.latitude, longitude: c.longitude)
        return a.distance(from: b) / 1609.34
    }
}

let bundledSites: [RadarSite] = [
    RadarSite(id: "MLB", name: "Melbourne, FL", lat: 28.1133, lon: -80.6542, type: "NEXRAD"),
    RadarSite(id: "TBW", name: "Tampa Bay, FL", lat: 27.705, lon: -82.402, type: "NEXRAD"),
    RadarSite(id: "JAX", name: "Jacksonville, FL", lat: 30.4847, lon: -81.7019, type: "NEXRAD"),
    RadarSite(id: "AMX", name: "Miami, FL", lat: 25.611, lon: -80.413, type: "NEXRAD"),
    RadarSite(id: "TLH", name: "Tallahassee, FL", lat: 30.398, lon: -84.329, type: "NEXRAD"),
    RadarSite(id: "BYX", name: "Key West, FL", lat: 24.597, lon: -81.703, type: "NEXRAD"),
    RadarSite(id: "EVX", name: "Eglin AFB, FL", lat: 30.565, lon: -85.922, type: "NEXRAD"),
    RadarSite(id: "MCO", name: "Orlando Intl (TDWR), FL", lat: 28.34, lon: -81.32, type: "TDWR"),
    RadarSite(id: "TPA", name: "Tampa (TDWR), FL", lat: 27.86, lon: -82.51, type: "TDWR"),
    RadarSite(id: "VAX", name: "Moody AFB, GA", lat: 30.89, lon: -83.002, type: "NEXRAD"),
    RadarSite(id: "JGX", name: "Robins AFB, GA", lat: 32.6753, lon: -83.3511, type: "NEXRAD"),
    RadarSite(id: "BMX", name: "Birmingham, AL", lat: 33.172, lon: -86.770, type: "NEXRAD"),
    RadarSite(id: "MOB", name: "Mobile, AL", lat: 30.6794, lon: -88.2397, type: "NEXRAD"),
    RadarSite(id: "LIX", name: "New Orleans, LA", lat: 30.3367, lon: -89.8256, type: "NEXRAD"),
    RadarSite(id: "HGX", name: "Houston, TX", lat: 29.4719, lon: -95.0792, type: "NEXRAD"),
]

struct RadarProduct: Identifiable, Hashable {
    var id: String
    var name: String
}

func productsFor(_ site: RadarSite) -> [RadarProduct] {
    if site.type == "TDWR" {
        return [RadarProduct(id: "TZL", name: "Reflectivity"),
                RadarProduct(id: "TV0", name: "Velocity")]
    }
    return [RadarProduct(id: "N0B", name: "Reflectivity"),
            RadarProduct(id: "N0S", name: "Storm-Relative Velocity"),
            RadarProduct(id: "N0U", name: "Velocity"),
            RadarProduct(id: "NET", name: "Echo Tops")]
}

// MARK: - Location

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D? = nil
    @Published var statusText: String = "Location not asked yet"
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async {
            self.coordinate = loc.coordinate
            self.statusText = "Location on"
        }
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async {
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.statusText = "Location on"
                self.manager.startUpdatingLocation()
            case .denied, .restricted:
                self.statusText = "Location off — using Orange City"
            case .notDetermined:
                self.statusText = "Location not asked yet"
            @unknown default:
                self.statusText = "Location unknown"
            }
        }
    }
}

// MARK: - Shared state

@MainActor
final class AppState: ObservableObject {
    @Published var sites: [RadarSite] = bundledSites
    @Published var selectedSite: RadarSite = bundledSites[0]
    @Published var alertPolygons: [[CLLocationCoordinate2D]] = []
    let location = LocationManager()

    var userCoordinate: CLLocationCoordinate2D { location.coordinate ?? orangeCity }

    func useClosestNexrad() {
        let c = userCoordinate
        if let best = sites.filter({ $0.type == "NEXRAD" }).min(by: { $0.milesFrom(c) < $1.milesFrom(c) }) {
            selectedSite = best
        }
    }

    func loadNearbySites() async {
        let c = userCoordinate
        let stamp = Self.utcStamp(Date())
        let urlStr = "https://mesonet.agron.iastate.edu/json/radar.py?operation=available&lat=\(c.latitude)&lon=\(c.longitude)&start=\(stamp)"
        guard let url = URL(string: urlStr) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let resp = try JSONDecoder().decode(AvailableRadars.self, from: data)
            var merged = sites
            for r in resp.radars {
                if r.type == "COMPOSITE" { continue }
                let t = (r.type == "TWDR" || r.type == "TDWR") ? "TDWR" : "NEXRAD"
                let site = RadarSite(id: r.id, name: r.name, lat: r.lat, lon: r.lon, type: t)
                if !merged.contains(where: { $0.id == site.id }) { merged.append(site) }
            }
            sites = merged.sorted { $0.name < $1.name }
        } catch {
            // Keep bundled list if this fails.
        }
    }

    static func utcStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return f.string(from: date)
    }
}

struct AvailableRadars: Decodable {
    struct Entry: Decodable { let id: String; let name: String; let lat: Double; let lon: Double; let type: String }
    let radars: [Entry]
}

// MARK: - Map with tile overlay + warning polygons

struct RadarMapView: UIViewRepresentable {
    var tileTemplate: String
    var maxZoom: Int
    var polygons: [[CLLocationCoordinate2D]]
    var center: CLLocationCoordinate2D
    var centerToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var currentTemplate: String = ""
        var currentPolygonCount: Int = -1
        var lastCenterToken: Int = -1

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let poly = overlay as? MKPolygon {
                let r = MKPolygonRenderer(polygon: poly)
                r.strokeColor = .red
                r.fillColor = UIColor.red.withAlphaComponent(0.15)
                r.lineWidth = 2
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.setRegion(MKCoordinateRegion(center: orangeCity, span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4)), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coord = context.coordinator
        if coord.currentTemplate != tileTemplate {
            coord.currentTemplate = tileTemplate
            map.removeOverlays(map.overlays.filter { $0 is MKTileOverlay })
            if !tileTemplate.isEmpty {
                let overlay = MKTileOverlay(urlTemplate: tileTemplate)
                overlay.canReplaceMapContent = false
                overlay.maximumZ = maxZoom
                overlay.minimumZ = 0
                map.addOverlay(overlay, level: .aboveLabels)
            }
        }
        if coord.currentPolygonCount != polygons.count {
            coord.currentPolygonCount = polygons.count
            map.removeOverlays(map.overlays.filter { $0 is MKPolygon })
            for ring in polygons where ring.count > 2 {
                let poly = MKPolygon(coordinates: ring, count: ring.count)
                map.addOverlay(poly, level: .aboveRoads)
            }
        }
        if coord.lastCenterToken != centerToken {
            coord.lastCenterToken = centerToken
            map.setRegion(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 3, longitudeDelta: 3)), animated: true)
        }
    }
}

// MARK: - Radar data

struct RainViewerResponse: Decodable {
    struct Frame: Decodable { let time: Int; let path: String }
    struct Radar: Decodable { let past: [Frame] }
    let host: String
    let radar: Radar
}

struct ScanList: Decodable {
    struct Scan: Decodable { let ts: String }
    let scans: [Scan]
}

@MainActor
final class RadarViewModel: ObservableObject {
    @Published var rainFrames: [RainViewerResponse.Frame] = []
    @Published var rainHost: String = "https://tilecache.rainviewer.com"
    @Published var scans: [String] = []   // IEM scan ts strings, oldest first
    @Published var frameIndex: Int = 0
    @Published var playing: Bool = false
    @Published var message: String = ""

    func loadRainViewer() async {
        guard let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let resp = try JSONDecoder().decode(RainViewerResponse.self, from: data)
            rainHost = resp.host
            rainFrames = resp.radar.past
            frameIndex = max(0, rainFrames.count - 1)
        } catch {
            message = "Could not load US radar. Check internet."
        }
    }

    func loadScans(site: RadarSite, product: RadarProduct) async {
        let end = Date()
        let start = end.addingTimeInterval(-2 * 3600)
        let urlStr = "https://mesonet.agron.iastate.edu/json/radar.py?operation=list&radar=\(site.id)&product=\(product.id)&start=\(AppState.utcStamp(start))&end=\(AppState.utcStamp(end))"
        guard let url = URL(string: urlStr) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let resp = try JSONDecoder().decode(ScanList.self, from: data)
            scans = resp.scans.map { $0.ts }
            frameIndex = max(0, scans.count - 1)
            if scans.isEmpty {
                message = "No scans for \(product.name) at \(site.displayID) right now. Try Reflectivity."
            } else {
                message = ""
            }
        } catch {
            message = "Could not load \(site.displayID) scans. Try again."
        }
    }

    func rainTemplate() -> String {
        guard rainFrames.indices.contains(frameIndex) else { return "" }
        return "\(rainHost)\(rainFrames[frameIndex].path)/512/{z}/{x}/{y}/2/1_1.png"
    }

    func siteTemplate(site: RadarSite, product: RadarProduct) -> String {
        var stamp = "0"
        if scans.indices.contains(frameIndex) {
            stamp = scans[frameIndex].replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "T", with: "")
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "Z", with: "")
        }
        return "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/ridge::\(site.id)-\(product.id)-\(stamp)/{z}/{x}/{y}.png"
    }

    func frameTimeText(siteMode: Bool) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        if siteMode {
            guard scans.indices.contains(frameIndex) else { return "Latest" }
            let p = DateFormatter()
            p.timeZone = TimeZone(secondsFromGMT: 0)
            p.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
            if let d = p.date(from: scans[frameIndex]) { return f.string(from: d) }
            return scans[frameIndex]
        } else {
            guard rainFrames.indices.contains(frameIndex) else { return "" }
            return f.string(from: Date(timeIntervalSince1970: TimeInterval(rainFrames[frameIndex].time)))
        }
    }

    func advance(siteMode: Bool) {
        let count = siteMode ? scans.count : rainFrames.count
        guard count > 0 else { return }
        frameIndex = (frameIndex + 1) % count
    }
}

// MARK: - Radar tab

struct RadarView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm = RadarViewModel()
    @State private var siteMode: Bool = false
    @State private var product: RadarProduct = RadarProduct(id: "N0B", name: "Reflectivity")
    @State private var centerToken: Int = 0
    @State private var mapCenter: CLLocationCoordinate2D = orangeCity
    private let timer = Timer.publish(every: 0.9, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            VStack(spacing: 8) {
                Picker("Radar type", selection: $siteMode) {
                    Text("US Radar").tag(false)
                    Text("Site Radar").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if siteMode {
                    HStack {
                        Picker("Site", selection: $state.selectedSite) {
                            ForEach(state.sites) { s in
                                Text("\(s.displayID) \(s.name)").tag(s)
                            }
                        }
                        Picker("Product", selection: $product) {
                            ForEach(productsFor(state.selectedSite)) { p in
                                Text(p.name).tag(p)
                            }
                        }
                    }
                    .padding(.horizontal)
                    Text("Closest NEXRAD: \(closestText())")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if product.id == "N0S" || product.id == "N0U" || product.id == "TV0" {
                        Text("Velocity: green = wind toward the radar, red = wind away from the radar. Bright green next to bright red = rotation.")
                            .font(.caption)
                            .padding(.horizontal)
                    }
                }

                RadarMapView(
                    tileTemplate: siteMode ? vm.siteTemplate(site: state.selectedSite, product: product) : vm.rainTemplate(),
                    maxZoom: siteMode ? 12 : 7,
                    polygons: state.alertPolygons,
                    center: mapCenter,
                    centerToken: centerToken
                )
                .frame(maxHeight: .infinity)

                HStack {
                    Button(vm.playing ? "Pause" : "Play") { vm.playing.toggle() }
                    Text(vm.frameTimeText(siteMode: siteMode)).font(.caption)
                    Spacer()
                    Button("Find me") {
                        state.location.request()
                        mapCenter = state.userCoordinate
                        centerToken += 1
                    }
                    Button("Refresh") {
                        Task { await reload() }
                    }
                }
                .padding(.horizontal)

                if !vm.message.isEmpty {
                    Text(vm.message).font(.caption).foregroundColor(.red).padding(.horizontal)
                }
                Text(siteMode ? "Single-site radar: Iowa Environmental Mesonet (IEM), NWS NEXRAD data." : "US radar: RainViewer. Warning areas: National Weather Service.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            .navigationTitle("Radar")
            .onAppear {
                state.location.request()
                Task { await reload() }
            }
            .onChange(of: siteMode) { _ in Task { await reload() } }
            .onChange(of: state.selectedSite) { newSite in
                let prods = productsFor(newSite)
                if !prods.contains(product) { product = prods[0] }
                if siteMode { Task { await vm.loadScans(site: newSite, product: product) } }
            }
            .onChange(of: product) { _ in
                if siteMode { Task { await vm.loadScans(site: state.selectedSite, product: product) } }
            }
            .onReceive(timer) { _ in
                if vm.playing { vm.advance(siteMode: siteMode) }
            }
        }
    }

    func closestText() -> String {
        let c = state.userCoordinate
        guard let best = state.sites.filter({ $0.type == "NEXRAD" }).min(by: { $0.milesFrom(c) < $1.milesFrom(c) }) else { return "" }
        return "\(best.displayID) \(best.name), \(Int(best.milesFrom(c).rounded())) miles away"
    }

    func reload() async {
        if siteMode {
            await vm.loadScans(site: state.selectedSite, product: product)
        } else {
            await vm.loadRainViewer()
        }
        await state.loadNearbySites()
    }
}

// MARK: - Sites tab

struct SitesView: View {
    @EnvironmentObject var state: AppState
    @State private var search: String = ""

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button("Use closest radar") { state.useClosestNexrad() }
                    Text(state.location.statusText).font(.caption).foregroundColor(.secondary)
                    Text("Picked: \(state.selectedSite.displayID) \(state.selectedSite.name) — \(Int(state.selectedSite.milesFrom(state.userCoordinate).rounded())) miles away")
                        .font(.caption)
                }
                Section("Radar sites") {
                    ForEach(filtered) { site in
                        Button {
                            state.selectedSite = site
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(site.displayID) — \(site.name)")
                                    Text(site.type == "TDWR" ? "Airport radar, short range" : "NEXRAD")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("\(Int(site.milesFrom(state.userCoordinate).rounded())) mi")
                                    .font(.caption).foregroundColor(.secondary)
                                if site.id == state.selectedSite.id {
                                    Image(systemName: "checkmark").foregroundColor(.blue)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }
            }
            .navigationTitle("Radar Sites")
            .searchable(text: $search, prompt: "Search city or KMLB")
            .onAppear {
                state.location.request()
                Task { await state.loadNearbySites() }
            }
        }
    }

    var filtered: [RadarSite] {
        let sorted = state.sites.sorted { $0.milesFrom(state.userCoordinate) < $1.milesFrom(state.userCoordinate) }
        if search.isEmpty { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.displayID.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }
}

// MARK: - Models (Open-Meteo)

struct WeatherModel: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var apiID: String?   // nil = best match
    var blurb: String
}

let weatherModels: [WeatherModel] = [
    WeatherModel(name: "Best Match", apiID: nil, blurb: "Open-Meteo picks the best model for here"),
    WeatherModel(name: "HRRR", apiID: "gfs_hrrr", blurb: "US, 3 km, updates hourly, next 48 hours"),
    WeatherModel(name: "GFS", apiID: "gfs_global", blurb: "US global model, out to 16 days"),
    WeatherModel(name: "NAM", apiID: "ncep_nam_conus", blurb: "US regional model"),
    WeatherModel(name: "NBM", apiID: "ncep_nbm_conus", blurb: "US National Blend of Models"),
    WeatherModel(name: "ECMWF", apiID: "ecmwf_ifs025", blurb: "European model, often very good"),
    WeatherModel(name: "ICON", apiID: "icon_seamless", blurb: "German DWD model"),
    WeatherModel(name: "GEM", apiID: "gem_seamless", blurb: "Canadian model"),
]

struct OMResponse: Decodable {
    struct Hourly: Decodable {
        let time: [String]
        let temperature_2m: [Double?]?
        let precipitation: [Double?]?
        let precipitation_probability: [Double?]?
        let wind_speed_10m: [Double?]?
        let wind_gusts_10m: [Double?]?
    }
    let hourly: Hourly
}

struct HourRow: Identifiable {
    var id: String { time }
    var time: String
    var temp: Double?
    var rain: Double?
    var chance: Double?
    var wind: Double?
    var gust: Double?
}

struct ModelSummary: Identifiable {
    var id: String { modelName }
    var modelName: String
    var rain24: Double?
    var rain48: Double?
    var note: String
}

@MainActor
final class ModelsViewModel: ObservableObject {
    @Published var rows: [HourRow] = []
    @Published var summaries: [ModelSummary] = []
    @Published var message: String = ""
    @Published var loading: Bool = false

    func fetch(model: WeatherModel, at c: CLLocationCoordinate2D) async -> OMResponse? {
        var urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(c.latitude)&longitude=\(c.longitude)&hourly=temperature_2m,precipitation,precipitation_probability,wind_speed_10m,wind_gusts_10m&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch&timezone=auto&forecast_days=7"
        if let apiID = model.apiID { urlStr += "&models=\(apiID)" }
        guard let url = URL(string: urlStr) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(OMResponse.self, from: data)
        } catch {
            return nil
        }
    }

    func load(model: WeatherModel, at c: CLLocationCoordinate2D) async {
        loading = true
        defer { loading = false }
        guard let resp = await fetch(model: model, at: c) else {
            rows = []
            message = "\(model.name) gave no data here. Try Best Match or HRRR."
            return
        }
        message = ""
        rows = Self.makeRows(resp)
    }

    func compareAll(at c: CLLocationCoordinate2D) async {
        loading = true
        defer { loading = false }
        var out: [ModelSummary] = []
        for m in weatherModels {
            if let resp = await fetch(model: m, at: c) {
                let r = Self.makeRows(resp)
                let rain24 = r.prefix(24).compactMap { $0.rain }.reduce(0, +)
                let rain48 = r.prefix(48).compactMap { $0.rain }.reduce(0, +)
                out.append(ModelSummary(modelName: m.name, rain24: rain24, rain48: rain48, note: ""))
            } else {
                out.append(ModelSummary(modelName: m.name, rain24: nil, rain48: nil, note: "No data"))
            }
        }
        summaries = out
    }

    static func makeRows(_ resp: OMResponse) -> [HourRow] {
        let h = resp.hourly
        let nowFmt = DateFormatter()
        nowFmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let nowStr = nowFmt.string(from: Date())
        var start = 0
        if let idx = h.time.firstIndex(where: { $0 > nowStr }) { start = max(0, idx - 1) }
        var out: [HourRow] = []
        for i in start..<min(h.time.count, start + 48) {
            out.append(HourRow(
                time: h.time[i],
                temp: value(h.temperature_2m, i),
                rain: value(h.precipitation, i),
                chance: value(h.precipitation_probability, i),
                wind: value(h.wind_speed_10m, i),
                gust: value(h.wind_gusts_10m, i)
            ))
        }
        return out
    }

    static func value(_ arr: [Double?]?, _ i: Int) -> Double? {
        guard let arr = arr, arr.indices.contains(i) else { return nil }
        return arr[i]
    }
}

struct ModelsView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm = ModelsViewModel()
    @State private var model: WeatherModel = weatherModels[1]  // HRRR

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("Model", selection: $model) {
                        ForEach(weatherModels) { m in Text(m.name).tag(m) }
                    }
                    Text(model.blurb).font(.caption).foregroundColor(.secondary)
                    Text("Place: \(state.location.coordinate == nil ? "Orange City, FL" : "your location")")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Compare all models (rain totals)") {
                        Task { await vm.compareAll(at: state.userCoordinate) }
                    }
                }
                if !vm.summaries.isEmpty {
                    Section("Rain totals by model") {
                        ForEach(vm.summaries) { s in
                            HStack {
                                Text(s.modelName)
                                Spacer()
                                if let r24 = s.rain24, let r48 = s.rain48 {
                                    Text("24h \(String(format: "%.2f", r24))\"  48h \(String(format: "%.2f", r48))\"")
                                        .font(.caption)
                                } else {
                                    Text(s.note).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        Text("If models agree, rain is more likely. If they are far apart, nobody knows yet.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                if vm.loading { Section { Text("Loading…") } }
                if !vm.message.isEmpty {
                    Section { Text(vm.message).foregroundColor(.red).font(.caption) }
                }
                Section("Next 48 hours — \(model.name)") {
                    ForEach(vm.rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prettyTime(row.time)).font(.subheadline).bold()
                            Text(lineFor(row)).font(.caption)
                            if let rain = row.rain, rain > 0 {
                                GeometryReader { geo in
                                    Rectangle()
                                        .fill(Color.blue)
                                        .frame(width: max(4, min(geo.size.width, CGFloat(rain) * 300)), height: 6)
                                }
                                .frame(height: 6)
                            }
                        }
                    }
                }
                Section {
                    Text("Weather models: Open-Meteo (free, non-commercial). Rain in inches, wind in mph, temp in °F.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Models")
            .onAppear {
                state.location.request()
                Task { await vm.load(model: model, at: state.userCoordinate) }
            }
            .onChange(of: model) { m in
                Task { await vm.load(model: m, at: state.userCoordinate) }
            }
            .refreshable { await vm.load(model: model, at: state.userCoordinate) }
        }
    }

    func prettyTime(_ s: String) -> String {
        let p = DateFormatter()
        p.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let out = DateFormatter()
        out.dateFormat = "EEE h a"
        if let d = p.date(from: s) { return out.string(from: d) }
        return s
    }

    func lineFor(_ r: HourRow) -> String {
        var parts: [String] = []
        if let t = r.temp { parts.append("\(Int(t.rounded()))°F") }
        if let rain = r.rain { parts.append("rain \(String(format: "%.2f", rain))\"") }
        if let ch = r.chance { parts.append("\(Int(ch.rounded()))% chance") }
        if let w = r.wind { parts.append("wind \(Int(w.rounded())) mph") }
        if let g = r.gust { parts.append("gusts \(Int(g.rounded()))") }
        return parts.isEmpty ? "No data" : parts.joined(separator: "  •  ")
    }
}

// MARK: - Alerts (NWS)

struct AlertsResponse: Decodable {
    let features: [AlertFeature]
}

struct AlertFeature: Decodable, Identifiable {
    struct Properties: Decodable {
        let event: String?
        let headline: String?
        let description: String?
        let expires: String?
        let severity: String?
        let areaDesc: String?
    }
    let properties: Properties
    let geometry: AlertGeometry?
    var id: String { (properties.event ?? "alert") + (properties.expires ?? "") + (properties.areaDesc ?? "") }
}

struct AlertGeometry: Decodable {
    let type: String
    let polygons: [[CLLocationCoordinate2D]]

    enum CodingKeys: String, CodingKey { case type, coordinates }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        var polys: [[CLLocationCoordinate2D]] = []
        if let rings = try? c.decode([[[Double]]].self, forKey: .coordinates), let first = rings.first {
            polys.append(first.compactMap { pair in
                pair.count >= 2 ? CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0]) : nil
            })
        } else if let multi = try? c.decode([[[[Double]]]].self, forKey: .coordinates) {
            for poly in multi {
                if let first = poly.first {
                    polys.append(first.compactMap { pair in
                        pair.count >= 2 ? CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0]) : nil
                    })
                }
            }
        }
        polygons = polys
    }
}

@MainActor
final class AlertsViewModel: ObservableObject {
    @Published var alerts: [AlertFeature] = []
    @Published var message: String = ""
    @Published var loaded: Bool = false

    func load(at c: CLLocationCoordinate2D, state: AppState) async {
        let urlStr = "https://api.weather.gov/alerts/active?point=\(c.latitude),\(c.longitude)"
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url)
        req.setValue("WeatherFront/1.0 (personal app, Rob)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(AlertsResponse.self, from: data)
            alerts = resp.features
            state.alertPolygons = resp.features.flatMap { $0.geometry?.polygons ?? [] }
            message = ""
            loaded = true
        } catch {
            message = "Could not load alerts. Check internet and try again."
            loaded = true
        }
    }
}

struct AlertsView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm = AlertsViewModel()

    var body: some View {
        NavigationView {
            List {
                if !vm.message.isEmpty {
                    Text(vm.message).foregroundColor(.red).font(.caption)
                }
                if vm.loaded && vm.alerts.isEmpty {
                    Text("No active alerts for your location right now.")
                }
                ForEach(vm.alerts) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.properties.event ?? "Alert").bold()
                        if let h = a.properties.headline { Text(h).font(.caption) }
                        if let area = a.properties.areaDesc { Text(area).font(.caption).foregroundColor(.secondary) }
                        if let exp = a.properties.expires { Text("Ends: \(prettyExpiry(exp))").font(.caption).foregroundColor(.secondary) }
                        if let d = a.properties.description {
                            Text(String(d.prefix(500))).font(.caption)
                        }
                    }
                }
                Section {
                    Text("Alerts: National Weather Service. Warning areas also show in red on the Radar tab. This app is not a replacement for official warnings — keep Wireless Emergency Alerts on.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Alerts")
            .onAppear {
                state.location.request()
                Task { await vm.load(at: state.userCoordinate, state: state) }
            }
            .refreshable { await vm.load(at: state.userCoordinate, state: state) }
        }
    }

    func prettyExpiry(_ s: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        if let d = f.date(from: s) { return out.string(from: d) }
        return s
    }
}
