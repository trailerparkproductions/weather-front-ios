import SwiftUI
import MapKit
import CoreLocation
import Combine

// Weather Front — personal radar + models app for Rob.
// Data: RainViewer (US radar tiles), IEM single-site radar tiles (reflectivity + velocity),
// Open-Meteo (HRRR/GFS/NAM/NBM/ECMWF/ICON/GEM/JMA/Meteo-France models + forecast + place search),
// NWS api.weather.gov (alerts).
// No account, no API key, no ads.

let orangeCity = CLLocationCoordinate2D(latitude: 28.93472, longitude: -81.28806)

@main
struct WeatherFrontApp: App {
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup {
            TabView {
                ForecastView().tabItem { Label("Forecast", systemImage: "sun.max") }
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
    @Published var placeName: String = "Orange City, FL"
    @Published var placeLat: Double = 28.93472
    @Published var placeLon: Double = -81.28806
    @Published var placeToken: Int = 0
    let location = LocationManager()
    private var pendingGPS: Bool = false
    private var cancellables: Set<AnyCancellable> = []

    init() {
        location.$coordinate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] coord in
                guard let self = self, let coord = coord, self.pendingGPS else { return }
                self.pendingGPS = false
                self.setPlace(name: "Your location", lat: coord.latitude, lon: coord.longitude)
            }
            .store(in: &cancellables)
    }

    var userCoordinate: CLLocationCoordinate2D { location.coordinate ?? orangeCity }
    var forecastCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: placeLat, longitude: placeLon) }

    func setPlace(name: String, lat: Double, lon: Double) {
        placeName = name
        placeLat = lat
        placeLon = lon
        placeToken += 1
    }

    func useMyLocation() {
        pendingGPS = true
        location.request()
        if let c = location.coordinate {
            pendingGPS = false
            setPlace(name: "Your location", lat: c.latitude, lon: c.longitude)
        }
    }

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

    func loadRainViewer(center: CLLocationCoordinate2D = orangeCity) async {
        guard let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let resp = try JSONDecoder().decode(RainViewerResponse.self, from: data)
            rainHost = resp.host
            rainFrames = resp.radar.past
            frameIndex = max(0, rainFrames.count - 1)
            prefetchRainTiles(center: center)
        } catch {
            message = "Could not load US radar. Check internet."
        }
    }

    // Warm the tile cache for every animation frame so Play looks smooth.
    func prefetchRainTiles(center: CLLocationCoordinate2D) {
        let (x, y) = Self.tileXY(lat: center.latitude, lon: center.longitude, zoom: 6)
        for frame in rainFrames {
            let urlStr = "\(rainHost)\(frame.path)/512/6/\(x)/\(y)/2/1_1.png"
            if let u = URL(string: urlStr) {
                URLSession.shared.dataTask(with: u) { _, _, _ in }.resume()
            }
        }
    }

    func prefetchSiteTiles(site: RadarSite, product: RadarProduct) {
        let (x, y) = Self.tileXY(lat: site.lat, lon: site.lon, zoom: 7)
        for stampRaw in scans {
            let stamp = stampRaw.replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "T", with: "")
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "Z", with: "")
            let urlStr = "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/ridge::\(site.id)-\(product.id)-\(stamp)/7/\(x)/\(y).png"
            if let u = URL(string: urlStr) {
                URLSession.shared.dataTask(with: u) { _, _, _ in }.resume()
            }
        }
    }

    static func tileXY(lat: Double, lon: Double, zoom: Int) -> (Int, Int) {
        let n = pow(2.0, Double(zoom))
        let x = Int(floor((lon + 180.0) / 360.0 * n))
        let latRad = lat * Double.pi / 180.0
        let y = Int(floor((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / Double.pi) / 2.0 * n))
        return (max(0, x), max(0, y))
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
            prefetchSiteTiles(site: site, product: product)
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
    private let timer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

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

                if frameCount > 1 {
                    Slider(value: Binding(get: { Double(vm.frameIndex) }, set: { vm.frameIndex = Int($0) }),
                           in: 0...Double(frameCount - 1), step: 1)
                        .padding(.horizontal)
                }

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
            .onChange(of: state.placeToken) { _ in
                mapCenter = state.forecastCoordinate
                centerToken += 1
                Task { await reload() }
            }
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

    var frameCount: Int { siteMode ? vm.scans.count : vm.rainFrames.count }

    func closestText() -> String {
        let c = state.userCoordinate
        guard let best = state.sites.filter({ $0.type == "NEXRAD" }).min(by: { $0.milesFrom(c) < $1.milesFrom(c) }) else { return "" }
        return "\(best.displayID) \(best.name), \(Int(best.milesFrom(c).rounded())) miles away"
    }

    func reload() async {
        if siteMode {
            await vm.loadScans(site: state.selectedSite, product: product)
        } else {
            await vm.loadRainViewer(center: state.forecastCoordinate)
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

// MARK: - Place search (Open-Meteo geocoding)

struct GeoResponse: Decodable {
    struct Result: Decodable, Identifiable {
        let id: Int
        let name: String
        let latitude: Double
        let longitude: Double
        let admin1: String?
        let country: String?
        var label: String {
            var parts = [name]
            if let a = admin1, !a.isEmpty { parts.append(a) }
            if let c = country, !c.isEmpty { parts.append(c) }
            return parts.joined(separator: ", ")
        }
    }
    let results: [Result]?
}

struct PlaceSearchView: View {
    @EnvironmentObject var state: AppState
    @State private var query: String = ""
    @State private var results: [GeoResponse.Result] = []
    @State private var message: String = ""
    @State private var searching: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Place: \(state.placeName)").font(.subheadline).bold()
            HStack {
                TextField("Search city or town", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                Button("Search") { Task { await search() } }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            Button("Use my location") { state.useMyLocation() }
            if searching { Text("Searching…").font(.caption).foregroundColor(.secondary) }
            if !message.isEmpty { Text(message).font(.caption).foregroundColor(.red) }
            ForEach(results) { r in
                Button {
                    state.setPlace(name: r.label, lat: r.latitude, lon: r.longitude)
                    results = []
                    query = ""
                } label: {
                    HStack {
                        Image(systemName: "mappin.circle")
                        Text(r.label).foregroundColor(.primary)
                        Spacer()
                    }
                }
            }
        }
    }

    func search() async {
        searching = true
        defer { searching = false }
        message = ""
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(encoded)&count=8&language=en&format=json") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let resp = try JSONDecoder().decode(GeoResponse.self, from: data)
            results = resp.results ?? []
            if results.isEmpty { message = "No places found. Try a bigger town name." }
        } catch {
            message = "Place search failed. Check internet."
        }
    }
}

// MARK: - Open-Meteo shared decoding

struct OMResponse: Decodable {
    struct Current: Decodable {
        let time: String?
        let temperature_2m: Double?
        let apparent_temperature: Double?
        let relative_humidity_2m: Double?
        let pressure_msl: Double?
        let wind_speed_10m: Double?
        let wind_gusts_10m: Double?
        let wind_direction_10m: Double?
        let precipitation: Double?
        let weather_code: Int?
    }
    struct Hourly: Decodable {
        let time: [String]
        let temperature_2m: [Double?]?
        let apparent_temperature: [Double?]?
        let precipitation: [Double?]?
        let precipitation_probability: [Double?]?
        let wind_speed_10m: [Double?]?
        let wind_gusts_10m: [Double?]?
        let wind_direction_10m: [Double?]?
        let uv_index: [Double?]?
        let relative_humidity_2m: [Double?]?
    }
    struct Daily: Decodable {
        let time: [String]
        let temperature_2m_max: [Double?]?
        let temperature_2m_min: [Double?]?
        let precipitation_sum: [Double?]?
        let precipitation_probability_max: [Double?]?
        let wind_speed_10m_max: [Double?]?
        let wind_gusts_10m_max: [Double?]?
        let uv_index_max: [Double?]?
    }
    let current: Current?
    let hourly: Hourly?
    let daily: Daily?
}

struct HourRow: Identifiable {
    var id: String { time }
    var time: String
    var temp: Double?
    var feels: Double?
    var rain: Double?
    var chance: Double?
    var wind: Double?
    var gust: Double?
    var windDir: Double?
    var uv: Double?
}

struct DayRow: Identifiable {
    var id: String { date }
    var date: String
    var high: Double?
    var low: Double?
    var rainTotal: Double?
    var rainChance: Double?
    var windMax: Double?
    var gustMax: Double?
    var uvMax: Double?
}

func omValue(_ arr: [Double?]?, _ i: Int) -> Double? {
    guard let arr = arr, arr.indices.contains(i) else { return nil }
    return arr[i]
}

func omHourRows(_ resp: OMResponse, limit: Int) -> [HourRow] {
    guard let h = resp.hourly else { return [] }
    let nowFmt = DateFormatter()
    nowFmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
    let nowStr = nowFmt.string(from: Date())
    var start = 0
    if let idx = h.time.firstIndex(where: { $0 > nowStr }) { start = max(0, idx - 1) }
    var out: [HourRow] = []
    for i in start..<min(h.time.count, start + limit) {
        out.append(HourRow(
            time: h.time[i],
            temp: omValue(h.temperature_2m, i),
            feels: omValue(h.apparent_temperature, i),
            rain: omValue(h.precipitation, i),
            chance: omValue(h.precipitation_probability, i),
            wind: omValue(h.wind_speed_10m, i),
            gust: omValue(h.wind_gusts_10m, i),
            windDir: omValue(h.wind_direction_10m, i),
            uv: omValue(h.uv_index, i)
        ))
    }
    return out
}

func omDayRows(_ resp: OMResponse, limit: Int) -> [DayRow] {
    guard let d = resp.daily else { return [] }
    var out: [DayRow] = []
    for i in 0..<min(d.time.count, limit) {
        out.append(DayRow(
            date: d.time[i],
            high: omValue(d.temperature_2m_max, i),
            low: omValue(d.temperature_2m_min, i),
            rainTotal: omValue(d.precipitation_sum, i),
            rainChance: omValue(d.precipitation_probability_max, i),
            windMax: omValue(d.wind_speed_10m_max, i),
            gustMax: omValue(d.wind_gusts_10m_max, i),
            uvMax: omValue(d.uv_index_max, i)
        ))
    }
    return out
}

func compassText(_ deg: Double?) -> String {
    guard let deg = deg else { return "" }
    let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    let idx = Int((deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 45.0 + 0.5) % 8
    return dirs[idx]
}

func weatherCodeText(_ code: Int?) -> String {
    guard let code = code else { return "" }
    switch code {
    case 0: return "Clear sky"
    case 1, 2, 3: return "Partly cloudy to cloudy"
    case 45, 48: return "Fog"
    case 51, 53, 55: return "Drizzle"
    case 61, 63, 65: return "Rain"
    case 66, 67: return "Freezing rain"
    case 71, 73, 75, 77: return "Snow"
    case 80, 81, 82: return "Rain showers"
    case 85, 86: return "Snow showers"
    case 95: return "Thunderstorm"
    case 96, 99: return "Thunderstorm with hail"
    default: return "Weather code \(code)"
    }
}

func prettyHourTime(_ s: String) -> String {
    let p = DateFormatter()
    p.dateFormat = "yyyy-MM-dd'T'HH:mm"
    let out = DateFormatter()
    out.dateFormat = "EEE h a"
    if let d = p.date(from: s) { return out.string(from: d) }
    return s
}

func prettyDayDate(_ s: String) -> String {
    let p = DateFormatter()
    p.dateFormat = "yyyy-MM-dd"
    let out = DateFormatter()
    out.dateFormat = "EEE MMM d"
    if let d = p.date(from: s) { return out.string(from: d) }
    return s
}

// MARK: - Forecast tab

@MainActor
final class ForecastViewModel: ObservableObject {
    @Published var current: OMResponse.Current? = nil
    @Published var uvNow: Double? = nil
    @Published var hourly: [HourRow] = []
    @Published var daily: [DayRow] = []
    @Published var message: String = ""
    @Published var loading: Bool = false

    func load(at c: CLLocationCoordinate2D) async {
        loading = true
        defer { loading = false }
        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(c.latitude)&longitude=\(c.longitude)&current=temperature_2m,apparent_temperature,relative_humidity_2m,pressure_msl,wind_speed_10m,wind_gusts_10m,wind_direction_10m,precipitation,weather_code&hourly=temperature_2m,apparent_temperature,precipitation,precipitation_probability,wind_speed_10m,wind_gusts_10m,wind_direction_10m,uv_index,relative_humidity_2m&daily=temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,wind_speed_10m_max,wind_gusts_10m_max,uv_index_max&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch&timezone=auto&forecast_days=16"
        guard let url = URL(string: urlStr) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let resp = try JSONDecoder().decode(OMResponse.self, from: data)
            current = resp.current
            hourly = omHourRows(resp, limit: 240)
            daily = omDayRows(resp, limit: 10)
            uvNow = hourly.first?.uv
            message = ""
        } catch {
            message = "Could not load forecast. Check internet and pull down to try again."
        }
    }
}

struct ForecastView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm = ForecastViewModel()

    var body: some View {
        NavigationView {
            List {
                Section { PlaceSearchView() }
                if vm.loading { Section { Text("Loading…") } }
                if !vm.message.isEmpty {
                    Section { Text(vm.message).foregroundColor(.red).font(.caption) }
                }
                if let cur = vm.current {
                    Section("Now — \(state.placeName)") {
                        if let t = cur.temperature_2m {
                            Text("\(Int(t.rounded()))°F").font(.largeTitle).bold()
                        }
                        let sky = weatherCodeText(cur.weather_code)
                        if !sky.isEmpty { Text(sky) }
                        if let f = cur.apparent_temperature { Text("Feels like \(Int(f.rounded()))°F") }
                        if let today = vm.daily.first, let hi = today.high, let lo = today.low {
                            Text("Today: high \(Int(hi.rounded()))°F, low \(Int(lo.rounded()))°F")
                        }
                        if let w = cur.wind_speed_10m {
                            Text("Wind \(Int(w.rounded())) mph \(compassText(cur.wind_direction_10m))" + (cur.wind_gusts_10m.map { ", gusts \(Int($0.rounded())) mph" } ?? ""))
                        }
                        if let uv = vm.uvNow { Text("UV index now: \(String(format: "%.1f", uv))") }
                        if let today = vm.daily.first, let uvMax = today.uvMax { Text("UV high today: \(String(format: "%.1f", uvMax))") }
                        if let h = cur.relative_humidity_2m { Text("Humidity \(Int(h.rounded()))%") }
                        if let p = cur.pressure_msl { Text("Pressure \(String(format: "%.1f", p)) hPa") }
                    }
                }
                if !vm.hourly.isEmpty {
                    Section("Hour by hour — next 10 days") {
                        ForEach(vm.hourly) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prettyHourTime(row.time)).font(.subheadline).bold()
                                Text(hourLine(row)).font(.caption)
                            }
                        }
                    }
                }
                if !vm.daily.isEmpty {
                    Section("10-day forecast") {
                        ForEach(vm.daily) { day in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prettyDayDate(day.date)).font(.subheadline).bold()
                                Text(dayLine(day)).font(.caption)
                            }
                        }
                    }
                }
                Section {
                    Text("Forecast: Open-Meteo (free, non-commercial). Temp in °F, wind in mph, rain in inches. Free models go to 16 days — see the Models tab.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Forecast")
            .onAppear {
                state.location.request()
                Task { await vm.load(at: state.forecastCoordinate) }
            }
            .onChange(of: state.placeToken) { _ in
                Task { await vm.load(at: state.forecastCoordinate) }
            }
            .refreshable { await vm.load(at: state.forecastCoordinate) }
        }
    }

    func hourLine(_ r: HourRow) -> String {
        var parts: [String] = []
        if let t = r.temp { parts.append("\(Int(t.rounded()))°F") }
        if let f = r.feels { parts.append("feels \(Int(f.rounded()))°") }
        if let rain = r.rain { parts.append("rain \(String(format: "%.2f", rain))\"") }
        if let ch = r.chance { parts.append("\(Int(ch.rounded()))% chance") }
        if let w = r.wind { parts.append("wind \(Int(w.rounded())) mph \(compassText(r.windDir))") }
        if let g = r.gust { parts.append("gusts \(Int(g.rounded()))") }
        if let uv = r.uv { parts.append("UV \(String(format: "%.1f", uv))") }
        return parts.isEmpty ? "No data" : parts.joined(separator: "  •  ")
    }

    func dayLine(_ d: DayRow) -> String {
        var parts: [String] = []
        if let hi = d.high, let lo = d.low { parts.append("High \(Int(hi.rounded()))°F / Low \(Int(lo.rounded()))°F") }
        if let rain = d.rainTotal { parts.append("rain \(String(format: "%.2f", rain))\"") }
        if let ch = d.rainChance { parts.append("\(Int(ch.rounded()))% chance") }
        if let w = d.windMax { parts.append("wind up to \(Int(w.rounded())) mph") }
        if let g = d.gustMax { parts.append("gusts \(Int(g.rounded()))") }
        if let uv = d.uvMax { parts.append("UV high \(String(format: "%.1f", uv))") }
        return parts.isEmpty ? "No data" : parts.joined(separator: "  •  ")
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
    WeatherModel(name: "JMA", apiID: "jma_seamless", blurb: "Japanese model"),
    WeatherModel(name: "Météo-France", apiID: "meteofrance_seamless", blurb: "French model"),
]

struct ModelSummary: Identifiable {
    var id: String { modelName }
    var modelName: String
    var rain24: Double?
    var rain48: Double?
    var rain7d: Double?
    var note: String
}

@MainActor
final class ModelsViewModel: ObservableObject {
    @Published var rowsByModel: [String: [HourRow]] = [:]
    @Published var daysByModel: [String: [DayRow]] = [:]
    @Published var averageRows: [HourRow] = []
    @Published var averageDays: [DayRow] = []
    @Published var summaries: [ModelSummary] = []
    @Published var message: String = ""
    @Published var loading: Bool = false
    @Published var loaded: Bool = false

    func fetch(model: WeatherModel, at c: CLLocationCoordinate2D) async -> OMResponse? {
        var urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(c.latitude)&longitude=\(c.longitude)&hourly=temperature_2m,precipitation,precipitation_probability,wind_speed_10m,wind_gusts_10m,uv_index&daily=temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,wind_speed_10m_max,wind_gusts_10m_max,uv_index_max&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch&timezone=auto&forecast_days=16"
        if let apiID = model.apiID { urlStr += "&models=\(apiID)" }
        guard let url = URL(string: urlStr) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(OMResponse.self, from: data)
        } catch {
            return nil
        }
    }

    func loadAll(at c: CLLocationCoordinate2D) async {
        loading = true
        defer { loading = false }
        var newRows: [String: [HourRow]] = [:]
        var newDays: [String: [DayRow]] = [:]
        var newSummaries: [ModelSummary] = []
        for m in weatherModels {
            if let resp = await fetch(model: m, at: c) {
                let rows = omHourRows(resp, limit: 384)
                let hasData = rows.contains { $0.temp != nil }
                newRows[m.name] = rows
                newDays[m.name] = omDayRows(resp, limit: 16)
                if hasData {
                    newSummaries.append(ModelSummary(
                        modelName: m.name,
                        rain24: rows.prefix(24).compactMap { $0.rain }.reduce(0, +),
                        rain48: rows.prefix(48).compactMap { $0.rain }.reduce(0, +),
                        rain7d: rows.prefix(168).compactMap { $0.rain }.reduce(0, +),
                        note: ""))
                } else {
                    newSummaries.append(ModelSummary(modelName: m.name, rain24: nil, rain48: nil, rain7d: nil, note: "No data"))
                }
            } else {
                newRows[m.name] = []
                newDays[m.name] = []
                newSummaries.append(ModelSummary(modelName: m.name, rain24: nil, rain48: nil, rain7d: nil, note: "No data"))
            }
        }
        rowsByModel = newRows
        daysByModel = newDays
        summaries = newSummaries
        averageRows = Self.averageHours(Array(newRows.values))
        averageDays = Self.averageDays(Array(newDays.values))
        if !averageRows.isEmpty {
            let avg = averageRows
            summaries.append(ModelSummary(
                modelName: "Average of models",
                rain24: avg.prefix(24).compactMap { $0.rain }.reduce(0, +),
                rain48: avg.prefix(48).compactMap { $0.rain }.reduce(0, +),
                rain7d: avg.prefix(168).compactMap { $0.rain }.reduce(0, +),
                note: ""))
        }
        loaded = true
        message = averageRows.isEmpty ? "No model data here right now. Check internet and pull down to try again." : ""
    }

    static func avg(_ values: [Double?]) -> Double? {
        let v = values.compactMap { $0 }
        guard !v.isEmpty else { return nil }
        return v.reduce(0, +) / Double(v.count)
    }

    static func averageHours(_ allRows: [[HourRow]]) -> [HourRow] {
        var byTime: [String: [HourRow]] = [:]
        for rows in allRows {
            for r in rows { byTime[r.time, default: []].append(r) }
        }
        return byTime.keys.sorted().map { t in
            let rs = byTime[t] ?? []
            return HourRow(
                time: t,
                temp: avg(rs.map { $0.temp }),
                feels: avg(rs.map { $0.feels }),
                rain: avg(rs.map { $0.rain }),
                chance: avg(rs.map { $0.chance }),
                wind: avg(rs.map { $0.wind }),
                gust: avg(rs.map { $0.gust }),
                windDir: nil,
                uv: avg(rs.map { $0.uv }))
        }
    }

    static func averageDays(_ allDays: [[DayRow]]) -> [DayRow] {
        var byDate: [String: [DayRow]] = [:]
        for days in allDays {
            for d in days { byDate[d.date, default: []].append(d) }
        }
        return byDate.keys.sorted().map { date in
            let ds = byDate[date] ?? []
            return DayRow(
                date: date,
                high: avg(ds.map { $0.high }),
                low: avg(ds.map { $0.low }),
                rainTotal: avg(ds.map { $0.rainTotal }),
                rainChance: avg(ds.map { $0.rainChance }),
                windMax: avg(ds.map { $0.windMax }),
                gustMax: avg(ds.map { $0.gustMax }),
                uvMax: avg(ds.map { $0.uvMax }))
        }
    }
}

struct PlacePin: Identifiable {
    var id: String { name }
    var name: String
    var coordinate: CLLocationCoordinate2D
}

struct ModelsView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm = ModelsViewModel()
    @State private var model: WeatherModel = weatherModels[1]  // HRRR
    @State private var showAverage: Bool = false
    @State private var mapHour: Double = 0
    @State private var mapRegion: MKCoordinateRegion = MKCoordinateRegion(center: orangeCity, span: MKCoordinateSpan(latitudeDelta: 3, longitudeDelta: 3))

    var selectedRows: [HourRow] {
        showAverage ? vm.averageRows : (vm.rowsByModel[model.name] ?? [])
    }
    var selectedDays: [DayRow] {
        showAverage ? vm.averageDays : (vm.daysByModel[model.name] ?? [])
    }
    var selectedName: String { showAverage ? "Average of models" : model.name }

    var body: some View {
        NavigationView {
            List {
                Section { PlaceSearchView() }
                Section {
                    Picker("Model", selection: $model) {
                        ForEach(weatherModels) { m in Text(m.name).tag(m) }
                    }
                    .onChange(of: model) { _ in showAverage = false }
                    Toggle("Show average of models instead", isOn: $showAverage)
                    Text(showAverage ? "Simple average of every model that has data for that hour. Models with no data are left out." : model.blurb)
                        .font(.caption).foregroundColor(.secondary)
                    Text("Models go to 16 days. 4 weeks is not available free.")
                        .font(.caption).bold()
                    Button("Load all models") {
                        Task { await vm.loadAll(at: state.forecastCoordinate) }
                    }
                }
                if vm.loading { Section { Text("Loading models…") } }
                if !vm.message.isEmpty {
                    Section { Text(vm.message).foregroundColor(.red).font(.caption) }
                }
                if !vm.summaries.isEmpty {
                    Section("Rain totals by model") {
                        ForEach(vm.summaries) { s in
                            HStack {
                                Text(s.modelName).fontWeight(s.modelName == "Average of models" ? .bold : .regular)
                                Spacer()
                                if let r24 = s.rain24, let r48 = s.rain48, let r7 = s.rain7d {
                                    Text("24h \(String(format: "%.2f", r24))\"  48h \(String(format: "%.2f", r48))\"  7d \(String(format: "%.2f", r7))\"")
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
                if vm.loaded {
                    Section("Model map — \(selectedName)") {
                        Map(coordinateRegion: $mapRegion, annotationItems: [PlacePin(name: state.placeName, coordinate: state.forecastCoordinate)]) { pin in
                            MapAnnotation(coordinate: pin.coordinate) {
                                VStack(spacing: 2) {
                                    Image(systemName: "mappin.circle.fill").foregroundColor(.red)
                                    Text(pin.name).font(.caption2).bold()
                                }
                            }
                        }
                        .frame(height: 220)
                        if selectedRows.count > 1 {
                            Slider(value: $mapHour, in: 0...Double(min(selectedRows.count, 168) - 1), step: 1)
                            let row = selectedRows[min(Int(mapHour), selectedRows.count - 1)]
                            Text("\(prettyHourTime(row.time)) — \(lineFor(row))").font(.caption)
                        } else {
                            Text("No hourly data for this model here.").font(.caption).foregroundColor(.secondary)
                        }
                        Text("Simple model map: it shows the model numbers at your place. It is not a full colour weather map — that needs a map server.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Section("Next 72 hours — \(selectedName)") {
                        ForEach(Array(selectedRows.prefix(72))) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prettyHourTime(row.time)).font(.subheadline).bold()
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
                    Section("Day by day to 16 days — \(selectedName)") {
                        ForEach(selectedDays) { day in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prettyDayDate(day.date)).font(.subheadline).bold()
                                Text(dayLine(day)).font(.caption)
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
                mapRegion = MKCoordinateRegion(center: state.forecastCoordinate, span: MKCoordinateSpan(latitudeDelta: 3, longitudeDelta: 3))
                Task { await vm.loadAll(at: state.forecastCoordinate) }
            }
            .onChange(of: state.placeToken) { _ in
                mapHour = 0
                mapRegion = MKCoordinateRegion(center: state.forecastCoordinate, span: MKCoordinateSpan(latitudeDelta: 3, longitudeDelta: 3))
                Task { await vm.loadAll(at: state.forecastCoordinate) }
            }
            .refreshable { await vm.loadAll(at: state.forecastCoordinate) }
        }
    }

    func lineFor(_ r: HourRow) -> String {
        var parts: [String] = []
        if let t = r.temp { parts.append("\(Int(t.rounded()))°F") }
        if let rain = r.rain { parts.append("rain \(String(format: "%.2f", rain))\"") }
        if let ch = r.chance { parts.append("\(Int(ch.rounded()))% chance") }
        if let w = r.wind { parts.append("wind \(Int(w.rounded())) mph") }
        if let g = r.gust { parts.append("gusts \(Int(g.rounded()))") }
        if let uv = r.uv { parts.append("UV \(String(format: "%.1f", uv))") }
        return parts.isEmpty ? "No data" : parts.joined(separator: "  •  ")
    }

    func dayLine(_ d: DayRow) -> String {
        var parts: [String] = []
        if let hi = d.high, let lo = d.low { parts.append("High \(Int(hi.rounded()))°F / Low \(Int(lo.rounded()))°F") }
        if let rain = d.rainTotal { parts.append("rain \(String(format: "%.2f", rain))\"") }
        if let ch = d.rainChance { parts.append("\(Int(ch.rounded()))% chance") }
        if let w = d.windMax { parts.append("wind up to \(Int(w.rounded())) mph") }
        if let g = d.gustMax { parts.append("gusts \(Int(g.rounded()))") }
        if let uv = d.uvMax { parts.append("UV high \(String(format: "%.1f", uv))") }
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
            .onChange(of: state.placeToken) { _ in
                Task { await vm.load(at: state.forecastCoordinate, state: state) }
            }
            .onAppear {
                state.location.request()
                Task { await vm.load(at: state.forecastCoordinate, state: state) }
            }
            .refreshable { await vm.load(at: state.forecastCoordinate, state: state) }
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
