# Weather Front — RadarScope-like app for Rob (working name)

Asked Nov 25, 2026: "make an app like radarscope and weather front and has models like hrrr, gfs and all the other prediction models, prediction models for future rainfall, wind, temperature etc"

## Checked free data (Nov 25, 2026)
- Open-Meteo Forecast API: free, no key, non-commercial. Models via `models=` param:
  gfs_seamless (HRRR 0-48h ~3km + GFS after), gfs_hrrr / ncep_hrrr_conus (HRRR, CONUS, 48h),
  gfs_global / gfs025 (GFS, global, 16d), ncep_nam_conus (NAM), ncep_nbm_conus (NBM),
  ecmwf_ifs025 (ECMWF IFS, 15d), icon_seamless (DWD ICON), gem_seamless, jma_seamless, meteofrance_seamless.
  Variables hourly: temperature_2m, precipitation, rain, snowfall, precipitation_probability,
  wind_speed_10m, wind_gusts_10m, wind_direction_10m, pressure, humidity, dewpoint, CAPE (model dependent).
  Endpoint: https://api.open-meteo.com/v1/forecast?latitude=..&longitude=..&hourly=..&models=..
  Geocoding: https://geocoding-api.open-meteo.com/v1/search?name=..
- RainViewer Weather Maps API: free personal/educational, no key, attribution required.
  GET https://api.rainviewer.com/public/weather-maps.json -> host + radar.past frames (past 2h, 10-min steps).
  Tiles: {host}{path}/512/{z}/{x}/{y}/{color}/{options}.png  (max zoom 7 since Jan 1, 2026 transition;
  nowcast + most colour schemes discontinued Jan 1, 2026 — do not promise nowcast).
- NWS API: https://api.weather.gov free, User-Agent required. Alerts: /alerts/active?point=lat,lon or ?area=FL
  Point forecast via /points/{lat},{lon} then gridpoints forecast/forecastHourly.

## Honest limits for V1
- RadarScope-level NEXRAD velocity / dual-pol / storm tracks: NOT in V1. V1 radar = RainViewer reflectivity tiles on a map, animated past 2h.
- Full model MAPS (coloured GRIB maps moving over the US): NOT in V1 — that needs a tile server rendering GRIB.
  V1 models = per-location charts + tables comparing each model hour-by-hour (temp / rain / wind / gusts).
  This answers "how much rain / how hot / how windy, and do models agree?" for a town.
- ECMWF via Open-Meteo is IFS 0.25° free tier, not full paid ECMWF.

## Proposed V1 (same IPA build path as Simple Cut / TPP)
Tabs:
1. Radar — MapKit map (GPS or Orange City, FL default), RainViewer tiles, play/pause + time slider, attribution.
2. Models — location picker (search + GPS + saved places), model picker/compare: HRRR, GFS, NAM, NBM, ECMWF, ICON.
   Hourly charts/tables: temperature, rainfall (in), rain chance, wind + gusts (mph), for 48h and 7d.
   Show model disagreement plainly (e.g. HRRR 0.8in vs GFS 0.2in tomorrow).
3. Forecast — current, hourly, daily (Open-Meteo best_match, Fahrenheit / mph / inches).
4. Alerts — NWS active alerts for the location, plain headline + expiry.

No account, no API key, no ads. SwiftUI + MapKit + Charts, iOS 16+.
Build: GitHub Actions Mac runner -> unsigned .ipa -> iloader sideload. Repo: trailerparkproductions/weather-front-ios (to create).

## Open choice for Rob
- V1 as above (radar map + model charts per town), or model MAPS first (much bigger, needs server)?
- Default place Orange City only, or saved places (race tracks too)?

## Velocity + storm track — checked Nov 25, 2026 (Rob asked)
- Velocity is NOT in RainViewer (reflectivity only). Velocity comes from single NEXRAD sites.
  IEM GIS RADAR: single-site Level 3 images, EPSG:4326 PNG + world file + JSON, archive from 2012,
  products: N0U Base Velocity, N0S Storm Relative Base Velocity, TV0 TDWR Base Velocity.
  IEM mosaics are base reflectivity only, NOT velocity (velocity cannot be mosaicked nationally).
  Service is as-is, not for thousands of simultaneous users — fine for Rob's personal sideload app.
- NOAA NEXRAD on AWS (open, no account): Level II archive unidata-nexrad-level2,
  Level II real-time unidata-nexrad-level2-chunks, Level III unidata-nexrad-level3.
  Level III codes: N?G Base velocity super-res, N?S Storm-relative velocity,
  NST Storm tracking information, NMD Mesocyclone detection, N?C Correlation coefficient.
  Level III overlay products include storm tracking, mesocyclone, TVS, hail index.
- IEM Level3 Attributes placefile (text): storm cell attributes, TVS flag, hail probability,
  filterable by radar (e.g. ?nexrad=MLB). Parseable on phone.
- Nearest radars for Orange City, FL: KMLB Melbourne (main, covers Orlando/Daytona area),
  KTBW Tampa Bay, KJAX Jacksonville. Velocity range ~230km from the radar site.

### Plan
- V1 velocity: pick radar site (auto-nearest + manual MLB/TBW/JAX), show latest IEM N0U + N0S
  images as map overlays, animate last frames, refresh each volume scan (~4-6 min precip mode).
  Green = toward radar, red = away (standard velocity colours, with legend + plain words).
- V1 storm track (easy, honest): NWS warning polygons on the map + storm motion arrow/text from
  the warning, plus IEM L3 attributes list per cell (hail %, TVS flag). Label it "warning track",
  not full cell-track cones.
- V2 storm track (hard): parse NST Level 3 files from AWS S3 in Swift, draw past + forecast cell
  track lines/cones. Needs a Level 3 decoder — separate build, test with real storm data first.

## Radar sites picker — checked Nov 25, 2026 (Rob asked: "access radar sites like Melbourne radar kmlb")
- WSR-88D list: 158 sites (NWS list updated Aug 18, 2026). App will ship a site list (name, ID, lat/lon, state)
  with search + nearest-to-GPS + favourites. Tap a site = single-site mode for that radar only.
- Florida sites: KMLB Melbourne (28.1133, -80.6542), KTBW Tampa/Ruskin (27.705, -82.402),
  KJAX Jacksonville (30.485, -81.702), KAMX Miami (25.611, -80.413), KTLH Tallahassee (30.398, -84.329),
  KBYX Key West (24.597, -81.703), KEVX Eglin AFB (30.565, -85.922).
  Default for Orange City: KMLB, backups KTBW / KJAX (also the alternates NWS lists when KMLB is down).
- IEM ridge data is organised one folder per radar site (3-char ID, e.g. MLB), product sub-folders
  (N0B reflectivity, N0U velocity, N0S storm-relative velocity, NET echo tops), each image with world file + JSON.
  App fetches the chosen site/product/time, draws it on the map at the right place, shows site name + time + product.
- Single-site screen: product picker (Reflectivity / Velocity / Storm-Relative Velocity / Echo Tops),
  play last frames, range rings, "radar is X miles from you", last scan time, clear "no data / radar down" state.

## Current location + closest radar — checked Nov 25, 2026 (Rob asked)
- iOS: NSLocationWhenInUseUsageDescription in Info.plist (plain words: "Weather Front uses your location
  to show you on the radar and pick the closest radar. Location stays on your phone except the lat/lon
  sent to weather data services to get your forecast."), CLLocationManager.requestWhenInUseAuthorization(),
  MapKit showsUserLocation / UserAnnotation blue dot. When-in-use only, no background tracking.
- Flow: first open -> ask permission -> blue dot on radar map -> compute distance to every bundled
  WSR-88D site (haversine) -> auto-pick closest -> show "Closest radar: KMLB Melbourne, 69 miles away"
  (example from Orange City 28.93472,-81.28806: KMLB 68.6 mi, KTBW 108.7 mi, KJAX 109.9 mi (computed from Orange City centre) — verify in app with live GPS).
  Buttons: "Use closest radar" / "Pick myself". If location denied/off: default Orange City + KMLB, manual pick still works.
- If closest radar has no fresh data / is down: try next closest, say so plainly. Re-check closest when user taps
  "Find me" or moves a long way — do not silently switch radar mid-storm without telling Rob.
- Privacy: no account, no location history stored/sent to us. Lat/lon only goes to Open-Meteo / NWS / IEM / RainViewer
  as needed for that forecast/radar request, same as any weather app.
