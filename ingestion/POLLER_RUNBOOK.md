# Divvy Live Poller: Setup Runbook

This guide sets up a system that saves Divvy's live station data every minute, all day, without anyone needing to be logged in.

**How it works:**
- A **Cloud Function** (the worker) fetches Divvy's feed and saves it.
- **Cloud Scheduler** (the alarm clock) tells the worker when to run.
- A **Cloud Storage bucket** (the storage room) holds every saved file.

```
Divvy GBFS feed → Cloud Function → GCS bucket (raw) → Snowflake → dbt → dashboard / MCP
```

**Where to run this:** Cloud Shell, the terminal icon at the top right of the Google Cloud Console. Type `divvy` first to load this project's settings (set up in Step 0). Paste one block at a time, and check each block's output before moving on.

**Who runs it:** the project Owner (Sona) runs Steps 1–9. Steps 5 and 8 grant permissions, which the Editor role can't do. Teammates can run the monitoring commands at the end.

| Setting | Value |
|---|---|
| Project ID | `divvy-project-512716` |
| Region | `us-central1` |
| Bucket | `gs://divvy-raw-srv` |
| Repo in Cloud Shell | `~/CNDE/Divvy/divvy-project` |

---

## Status

**Done**
1. Created the project `divvy-project-512716` and linked billing.
2. Turned on the six Google Cloud services.
3. Added teammates as Editors.
4. Created the bucket `gs://divvy-raw-srv`.
5. Made `env.sh` with the project settings and pushed it to the team repo.

**Next: set up the poller**
1. Fix the env setup (Step 0): remove the auto-load from `.bashrc` and use the `divvy` shortcut instead.
2. Step 4: get the two feed URLs and add them to `env.sh`.
3. Step 5: create the poller's service account and let it write to the bucket.
4. Step 6: write `main.py` and `requirements.txt` in `ingestion/poller/`.
5. Step 7: deploy the function. This step is the slowest.
6. Step 8: create the scheduler, one job every minute and one daily.
7. Step 9: test it and confirm files are arriving.
8. Push everything to GitHub.

**After the poller is running**
1. A teammate checks the file count each day (about 1,440 per day).
2. Submit the proposal by Wednesday, October 28.
3. Load the data into Snowflake and build the dbt star schema, due at the November 18 check-in.
4. Do the backfill, findings, dashboard, and MCP demo, due December 11.

---

## Before Step 0: Project and billing ✅ Done

A Google Cloud project groups everything for this project: the bucket, the function, the scheduler, and who has access. Billing has to be linked because Cloud Functions and Cloud Scheduler won't run without it, even though the cost is very small.

Check that it's set up:

```bash
gcloud billing projects describe divvy-project-512716
```

You should see `billingEnabled: true`.

---

## Step 0: Set up the project settings (load only when working on Divvy)

**What it does:** saves the project ID, bucket name, and other settings in one file, `env.sh`. Every later command reads from it, so nothing has to be retyped, and teammates use the same values.

**Why load it only when needed:** Cloud Shell is also used for other projects. Loading these settings every time it starts would mix Divvy's `$BUCKET` and project into unrelated work. Instead, a `divvy` shortcut loads them only when you're working on this project.

### 0a. The settings file ✅ Done

```bash
cat > ~/CNDE/Divvy/divvy-project/ingestion/env.sh << 'EOF'
export PROJECT_ID="divvy-project-512716"
export REGION="us-central1"
export BUCKET="divvy-raw-srv"
export REPO="$HOME/CNDE/Divvy/divvy-project"
export POLLER_SA="divvy-poller-sa@${PROJECT_ID}.iam.gserviceaccount.com"
export SCHED_SA="divvy-scheduler-sa@${PROJECT_ID}.iam.gserviceaccount.com"
EOF
```

### 0b. Remove the auto-load from `.bashrc` (only if you added it earlier)

```bash
sed -i '\|source ~/CNDE/Divvy/divvy-project/ingestion/env.sh|d' ~/.bashrc
grep "env.sh" ~/.bashrc
```

The `grep` should print nothing, which means the line is gone.

### 0c. Create a gcloud configuration for this project

`gcloud config set project` changes the default project for every `gcloud` command. A named configuration keeps Divvy's project separate from your others.

```bash
gcloud config configurations create divvy
gcloud config set project divvy-project-512716
gcloud config set account YOUR_UCHICAGO_EMAIL
```

To switch back to your other settings:

```bash
gcloud config configurations activate default
```

### 0d. Add the `divvy` shortcut

```bash
cat >> ~/.bashrc << 'EOF'
alias divvy='source ~/CNDE/Divvy/divvy-project/ingestion/env.sh && gcloud config configurations activate divvy && cd ~/CNDE/Divvy/divvy-project'
EOF
source ~/.bashrc
```

The shortcut does nothing until you type it. Typing `divvy` loads this project's variables, switches gcloud to the Divvy project, and moves you into the repo folder.

### How to work from now on

- **Starting Divvy work:** type `divvy`, then check with `echo $PROJECT_ID $BUCKET`.
- **Switching to another project:** open a new Cloud Shell tab (the + button), which starts with no Divvy variables, then activate that project's gcloud configuration.
- **After adding variables to `env.sh`** (Steps 4 and 7): run `divvy` again to reload.

> Load `env.sh` with `source` (which `divvy` does), not `bash`. Running a file with `bash env.sh` sets the variables in a separate process, and they disappear when it finishes.

---

## Step 1: Turn on the services ✅ Done

**What it does:** turns on the Google Cloud services the project uses. They're off by default in a new project.

| Service | Used for |
|---|---|
| Cloud Functions | Runs the poller code |
| Cloud Run | What 2nd-gen Cloud Functions run on behind the scenes |
| Cloud Build | Packages the code when you deploy |
| Cloud Scheduler | Calls the function every minute |
| Artifact Registry | Stores the packaged code |
| Cloud Storage | The bucket |

```bash
gcloud services enable cloudfunctions.googleapis.com run.googleapis.com \
  cloudbuild.googleapis.com cloudscheduler.googleapis.com \
  artifactregistry.googleapis.com storage.googleapis.com
```

Check it:

```bash
gcloud services list --enabled
```

All six services should appear. Turning them on can take a minute or two.

---

## Step 2: Add teammates ✅ Done

**What it does:** gives each teammate Editor access to the project, so they can see the bucket, read logs, and redeploy the function.

**Why Editor:** Editor can create and change resources, but it can't change who has access. Access stays with the Owner.

Run once per teammate, using their UChicago email:

```bash
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="user:teammate@uchicago.edu" --role="roles/editor"
```

Check who has access:

```bash
gcloud projects get-iam-policy $PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.role:roles/editor" \
  --format="value(bindings.members)"
```

Teammates sign in to console.cloud.google.com with their **UChicago** account and pick the project from the dropdown at the top. Google doesn't send an invite email.

---

## Step 3: Create the bucket ✅ Done

**What it does:** creates the storage room where every raw snapshot is saved.

**Why it matters:** Divvy doesn't keep a history of station counts, so these files are the only record of the live data. Everything downstream (Snowflake, dbt, the dashboard) can be rebuilt from them.

```bash
gcloud storage buckets create gs://$BUCKET \
  --location=$REGION \
  --uniform-bucket-level-access \
  --public-access-prevention
```

- `--location`: stores the bucket in the same region as the function.
- `--uniform-bucket-level-access`: permissions apply to the whole bucket, not file by file, which keeps access simple.
- `--public-access-prevention`: blocks anyone from making the bucket public, even by accident.

Check it:

```bash
gcloud storage ls
```

You should see `gs://divvy-raw-srv/`.

---

## Step 4: Find the feed URLs

**What it does:** downloads Divvy's index file, which lists the addresses of all its live feeds. You need two of them:
- `station_status`: bike and dock counts at every station, updated about once a minute
- `station_information`: station names, locations, and capacity, which rarely change

```bash
curl -s https://gbfs.divvybikes.com/gbfs/gbfs.json | python3 -m json.tool
```

`curl` fetches the file, and `python3 -m json.tool` formats it so it's readable. Find the URLs that end in `station_status.json` and `station_information.json`.

Add them to `env.sh`, using the real URLs from the output:

```bash
cat >> $REPO/ingestion/env.sh << 'EOF'
export STATUS_URL="paste-station-status-url"
export INFO_URL="paste-station-information-url"
EOF
source $REPO/ingestion/env.sh
echo $STATUS_URL
echo $INFO_URL
```

`>>` adds the lines to the end of the file without erasing what's there.

Test that both URLs return data:

```bash
curl -s $STATUS_URL | head -c 300
curl -s $INFO_URL | head -c 300
```

Both should start with something like `{"data":{"stations":[...`.

---

## Step 5: Create the poller's service account

**What it does:** creates an identity for the function to run as, then gives that identity exactly one permission: adding files to the bucket.

**Why:** software needs its own identity so Google knows what it's allowed to do. The `objectCreator` role can add new files, but it can't read, overwrite, or delete them. A bug in the code can't damage data you've already collected.

```bash
gcloud iam service-accounts create divvy-poller-sa --display-name="Divvy poller"
```

```bash
gcloud storage buckets add-iam-policy-binding gs://$BUCKET \
  --member="serviceAccount:$POLLER_SA" \
  --role="roles/storage.objectCreator"
```

> No key file is needed. The function runs as this account inside Google Cloud, so there's no password or key to download or protect.

---

## Step 6: Write the code

**What it does:** creates two files directly in the repo:
- `main.py`: the worker's instructions (fetch the feed, add a timestamp, save it to the bucket)
- `requirements.txt`: the Python libraries Google should install when building the function

**Why in the repo:** the code you deploy and the code on GitHub are then the same files.

```bash
mkdir -p $REPO/ingestion/poller
cd $REPO/ingestion/poller
```

```bash
cat > main.py << 'EOF'
import os
from datetime import datetime, timezone
import requests
import functions_framework
from google.cloud import storage

# Settings come from environment variables set at deploy time
BUCKET = os.environ["BUCKET"]
FEEDS = {
    "station_status": os.environ["STATUS_URL"],
    "station_information": os.environ["INFO_URL"],
}

@functions_framework.http          # marks this as the function Google calls
def poll(request):
    # The scheduler says which feed to fetch, e.g. ?feed=station_status
    feed = request.args.get("feed", "station_status")
    if feed not in FEEDS:
        return f"unknown feed: {feed}", 400

    # Fetch the feed; give up after 15 seconds; error out if Divvy fails
    resp = requests.get(FEEDS[feed], timeout=15)
    resp.raise_for_status()

    # Build a path like station_status/dt=2026-10-26/20261026T140500.json
    now = datetime.now(timezone.utc)
    path = f"{feed}/dt={now:%Y-%m-%d}/{now:%Y%m%dT%H%M%S}.json"

    # Save the raw response to the bucket, untouched
    storage.Client().bucket(BUCKET).blob(path).upload_from_string(
        resp.text, content_type="application/json")
    return f"saved {path}", 200
EOF
```

```bash
cat > requirements.txt << 'EOF'
functions-framework
requests
google-cloud-storage
EOF
```

**How the code works:**
- It reads the bucket name and feed URLs from environment variables, which are set in Step 7, so no settings are hard-coded.
- The scheduler adds `?feed=station_status` or `?feed=station_information` to the address, and the code fetches that feed.
- If Divvy is down or slow, `raise_for_status()` and the 15-second timeout turn it into an error that shows up in the logs.
- Files are saved in one folder per day (`dt=2026-10-26/`), named by timestamp in UTC.
- It saves exactly what Divvy sent. Cleaning happens later in dbt, so the bucket stays an untouched record.

> Paste each `cat > ... << 'EOF'` block in full, including the final `EOF` line. To check the files, run `cat main.py`, or use **Open Editor** at the top of Cloud Shell.

---

## Step 7: Deploy the function

**What it does:** uploads the code to Google, which packages it into a container and runs it on Google's servers with its own private web address. After this, the code runs in the cloud, not in Cloud Shell.

**This is the slowest step:** expect 3–10 minutes per attempt. Permission errors are most likely here.

Run it from the poller folder, because `--source=.` uploads whatever folder you're in:

```bash
cd $REPO/ingestion/poller

gcloud functions deploy divvy-poller \
  --gen2 \
  --region=$REGION \
  --runtime=python312 \
  --source=. \
  --entry-point=poll \
  --trigger-http \
  --no-allow-unauthenticated \
  --service-account=$POLLER_SA \
  --set-env-vars=BUCKET=$BUCKET,STATUS_URL=$STATUS_URL,INFO_URL=$INFO_URL
```

| Flag | What it does |
|---|---|
| `--gen2` | Uses the current version of Cloud Functions |
| `--region` | Runs it in the same region as the bucket |
| `--runtime` | The Python version. If it's rejected, use the newest one the docs list |
| `--source=.` | Uploads the code in the current folder |
| `--entry-point=poll` | Which function in `main.py` to run |
| `--trigger-http` | Runs it when its web address is called |
| `--no-allow-unauthenticated` | Blocks the public from calling it |
| `--service-account` | Runs as the identity from Step 5 |
| `--set-env-vars` | Passes in the bucket and URLs that `main.py` reads |

When it finishes, save the function's address to `env.sh`, because the scheduler needs it:

```bash
export FUNCTION_URL=$(gcloud functions describe divvy-poller --region=$REGION \
  --format="value(serviceConfig.uri)")
echo "export FUNCTION_URL=\"$FUNCTION_URL\"" >> $REPO/ingestion/env.sh
echo $FUNCTION_URL
```

> **If you redeploy later** (for example, after changing `main.py`), run the same deploy command with `env.sh` loaded. If `STATUS_URL` or `INFO_URL` is blank, the function will break.

---

## Step 8: Set up the scheduler

**What it does:** sets the alarm clock. The scheduler calls the function on a schedule: every minute for station status, and once a day for station information.

**Why it needs its own identity:** Step 7 locked the function so only accounts with permission can call it. The scheduler gets its own service account, and that account gets permission to call the function.

Create the scheduler's identity:

```bash
gcloud iam service-accounts create divvy-scheduler-sa
```

Allow it to call the function:

```bash
gcloud functions add-invoker-policy-binding divvy-poller --region=$REGION \
  --member="serviceAccount:$SCHED_SA"
```

**Job 1: station status, every minute.** The counts change constantly, and Divvy updates the feed about once a minute. Polling at that rate catches short stockouts and the sudden count jumps that signal rebalancing trucks.

```bash
gcloud scheduler jobs create http divvy-status-every-minute \
  --location=$REGION \
  --schedule="* * * * *" \
  --uri="${FUNCTION_URL}?feed=station_status" \
  --http-method=GET \
  --oidc-service-account-email=$SCHED_SA
```

**Job 2: station information, daily at 4am Chicago time.** Station names, locations, and capacity rarely change, so once a day is enough to catch new or changed stations.

```bash
gcloud scheduler jobs create http divvy-info-daily \
  --location=$REGION \
  --schedule="0 4 * * *" \
  --time-zone="America/Chicago" \
  --uri="${FUNCTION_URL}?feed=station_information" \
  --http-method=GET \
  --oidc-service-account-email=$SCHED_SA
```

- `* * * * *` is cron notation for every minute of every hour of every day. `0 4 * * *` means minute 0 of hour 4, every day.
- `--oidc-service-account-email` makes the scheduler prove its identity when it calls. Google checks that against the permission granted above.

---

## Step 9: Test it

**What it does:** triggers both jobs by hand instead of waiting, then checks three things:
1. Files appeared in the bucket.
2. The files contain real station data, not an error message.
3. The logs show no errors.

Run both jobs now:

```bash
gcloud scheduler jobs run divvy-status-every-minute --location=$REGION
gcloud scheduler jobs run divvy-info-daily --location=$REGION
```

List what's in the bucket. You should see files under `station_status/` and `station_information/`:

```bash
gcloud storage ls -r gs://$BUCKET/
```

Print the start of the newest file. It should show station IDs and bike counts:

```bash
gcloud storage cat $(gcloud storage ls -r gs://$BUCKET/station_status/ | grep .json | tail -1) | head -c 1000
```

Check the logs. Look for `saved ...` lines and any errors:

```bash
gcloud functions logs read divvy-poller --region=$REGION --limit=20
```

Wait about 5 minutes, then confirm the scheduler is adding a new file every minute:

```bash
gcloud storage ls gs://$BUCKET/station_status/dt=$(date -u +%Y-%m-%d)/ | wc -l
```

The count should go up by about one per minute.

**If all of that looks right, the poller is live.** Write down the start date for the proposal.

---

## After setup: push to GitHub

```bash
cd $REPO
git pull
git status
git diff
git add ingestion/
git commit -m "Add Divvy poller, env vars, and runbook"
git push
```

Skim `git diff` for anything sensitive, like a pasted token, before committing. Teammates then run `git pull` to get the code and the updated `env.sh`.

---

## Daily monitoring (any teammate)

Count yesterday's files. About **1,440** means every minute was captured:

```bash
gcloud storage ls gs://$BUCKET/station_status/dt=$(date -u -d yesterday +%Y-%m-%d)/ | wc -l
```

Check that the scheduler jobs are running:

```bash
gcloud scheduler jobs list --location=$REGION
```

Check for recent errors:

```bash
gcloud functions logs read divvy-poller --region=$REGION --limit=20
```

To stop collecting temporarily, for example at the end of the quarter:

```bash
gcloud scheduler jobs pause divvy-status-every-minute --location=$REGION
gcloud scheduler jobs pause divvy-info-daily --location=$REGION
```

Use `resume` instead of `pause` to start again.

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| `echo $PROJECT_ID` prints nothing | `env.sh` isn't loaded in this tab | Type `divvy` |
| Commands affect the wrong project | The wrong gcloud configuration is active | Run `gcloud config configurations list` and check which one is marked active, then type `divvy` |
| Deploy fails with a build or permission error | New projects sometimes need extra roles for the build service account | Read which role the error names, search the exact message, grant the role, and redeploy |
| Deploy fails with an "org policy" error | A UChicago organization restriction | Send the exact error to the professor or TA. You can't fix it yourself |
| Scheduler shows 401 or 403 | The invoker permission from Step 8 hasn't applied yet | Wait 2 minutes and run the job again. If it still fails, rerun the `add-invoker-policy-binding` command |
| Files exist but contain an error message | The feed URL is wrong or has changed | Rerun Step 4, update `env.sh`, and redeploy |
| Fewer than ~1,440 files in a day | Some polls failed | Check the logs for that day, and note gaps in the setup log |
| A teammate's push is rejected | Someone else pushed first | Run `git pull`, then `git push` |

---

## Issues hit so far

- Variables were blank after running `setup.sh`: running it with `bash` sets them in a separate process. Fixed by using `source`.
- Auto-loading `env.sh` from `.bashrc` mixed Divvy settings into other Cloud Shell work. Replaced it with a separate gcloud configuration and a `divvy` shortcut that loads the settings only when needed.
