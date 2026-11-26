# Weather Front

Personal radar + weather models app for Rob. Sideload with iloader (signs with your Apple ID, refresh every 7 days).

Tabs:
- Radar: US radar map (RainViewer) + single-site radar (IEM NEXRAD tiles) with reflectivity and velocity, animated. Blue dot = you. Red shapes = NWS warning areas.
- Sites: pick a radar site like KMLB Melbourne, or tap "Use closest radar".
- Models: HRRR, GFS, NAM, NBM, ECMWF, ICON, GEM — next 48 hours of temp, rain, rain chance, wind and gusts, plus rain totals compared across models.
- Alerts: National Weather Service active alerts for your location.

Data sources (free, no key): RainViewer Weather Maps API, Iowa Environmental Mesonet single-site radar tiles, Open-Meteo forecast API, NWS api.weather.gov.

Build: GitHub Actions (macOS) builds an unsigned .ipa. See .github/workflows/build-ipa.yml.
