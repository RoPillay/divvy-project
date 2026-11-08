source ~/CNDE/Divvy/divvy-project/ingestion/env.sh
mkdir -p /tmp/divvy_trips && cd /tmp/divvy_trips

d=2020-04-01
last=$(date -d "-1 month" +%Y%m)
while [ "$(date -d "$d" +%Y%m)" -le "$last" ]; do
  ym=$(date -d "$d" +%Y%m)
  zip="${ym}-divvy-tripdata.zip"
  if curl -sfO "https://divvy-tripdata.s3.amazonaws.com/${zip}"; then
    unzip -o -q "$zip" -x "__MACOSX/*"
    for f in *.csv; do gzip -f "$f"; done
    gcloud storage cp *.csv.gz gs://$BUCKET/historical/divvy_trips/ --quiet
    echo "uploaded $ym"
  else
    echo "MISSING $ym"
  fi
  rm -f *.zip *.csv *.csv.gz
  d=$(date -d "$d +1 month" +%Y-%m-%d)
done