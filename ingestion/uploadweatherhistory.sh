mkdir -p /tmp/weather && cd /tmp/weather
end_last=$(date -u -d "-6 days" +%Y-%m-%d)   # the archive runs a few days behind

for y in 2020 2021 2022 2023 2024 2025 2026; do
  start="${y}-01-01"
  end="${y}-12-31"
  [ "$y" = "2026" ] && end="$end_last"
  curl -sf "https://archive-api.open-meteo.com/v1/archive?latitude=41.8781&longitude=-87.6298&start_date=${start}&end_date=${end}&hourly=temperature_2m,precipitation,rain,snowfall,wind_speed_10m,wind_direction_10m,weather_code&timezone=UTC" \
    -o "weather_${y}.json" && echo "got $y"
done

gcloud storage cp weather_*.json gs://$BUCKET/historical/weather/