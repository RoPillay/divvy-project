mkdir -p /tmp/gtfs && cd /tmp/gtfs
curl -sfL -o google_transit.zip https://www.transitchicago.com/downloads/sch_data/google_transit.zip
unzip -o -q google_transit.zip stops.txt
head -3 stops.txt
gcloud storage cp stops.txt gs://$BUCKET/historical/cta_gtfs/stops.txt