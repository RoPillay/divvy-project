# Forecast and Backfill Runbook

This covers the two analytical pieces still left before the final:

| Part | Question | Deliverable |
|---|---|---|
| **A. Forecast** | Can we predict whether a station will be **empty (or full) in the next hour**, well enough to send crews ahead of time? | A model that beats two baselines, its evaluation, and a table of predictions for the dashboard and MCP server |
| **B. Backfill** | How well can **trip records alone** rebuild a station's bike count, and what's left over that trips can't explain? | An accuracy check over the weeks where trips and live data overlap, plus an independent check on the rebalancing findings |

**Where each piece runs:**
- **dbt** builds the input tables, in the same Workspace and project as before.
- **A Snowflake Notebook** (Python) trains and evaluates the forecast, and writes the predictions back to Snowflake.
- **The backfill** is entirely SQL (dbt models plus analysis queries).

| New object | Type | Schema |
|---|---|---|
| `srv_forecast_features` | dbt model | `PROD_SERVING` |
| `int_trip_flows_hourly`, `int_station_hour_end_bikes` | dbt models | `PROD_INTERMEDIATE` |
| `srv_backfill_check` | dbt model | `PROD_SERVING` |
| `STOCKOUT_FORECAST_EVAL`, `STOCKOUT_FORECAST_LATEST`, `FORECAST_RESULTS` | Tables written by the notebook | `DIVVY.ML` |

**Before you start:** prod should be fully built and current (a full Build with no selection), and the findings queries should be done. Both parts read from `PROD_SERVING`.

---

# Part A: The Forecast Model

## A0. The setup in plain terms

Each row is one **station-hour**. The question for that row is: *given what we know at the end of this hour, will this station spend at least 5 minutes empty during the next hour?* That's the same 5-minute threshold as a stockout. A second model answers the same question for *full*.

**What the model can use** is only information available at prediction time:
- **The station's current state:** share of the hour empty or full, average, minimum, and maximum bikes, and how full it is relative to capacity.
- **The trend:** the change in average bikes from the previous hour.
- **When the next hour is:** hour of day and day of week, in Chicago time.
- **Where the station is:** capacity, and distance to the L.
- **The station's usual pattern:** its historical empty rate for that hour on weekdays or weekends, calculated from the **training weeks only**.
- **Weather for the next hour.**

**How it's tested:**
- **Train** on the earlier weeks and **test** on the **last 7 days**. Splitting randomly would let the model see the future, so the split is by time.
- **Compare against two baselines:**
  - *Persistence:* "if it's empty now, it'll be empty next hour"
  - *The station's usual pattern:* its historical rate for that hour
- **The model is only worth using if it beats both.**

**The metrics:**

| Metric | Why |
|---|---|
| **PR-AUC** (average precision) | Stockouts are rare, about 5–10% of station-hours, so this is the main ranking metric. Higher is better |
| **ROC-AUC** | Standard, and easy to compare. But it looks good on rare events even when a model is weak, so don't lead with it |
| **Brier score** | How well calibrated the probabilities are. Lower is better |
| **Precision at 25** | *If crews checked the 25 highest-risk stations each hour, what share actually ran out?* This is the number that means something to Lyft |

**One honest limitation:** the model uses the **actual** weather for the next hour as a stand-in for a weather forecast. A real deployment would use a forecast, which is less accurate. So the weather result here is an **upper bound** on how much weather helps. Say so in the write-up.

## A1. Build the features table in dbt

Create `dbt/divvy/models/serving/srv_forecast_features.sql`.

**What it does:** one row per station-hour, for normal and repeat-stockout stations, in hours where the station was in service at least 30 minutes. It contains the features plus `target_empty` and `target_full` for the next hour. The **latest hour** has its targets left **null**, since that hour hasn't happened yet. Those rows are what the notebook scores for the live forecast.

```sql
with sh as (

    select *
    from {{ ref('srv_station_hour') }}
    where station_type in ('normal', 'repeat_stockout')
      and minutes_in_service >= 30

),

base as (

    select
        station_id,
        hour_utc,
        dateadd('hour', 1, hour_utc)                                        as target_hour_utc,
        minutes_empty,
        minutes_full,
        pct_empty,
        pct_full,
        avg_bikes,
        min_bikes,
        max_bikes,
        capacity,
        is_near_l,
        distance_to_l_km,
        lag(hour_utc)       over (partition by station_id order by hour_utc) as prev_hour,
        lag(avg_bikes)      over (partition by station_id order by hour_utc) as prev_avg_bikes,
        lead(hour_utc)      over (partition by station_id order by hour_utc) as next_hour,
        lead(minutes_empty) over (partition by station_id order by hour_utc) as next_minutes_empty,
        lead(minutes_full)  over (partition by station_id order by hour_utc) as next_minutes_full
    from sh

)

select
    b.station_id,
    b.hour_utc,
    b.target_hour_utc,

    -- current state (known at the end of hour_utc)
    b.minutes_empty,
    b.minutes_full,
    b.pct_empty,
    b.pct_full,
    b.avg_bikes,
    b.min_bikes,
    b.max_bikes,
    b.capacity,
    b.avg_bikes / nullif(b.capacity, 0)                                     as fill_ratio,
    iff(b.prev_hour = dateadd('hour', -1, b.hour_utc),
        b.avg_bikes - b.prev_avg_bikes, null)                               as avg_bikes_change_1h,
    b.is_near_l,
    b.distance_to_l_km,

    -- when and what the next hour is
    t.hour_of_day                                                           as target_hour_of_day,
    t.day_of_week_iso                                                       as target_dow,
    t.is_weekend                                                            as target_is_weekend,
    t.commute_period                                                        as target_commute_period,
    w.temp_c                                                                as target_temp_c,
    w.precip_mm                                                             as target_precip_mm,
    w.is_wet                                                                as target_is_wet,

    -- targets: only when the next hour exists and is consecutive
    case when b.next_hour = b.target_hour_utc
         then iff(b.next_minutes_empty >= {{ var('stockout_min_minutes') }}, 1, 0) end as target_empty,
    case when b.next_hour = b.target_hour_utc
         then iff(b.next_minutes_full  >= {{ var('stockout_min_minutes') }}, 1, 0) end as target_full

from base b
join {{ ref('dim_time') }} t       on t.hour_utc = b.target_hour_utc
left join {{ ref('dim_weather') }} w on w.hour_utc = b.target_hour_utc
```

Add to `models/serving/_serving.yml`, under `models:`:

```yaml
  - name: srv_forecast_features
    description: One row per station-hour with features known at the end of the hour and next-hour stockout targets (null for the latest hour).
    columns:
      - name: station_id
        tests: [not_null]
      - name: target_empty
        tests:
          - accepted_values:
              values: [0, 1]
              quote: false
```

**Build it:** Profile `dev`, Build, with `--select srv_forecast_features`. Check the result:

```sql
USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;

SELECT COUNT(*)                         AS rows,
       COUNT(target_empty)              AS labeled_rows,
       ROUND(100 * AVG(target_empty), 2) AS pct_next_hour_empty,
       ROUND(100 * AVG(target_full), 2)  AS pct_next_hour_full,
       MIN(hour_utc), MAX(hour_utc)
FROM DIVVY.DEV_SERVING.SRV_FORECAST_FEATURES;
```

Expect a few hundred thousand to about a million rows, with **a few percent to about 10%** labeled empty. Then build on **prod** the same way.

## A2. Set up the notebook

Run once in a SQL file, to create the place the notebook writes its results:

```sql
USE ROLE DIVVY_ENGINEER;
CREATE SCHEMA IF NOT EXISTS DIVVY.ML;
```

Then create the notebook:
1. Snowsight → **Projects → Notebooks → + Notebook**.
2. Name it `stockout_forecast`. Set the location to database `DIVVY`, schema `ML`.
3. Choose the **warehouse runtime** and warehouse `DIVVY_WH`.
4. Open the **Packages** menu at the top of the notebook and add **`scikit-learn`**. `pandas` and `numpy` are included already.

> **If adding a package fails** with a message about Anaconda terms, someone with `ACCOUNTADMIN` needs to accept them once, under **Admin → Billing & Terms → Anaconda**. If that isn't possible on the trial, run the same Python locally instead. Install `snowflake-snowpark-python[pandas]` and `scikit-learn`, and replace `get_active_session()` with a `Session.builder.configs({...}).create()` that uses your account, user, role, and warehouse.

> **Cost:** the notebook keeps `DIVVY_WH` running while its session is active. Click **End session** at the top when you're done.

Paste each block below into its own Python cell, and run them in order.

## A3. Notebook cells

### Cell 1: Load the data

```python
import numpy as np
import pandas as pd
from snowflake.snowpark.context import get_active_session

session = get_active_session()

df = session.table("DIVVY.PROD_SERVING.SRV_FORECAST_FEATURES").to_pandas()
df.columns = [c.lower() for c in df.columns]
df["hour_utc"] = pd.to_datetime(df["hour_utc"])
df["target_hour_utc"] = pd.to_datetime(df["target_hour_utc"])

# cyclical hour, so 11 PM and midnight are close together
df["hour_sin"] = np.sin(2 * np.pi * df["target_hour_of_day"] / 24)
df["hour_cos"] = np.cos(2 * np.pi * df["target_hour_of_day"] / 24)

labeled = df[df["target_empty"].notna()].copy()
labeled["target_empty"] = labeled["target_empty"].astype(int)
labeled["target_full"] = labeled["target_full"].astype(int)

print(f"{len(df):,} rows, {len(labeled):,} labeled")
print("next-hour empty rate:", round(labeled["target_empty"].mean() * 100, 2), "%")
print("next-hour full rate:",  round(labeled["target_full"].mean() * 100, 2), "%")
```

### Cell 2: Split by time (last 7 days = test)

```python
test_start = labeled["hour_utc"].max().normalize() - pd.Timedelta(days=7)
train = labeled[labeled["hour_utc"] <  test_start].copy()
test  = labeled[labeled["hour_utc"] >= test_start].copy()

print("train:", train["hour_utc"].min(), "to", train["hour_utc"].max(), f"({len(train):,} rows)")
print("test: ", test["hour_utc"].min(),  "to", test["hour_utc"].max(),  f"({len(test):,} rows)")
```

### Cell 3: The station's usual pattern, from the training weeks only

This is baseline 2, and it's also a feature for the models. It's each station's rate for that hour of day, split by weekday vs. weekend, shrunk toward the systemwide rate for that hour. The shrinking matters because three weeks gives only about 15 weekday observations per station-hour, and the raw rates would be noisy.

```python
KEYS = ["target_is_weekend", "target_hour_of_day"]
K = 5  # shrinkage strength: how many "prior" observations to blend in

def usual_rate(fit_on, apply_to, target):
    prior = (fit_on.groupby(KEYS)[target].mean()
                   .rename("prior").reset_index())
    g = (fit_on.groupby(["station_id"] + KEYS)[target]
               .agg(["sum", "count"]).reset_index()
               .merge(prior, on=KEYS))
    g["rate"] = (g["sum"] + K * g["prior"]) / (g["count"] + K)
    out = (apply_to[["station_id"] + KEYS]
             .merge(g[["station_id"] + KEYS + ["rate"]], on=["station_id"] + KEYS, how="left")
             .merge(prior, on=KEYS, how="left"))
    return (out["rate"].fillna(out["prior"])
                       .fillna(fit_on[target].mean())
                       .to_numpy())

for target in ["target_empty", "target_full"]:
    col = "usual_rate_" + target.split("_")[1]          # usual_rate_empty / usual_rate_full
    train[col] = usual_rate(train, train, target)
    test[col]  = usual_rate(train, test, target)
```

### Cell 4: Features, models, and evaluation helpers

```python
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import make_pipeline
from sklearn.impute import SimpleImputer
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import average_precision_score, roc_auc_score, brier_score_loss

BASE_FEATURES = [
    "pct_empty", "pct_full", "avg_bikes", "min_bikes", "max_bikes", "fill_ratio",
    "avg_bikes_change_1h", "capacity", "distance_to_l_km", "is_near_l",
    "hour_sin", "hour_cos", "target_dow", "target_is_weekend",
]
WEATHER_FEATURES = ["target_temp_c", "target_precip_mm"]

def X(frame, features):
    return frame[features].astype(float)

def gbm():
    return HistGradientBoostingClassifier(max_iter=300, learning_rate=0.05,
                                          max_leaf_nodes=31, random_state=42)

def logit():
    return make_pipeline(SimpleImputer(strategy="median"), StandardScaler(),
                         LogisticRegression(max_iter=1000))

def evaluate(name, y, p, frame, k=25):
    tmp = pd.DataFrame({"hour": frame["target_hour_utc"].to_numpy(), "y": y, "p": p})
    top_k = (tmp.sort_values("p", ascending=False)
                .groupby("hour").head(k)
                .groupby("hour")["y"].mean().mean())
    return {
        "model": name,
        "pr_auc": round(average_precision_score(y, p), 4),
        "roc_auc": round(roc_auc_score(y, p), 4),
        "brier": round(brier_score_loss(y, np.clip(p, 0, 1)), 4),
        f"precision_at_{k}": round(top_k, 4),
    }
```

`HistGradientBoostingClassifier` handles missing values on its own, such as weather for the newest hours. The logistic model fills them with the median.

### Cell 5: Train and compare (empty)

```python
def run(target):
    kind = target.split("_")[1]                  # "empty" or "full"
    y_tr, y_te = train[target].to_numpy(), test[target].to_numpy()
    usual = "usual_rate_" + kind
    results, preds = [], {}

    # Baseline 1: persistence ("as empty/full as it is now")
    preds["persistence"] = test["pct_" + kind].fillna(0).to_numpy()
    # Baseline 2: the station's usual pattern for that hour
    preds["usual_pattern"] = test[usual].to_numpy()

    feats = BASE_FEATURES + [usual]
    for name, make, use_weather in [
        ("logistic",              logit, True),
        ("gbm",                   gbm,   True),
        ("gbm_without_weather",   gbm,   False),
    ]:
        f = feats + (WEATHER_FEATURES if use_weather else [])
        m = make().fit(X(train, f), y_tr)
        preds[name] = m.predict_proba(X(test, f))[:, 1]

    for name, p in preds.items():
        results.append(evaluate(name, y_te, p, test))
    return pd.DataFrame(results), preds

results_empty, preds_empty = run("target_empty")
results_empty
```

### Cell 6: The same for full

```python
results_full, preds_full = run("target_full")
results_full
```

**How to read the results tables:**
- **The model is useful if `gbm` beats both `persistence` and `usual_pattern` on `pr_auc` and `precision_at_25`.** Report the gap, for example: "PR-AUC 0.45 vs. 0.31 for the station's usual pattern."
- **`gbm` vs. `gbm_without_weather`** shows how much weather adds. Given Finding 3, expect a small gap. That's a consistent result to report.
- **`precision_at_25`** is the operational headline: "Of the 25 stations the model flagged each hour, X% actually ran out within the hour, compared with Y% using each station's usual pattern."
- **If persistence is hard to beat,** that's a real result too: stockouts last a while, so "empty now" is a strong signal. In that case the model's value is catching stations *before* they run out. Check that with Cell 7.

### Cell 7: Does it catch stockouts before they start?

Persistence can only flag a station that's already empty. This cell measures the cases that matter most for crews: stations that are **not empty now but run out next hour**.

```python
fresh = (test["minutes_empty"].fillna(0) < 5).to_numpy()
y_te = test["target_empty"].to_numpy()
rows = [evaluate(name + " (new stockouts only)", y_te[fresh], p[fresh], test[fresh])
        for name, p in preds_empty.items() if name != "persistence"]
pd.DataFrame(rows)
```

### Cell 8: What the model relies on

```python
from sklearn.inspection import permutation_importance

feats = BASE_FEATURES + ["usual_rate_empty"] + WEATHER_FEATURES
m = gbm().fit(X(train, feats), train["target_empty"])
sample = test.sample(n=min(50_000, len(test)), random_state=42)
imp = permutation_importance(m, X(sample, feats), sample["target_empty"],
                             scoring="average_precision", n_repeats=3, random_state=42)
(pd.DataFrame({"feature": feats, "importance": imp.importances_mean})
   .sort_values("importance", ascending=False))
```

This shows how much PR-AUC drops when each feature is shuffled. Expect the current state and the usual pattern near the top, and weather near the bottom.

### Cell 9: Save the results and test-week predictions to Snowflake

```python
summary = pd.concat([results_empty.assign(target="empty"),
                     results_full.assign(target="full")], ignore_index=True)
summary.columns = [c.upper() for c in summary.columns]
session.write_pandas(summary, "FORECAST_RESULTS", database="DIVVY", schema="ML",
                     auto_create_table=True, overwrite=True, quote_identifiers=False)

ev = test[["station_id", "hour_utc", "target_hour_utc", "target_empty", "target_full"]].copy()
ev["p_empty"] = preds_empty["gbm"]
ev["p_full"]  = preds_full["gbm"]
ev["p_empty_usual"] = preds_empty["usual_pattern"]
ev.columns = [c.upper() for c in ev.columns]
session.write_pandas(ev, "STOCKOUT_FORECAST_EVAL", database="DIVVY", schema="ML",
                     auto_create_table=True, overwrite=True, quote_identifiers=False)
print("saved", len(ev), "test predictions")
```

### Cell 10: Score the latest hour (the live forecast)

This retrains on **all** labeled weeks, then predicts the next hour for every station using the most recent complete hour. The dashboard and MCP server read this table.

```python
full_fit = labeled.copy()
latest = df[df["target_empty"].isna() & (df["hour_utc"] == df["hour_utc"].max())].copy()

out = latest[["station_id", "hour_utc", "target_hour_utc"]].copy()
for target in ["target_empty", "target_full"]:
    kind = target.split("_")[1]
    usual = "usual_rate_" + kind
    full_fit[usual] = usual_rate(full_fit, full_fit, target)
    latest[usual]   = usual_rate(full_fit, latest, target)
    f = BASE_FEATURES + [usual] + WEATHER_FEATURES
    m = gbm().fit(X(full_fit, f), full_fit[target])
    out["p_" + kind] = m.predict_proba(X(latest, f))[:, 1]

out["scored_at"] = pd.Timestamp.utcnow().tz_localize(None)
out.columns = [c.upper() for c in out.columns]
session.write_pandas(out, "STOCKOUT_FORECAST_LATEST", database="DIVVY", schema="ML",
                     auto_create_table=True, overwrite=True, quote_identifiers=False)
out.sort_values("P_EMPTY", ascending=False).head(10)
```

Weather for the newest hour is usually missing, because of the archive delay. The model handles that, but note it: the live forecast runs without weather.

## A4. Check the outputs in SQL

```sql
USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;

SELECT * FROM DIVVY.ML.FORECAST_RESULTS ORDER BY TARGET, PR_AUC DESC;

-- Highest predicted risk for the next hour, with station names
SELECT s.station_name, s.is_near_l, f.target_hour_utc,
       ROUND(f.p_empty, 3) AS p_empty, ROUND(f.p_full, 3) AS p_full
FROM DIVVY.ML.STOCKOUT_FORECAST_LATEST f
JOIN DIVVY.PROD_MARTS.DIM_STATION s ON f.station_id = s.station_id
ORDER BY f.p_empty DESC
LIMIT 15;

-- Calibration check: do stations predicted at 30% actually run out about 30% of the time?
SELECT ROUND(p_empty, 1) AS predicted_bucket,
       COUNT(*)          AS station_hours,
       ROUND(AVG(target_empty), 3) AS actual_rate
FROM DIVVY.ML.STOCKOUT_FORECAST_EVAL
GROUP BY predicted_bucket
ORDER BY predicted_bucket;
```

Export `FORECAST_RESULTS` and the calibration query as CSVs. They become the forecast slide.

---

# Part B: The Backfill

## B0. The setup in plain terms

The live feed gives the real bike count every minute, but only from October 26. Trips go back years but record rides, not counts. The backfill asks: **if you start from a real count and add each hour's trip arrivals and subtract its departures, how close do you stay to the real count?**

- **Close:** trips alone could rebuild past station counts, which opens up years of history for analysis.
- **Drifting:** the gap is the activity trips don't capture: **rebalancing trucks**, e-bikes parked away from stations, and any trips whose station couldn't be matched.

**The useful second output: hourly residuals.** For each station-hour, the residual is *the actual change in bikes* minus *the net trip flow*. A large residual means bikes moved without a trip, which is an independent way to spot rebalancing and to check the rebalancing finding.

Each day is a fresh start from that day's first real count. The analysis measures how the error grows over the following hours, so one day's error doesn't carry into the next.

## B1. Make sure trips overlap the live window

The backfill only works for hours that have **both** live data and trips. Check the coverage:

```sql
SELECT MIN(started_at_utc) AS first_trip, MAX(started_at_utc) AS last_trip
FROM DIVVY.PROD_STAGING.STG_TRIPS
WHERE started_at_utc >= '2026-10-01';
```

If `last_trip` is before **October 31**, load the October 2026 file. Divvy publishes each month a few weeks after it ends, so check the index page first (`https://divvy-tripdata.s3.amazonaws.com/index.html`). Load November too if it's out. In Cloud Shell:

```bash
source ~/CNDE/Divvy/divvy-project/ingestion/env.sh
mkdir -p /tmp/fix && cd /tmp/fix
ym=202610
curl -sfO "https://divvy-tripdata.s3.amazonaws.com/${ym}-divvy-tripdata.zip" && unzip -o -q "${ym}-divvy-tripdata.zip" -x "__MACOSX/*"
ls -lh
head -3 *.csv            # check the started_at dates are October 2026 (the file may be mislabeled, like Jan 2026 was)
mv *.csv ${ym}-divvy-tripdata.csv 2>/dev/null; gzip -f ${ym}-divvy-tripdata.csv
gcloud storage cp ${ym}-divvy-tripdata.csv.gz gs://$BUCKET/historical/divvy_trips/${ym}-divvy-tripdata.csv.gz
rm -rf /tmp/fix
```

Then load it in Snowflake with the same `COPY INTO DIVVY_TRIPS_RAW` from the Snowflake runbook, Step 10a. Only the new file loads. Finally, run a **full Build** on prod.

> The overlap is about 5 days of October (Oct 27–31), plus November once it's published, which may be after Dec 11. Five days across about 1,180 stations is still about 140,000 station-hours, which is enough for an accuracy check. Present it as a check on a short window, not a full historical rebuild.

## B2. dbt models

### `models/intermediate/int_trip_flows_hourly.sql`

**What it does:** departures and arrivals per **live** station per hour, from trips, translated to live station IDs through the crosswalk. Only trips from around the live window are included. Trips with no station can't be assigned, so they drop out.

```sql
with live_start as (

    select dateadd('day', -1, min(polled_at)) as since
    from {{ ref('stg_station_status') }}

),

trips as (

    select t.started_at_utc, t.ended_at_utc, t.start_station_id, t.end_station_id
    from {{ ref('stg_trips') }} t
    cross join live_start ls
    where t.started_at_utc >= ls.since

),

xw as (

    select trip_station_id, station_id
    from {{ ref('int_station_crosswalk') }}
    where station_id is not null

),

deps as (

    select x.station_id, date_trunc('hour', t.started_at_utc) as hour_utc, count(*) as departures
    from trips t
    join xw x on t.start_station_id = x.trip_station_id
    group by 1, 2

),

arrs as (

    select x.station_id, date_trunc('hour', t.ended_at_utc) as hour_utc, count(*) as arrivals
    from trips t
    join xw x on t.end_station_id = x.trip_station_id
    group by 1, 2

)

select
    coalesce(d.station_id, a.station_id)             as station_id,
    coalesce(d.hour_utc, a.hour_utc)                 as hour_utc,
    coalesce(d.departures, 0)                        as departures,
    coalesce(a.arrivals, 0)                          as arrivals,
    coalesce(a.arrivals, 0) - coalesce(d.departures, 0) as net_trips
from deps d
full outer join arrs a
  on d.station_id = a.station_id
 and d.hour_utc   = a.hour_utc
```

### `models/intermediate/int_station_hour_end_bikes.sql`

**What it does:** the **real** bike count at the end of each station-hour, taken from the last report in that hour.

```sql
select
    station_id,
    date_trunc('hour', valid_from)                   as hour_utc,
    max_by(bikes_available, valid_from)              as end_bikes,
    count(*)                                         as reports
from {{ ref('int_station_status_intervals') }}
group by 1, 2
```

### `models/serving/srv_backfill_check.sql`

**What it does:** for each station and UTC day within the trip coverage, it starts from the first real end-of-hour count, adds net trips hour by hour, and compares the result with the real count. It also computes each hour's **residual**: the actual change minus net trips.

```sql
with coverage as (

    select max(ended_at_utc) as trips_until
    from {{ ref('stg_trips') }}

),

stations as (

    select station_id
    from {{ ref('srv_station_profile') }}
    where station_type in ('normal', 'repeat_stockout')

),

actual as (

    select e.station_id, e.hour_utc, e.end_bikes
    from {{ ref('int_station_hour_end_bikes') }} e
    join stations s on e.station_id = s.station_id
    cross join coverage c
    where e.hour_utc < date_trunc('hour', c.trips_until)

),

joined as (

    select
        a.station_id,
        a.hour_utc,
        date_trunc('day', a.hour_utc)                                        as day_utc,
        a.end_bikes,
        coalesce(f.net_trips, 0)                                             as net_trips,
        coalesce(f.departures, 0)                                            as departures,
        coalesce(f.arrivals, 0)                                              as arrivals,
        lag(a.end_bikes) over (partition by a.station_id order by a.hour_utc) as prev_end_bikes,
        lag(a.hour_utc)  over (partition by a.station_id order by a.hour_utc) as prev_hour
    from actual a
    left join {{ ref('int_trip_flows_hourly') }} f
      on a.station_id = f.station_id
     and a.hour_utc   = f.hour_utc

),

anchored as (

    select
        *,
        first_value(end_bikes) over (partition by station_id, day_utc order by hour_utc) as anchor_bikes,
        first_value(net_trips) over (partition by station_id, day_utc order by hour_utc) as anchor_net,
        min(hour_utc)          over (partition by station_id, day_utc)                   as anchor_hour,
        sum(net_trips)         over (partition by station_id, day_utc order by hour_utc
                                     rows between unbounded preceding and current row)    as cum_net
    from joined

)

select
    station_id,
    hour_utc,
    day_utc,
    datediff('hour', anchor_hour, hour_utc)                                  as hours_since_anchor,
    end_bikes                                                                as actual_bikes,
    anchor_bikes + (cum_net - anchor_net)                                    as reconstructed_bikes,
    anchor_bikes + (cum_net - anchor_net) - end_bikes                        as error_bikes,
    departures,
    arrivals,
    net_trips,
    iff(prev_hour = dateadd('hour', -1, hour_utc), end_bikes - prev_end_bikes, null) as actual_change,
    iff(prev_hour = dateadd('hour', -1, hour_utc),
        (end_bikes - prev_end_bikes) - net_trips, null)                      as residual
from anchored
```

The reconstruction at the anchor hour equals the real count by design, so the error is 0 there. Each later hour adds that hour's net trips.

Add tests to the YAML files:

```yaml
# models/intermediate/_intermediate.yml, under models:
  - name: int_station_hour_end_bikes
    columns:
      - name: end_bikes
        tests: [not_null]

# models/serving/_serving.yml, under models:
  - name: srv_backfill_check
    description: Trip-based reconstruction of station bike counts vs. the live feed, with hourly residuals.
    columns:
      - name: station_id
        tests: [not_null]
```

**Build:** a full Build on dev, then on prod. It's the simplest option, since these models depend on several upstream layers.

## B3. Backfill analysis queries

```sql
USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;
USE SCHEMA DIVVY.PROD_SERVING;
```

**B3-1. How much overlap there is:**

```sql
SELECT MIN(hour_utc), MAX(hour_utc),
       COUNT(*) AS station_hours, COUNT(DISTINCT station_id) AS stations
FROM SRV_BACKFILL_CHECK;
```

**B3-2. How fast the error grows.** This is the main backfill chart:

```sql
SELECT hours_since_anchor,
       COUNT(*)                                      AS station_hours,
       ROUND(AVG(ABS(error_bikes)), 2)               AS mean_abs_error_bikes,
       ROUND(MEDIAN(ABS(error_bikes)), 2)            AS median_abs_error_bikes,
       ROUND(AVG(error_bikes), 2)                    AS mean_signed_error
FROM SRV_BACKFILL_CHECK
GROUP BY hours_since_anchor
ORDER BY hours_since_anchor;
```

How to read it:
- **`mean_abs_error_bikes`** at hour 1, 6, 12, and 23 shows how quickly a trips-only reconstruction drifts.
- **`mean_signed_error`** shows the direction. Negative means the reconstruction runs *low*, so bikes arrive that trips don't account for: trucks dropping off bikes, or e-bikes parked off-station and then ridden back. Positive means bikes leave without trips.

**B3-3. Error relative to station size**, since 3 bikes off matters more at an 11-dock station than at a 50-dock one:

```sql
SELECT ROUND(AVG(ABS(b.error_bikes) / NULLIF(p.capacity, 0)) * 100, 1) AS mean_abs_error_pct_of_capacity
FROM SRV_BACKFILL_CHECK b
JOIN SRV_STATION_PROFILE p ON b.station_id = p.station_id
WHERE b.hours_since_anchor BETWEEN 6 AND 12;
```

**B3-4. How much of each hour's change trips explain:**

```sql
SELECT
  ROUND(CORR(actual_change, net_trips), 3)                               AS correlation,
  ROUND(SUM(ABS(residual)) / NULLIF(SUM(ABS(actual_change)), 0), 3)      AS share_of_change_unexplained,
  COUNT(*)                                                               AS station_hours
FROM SRV_BACKFILL_CHECK
WHERE actual_change IS NOT NULL;
```

**B3-5. Do large residuals line up with the rebalancing events?** This cross-checks Finding 4. If big unexplained jumps match the detected events, that supports both. If many big residuals have **no** detected event, the event detection is missing moves, which supports calling the event count a lower bound.

```sql
WITH big AS (
    SELECT station_id, hour_utc, residual
    FROM SRV_BACKFILL_CHECK
    WHERE ABS(residual) >= 5
),
ev AS (
    SELECT DISTINCT station_id, hour_utc
    FROM DIVVY.PROD_MARTS.FCT_REBALANCING_EVENTS
)
SELECT
  COUNT(*)                                             AS big_residual_hours,
  COUNT(e.station_id)                                  AS with_detected_event,
  ROUND(100 * COUNT(e.station_id) / COUNT(*), 1)       AS pct_with_detected_event,
  ROUND(AVG(IFF(b.residual > 0, 1, 0)) * 100, 1)       AS pct_positive
FROM big b
LEFT JOIN ev e ON b.station_id = e.station_id AND b.hour_utc = e.hour_utc;
```

**B3-6. Where trips explain the least:**

```sql
SELECT p.station_name, p.is_near_l,
       COUNT(*)                                    AS station_hours,
       ROUND(AVG(ABS(b.residual)), 2)              AS avg_abs_residual,
       ROUND(SUM(b.residual))                      AS total_unexplained_bikes
FROM SRV_BACKFILL_CHECK b
JOIN SRV_STATION_PROFILE p ON b.station_id = p.station_id
WHERE b.residual IS NOT NULL
GROUP BY p.station_name, p.is_near_l
ORDER BY avg_abs_residual DESC
LIMIT 15;
```

Export B3-1 through B3-6 as CSVs.

---

# What to bring back

| From | Becomes |
|---|---|
| `FORECAST_RESULTS` + Cell 7 + Cell 8 + the calibration query | **Forecast slide:** model vs. baselines, how well it catches stockouts before they start, and what drives it |
| `STOCKOUT_FORECAST_LATEST` | The dashboard's "next hour" map and the MCP tool "which stations will run out next hour?" |
| B3-2, B3-3 | **Backfill slide:** how fast a trips-only reconstruction drifts |
| B3-4, B3-5, B3-6 | **What trips can't see:** the size and location of activity outside trips, cross-checked against the rebalancing finding |

---

# Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| `srv_forecast_features` has 0 labeled rows | No consecutive in-service hours, or the threshold is too strict | Check `srv_station_hour` row counts. Temporarily lower `minutes_in_service >= 30` to 15 |
| Notebook can't add `scikit-learn` | Anaconda terms not accepted | `ACCOUNTADMIN`: Admin → Billing & Terms → Anaconda. Or run locally (A2) |
| `to_pandas()` runs out of memory | Too many rows for the notebook | Load fewer columns, or filter to `hour_utc >= DATEADD('day', -21, CURRENT_DATE())` with `session.sql(...)` |
| `KeyError` in Cell 3 or 5 | Column names didn't lowercase | Make sure Cell 1's `df.columns = [c.lower() ...]` ran |
| `write_pandas` fails with a type error | Timezone-aware timestamps | Run `.dt.tz_localize(None)` on any timestamp column first |
| All models tie with persistence | Stockouts persist across hours | Expected in part. Lead with Cell 7 (new stockouts only), where persistence scores zero by definition |
| `srv_backfill_check` is empty | Trips don't overlap the live window | Do B1: load the October 2026 trip file and run a full Build |
| Error is huge from hour 1 | Crosswalk gaps or a time zone mismatch | Check `int_trip_flows_hourly` against `stg_trips` for one busy station. The trip hour should line up with the live data's busy hours |
| B3-5 shows few matches | Detection threshold is 5+ bikes within 10 minutes, while residuals are hourly | Expected. Report it as evidence that rebalancing is undercounted |
