import os
from datetime import datetime, timezone
import requests
import functions_framework
from google.cloud import storage

BUCKET = os.environ["BUCKET"]
FEEDS = {
    "station_status": os.environ["STATUS_URL"],
    "station_information": os.environ["INFO_URL"],
}

@functions_framework.http
def poll(request):
    feed = request.args.get("feed", "station_status")
    if feed not in FEEDS:
        return f"unknown feed: {feed}", 400
    resp = requests.get(FEEDS[feed], timeout=15)
    resp.raise_for_status()
    now = datetime.now(timezone.utc)
    path = f"{feed}/dt={now:%Y-%m-%d}/{now:%Y%m%dT%H%M%S}.json"
    storage.Client().bucket(BUCKET).blob(path).upload_from_string(
        resp.text, content_type="application/json")
    return f"saved {path}", 200
