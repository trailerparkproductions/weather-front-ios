# Weather Front

Personal radar + weather models app for Rob. Sideload with iloader (signs with your Apple ID, refresh every 7 days).

Tabs (v2, Nov 26, 2026):
- Forecast: current weather (temp, feels like, wind + gusts + direction, UV now and UV high, humidity, pressure, today's high/low), hour-by-hour for the next 10 days, and a 10-day forecast. Search a city/town or tap "Use my location".
- Radar: US radar map (RainViewer) + single-site radar (IEM NEXRAD tiles) with reflectivity and velocity, animated. Play/pause and a time slider. Animation frames are prefetched so Play runs smoother. Blue dot = you. Red shapes = NWS warning areas.
- Sites: pick a radar site like KMLB Melbourne, or tap "Use closest radar".
- Models: HRRR, GFS, NAM, NBM, ECMWF, ICON, GEM, JMA, Météo-France, plus Best Match and an "Average of models" view. Next 72 hours hour-by-hour, day-by-day out to 16 days, rain totals compared across models, and a simple model map (map + time slider showing the model numbers at your place — not a full colour weather map).
- Alerts: National Weather Service active alerts for your place.

Honest limits:
- Free models go to 16 days. 4 weeks is not available free, so the app does not show 4 weeks.
- Some models only cover part of that time (HRRR about 48 hours, Météo-France about 4 days). If a model has no data, the app says "No data".
- The model map shows model numbers at your place on a map. Full colour model maps need a map server, which this app does not have.

Data sources (free, no key): RainViewer Weather Maps API, Iowa Environmental Mesonet single-site radar tiles, Open-Meteo forecast + geocoding APIs, NWS api.weather.gov. Temp in °F, wind in mph, rain in inches.

Build: GitHub Actions (macOS) builds an unsigned .ipa. See .github/workflows/build-ipa.yml.
