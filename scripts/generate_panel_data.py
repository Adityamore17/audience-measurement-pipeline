#!/usr/bin/env python3
"""
Generate a synthetic TV + digital audience-measurement panel.

WHY SYNTHETIC
Real panel data (Comscore, BARC, Nielsen) is proprietary. This script mimics
its STRUCTURE and its TYPICAL PROBLEMS so the pipeline can be built and tested
end to end. Every number in this project comes from this generator, and the
README says so.

WHAT IT CREATES (under --out, default ./data)
  raw/reference/households.csv          panel households (region, size)
  raw/reference/panelists.csv           panel members (age group, gender, region)
  raw/reference/universe_estimates.csv  population counts per demo cell
  raw/reference/brands.csv              brand dimension
  raw/reference/brand_aliases.csv       messy brand names -> brand_id
  raw/reference/brand_platforms.csv     which brand is on which platform
  raw/intab/intab_<date>.csv            daily meter status per household
  raw/viewing/viewing_events_<date>.csv daily viewing events (one file per day)
  late_delivery/...                     restated files for the meter-outage day

PLANTED SCENARIOS (so there is something real to investigate)
  * 2026-09-09  file re-delivery: ~8% of rows arrive twice
  * 2026-09-17  meter data outage: most East-region households send no data;
                the missing data arrives later in late_delivery/
  * 2026-09-20  real audience spike: cricket final on PlayMax, prime time
  * every day   duplicates, bad timestamps, unknown brands, orphan panelists,
                "TV left on" sessions, overlapping session fragments,
                inconsistent platform/brand spellings

Usage:
  python3 scripts/generate_panel_data.py --out data --seed 42
"""
import argparse
import csv
import os
from datetime import date, datetime, timedelta

import numpy as np

# ---------------------------------------------------------------- settings
START_DATE = date(2026, 8, 31)      # Monday -> 4 full ISO weeks
N_DAYS = 28
N_HOUSEHOLDS = 1200
UNIVERSE_TOTAL = 40_000_000         # persons 15+ in the (fictional) market

REDELIVERY_DATE = date(2026, 9, 9)
OUTAGE_DATE = date(2026, 9, 17)
OUTAGE_REGION = "East"
MATCH_DATE = date(2026, 9, 20)

AGE_GROUPS = ["15-24", "25-34", "35-44", "45-54", "55+"]
GENDERS = ["M", "F"]
REGIONS = ["North", "South", "East", "West"]
PLATFORMS = ["TV", "Digital", "Mobile", "OTT"]

# Population (universe) shares - what the market really looks like
UNIV_AGE = [0.22, 0.24, 0.20, 0.16, 0.18]
UNIV_GENDER = [0.51, 0.49]
UNIV_REGION = [0.30, 0.25, 0.20, 0.25]

# Panel recruitment is skewed (young + South over-represented) -> weighting needed
PANEL_AGE = [0.28, 0.27, 0.19, 0.13, 0.13]
PANEL_REGION = [0.26, 0.32, 0.18, 0.24]

BRANDS = [
    # brand_id, brand_name, genre, platforms
    ("B01", "Nova News", "News", ["TV", "Digital", "Mobile", "OTT"]),
    ("B02", "Sitara", "Entertainment", ["TV", "Digital", "Mobile", "OTT"]),
    ("B03", "PlayMax", "Sports", ["TV", "Digital", "Mobile", "OTT"]),
    ("B04", "CinePlex", "Movies", ["TV", "Digital", "Mobile", "OTT"]),
    ("B05", "Raag", "Music", ["TV", "Digital", "Mobile", "OTT"]),
    ("B06", "Gyan", "Infotainment", ["TV", "Digital", "Mobile"]),
]
BRAND_ALIASES = {  # alternate spellings seen in raw feeds
    "B01": ["Nova News HD", "NovaNews"],
    "B02": ["Sitara TV", "Sitara HD"],
    "B03": ["PlayMax Sports", "Play Max"],
    "B04": ["CinePlex Movies", "Cineplex HD"],
    "B05": ["Raag Music"],
    "B06": ["Gyan Channel", "Gyan HD"],
}

# Brand preference by age group (order = BRANDS)
BRAND_PREF = {
    "15-24": [0.06, 0.18, 0.26, 0.20, 0.22, 0.08],
    "25-34": [0.12, 0.22, 0.24, 0.20, 0.12, 0.10],
    "35-44": [0.20, 0.28, 0.18, 0.16, 0.06, 0.12],
    "45-54": [0.28, 0.30, 0.14, 0.12, 0.04, 0.12],
    "55+":   [0.36, 0.32, 0.08, 0.10, 0.03, 0.11],
}
GENDER_MULT = {"M": [1, 0.7, 1.5, 1, 1, 1], "F": [1, 1.4, 0.6, 1, 1, 1]}

# Daily probability of using each platform (for these 6 brands), by age group
PLATFORM_PROB = {
    "TV":      [0.40, 0.50, 0.60, 0.68, 0.75],
    "Digital": [0.10, 0.12, 0.10, 0.07, 0.04],
    "Mobile":  [0.30, 0.27, 0.20, 0.13, 0.07],
    "OTT":     [0.16, 0.18, 0.14, 0.09, 0.04],
}
EXTRA_SESSIONS_LAMBDA = {"TV": 1.2, "Digital": 0.4, "Mobile": 0.8, "OTT": 0.3}
# Viewers are loyal: each person gets a personal brand mix drawn around their
# demo's preferences. Lower = more loyal (fewer brands per person).
BRAND_LOYALTY_CONCENTRATION = 2.5
MEDIAN_MINUTES = {"TV": 35, "Digital": 6, "Mobile": 4, "OTT": 45}

# Dayparts as minute offsets from 06:00 (broadcast day runs 06:00 -> 06:00)
DAYPARTS = {
    "Morning": (0, 360),        # 06:00-12:00
    "Daytime": (360, 720),      # 12:00-18:00
    "Prime Time": (720, 1020),  # 18:00-23:00
    "Late Night": (1020, 1440), # 23:00-06:00
}
DAYPART_PROB = {  # where sessions start, by platform
    "TV":      [0.18, 0.17, 0.50, 0.15],
    "Digital": [0.30, 0.45, 0.18, 0.07],
    "Mobile":  [0.25, 0.30, 0.30, 0.15],
    "OTT":     [0.08, 0.15, 0.52, 0.25],
}

# Raw spellings of platform names (value -> probability)
PLATFORM_SPELLINGS = {
    "TV": (["TV", "tv", "Linear TV"], [0.85, 0.05, 0.10]),
    "Digital": (["Digital", "desktop"], [0.80, 0.20]),
    "Mobile": (["Mobile", "smartphone", "MOBILE"], [0.80, 0.10, 0.10]),
    "OTT": (["OTT", "CTV", "ott"], [0.70, 0.20, 0.10]),
}

TS_FMT = "%Y-%m-%d %H:%M:%S"


def normalise(p):
    p = np.asarray(p, dtype=float)
    return p / p.sum()


def build_universe():
    rows = []
    for a, pa in zip(AGE_GROUPS, UNIV_AGE):
        for g, pg in zip(GENDERS, UNIV_GENDER):
            for r, pr in zip(REGIONS, UNIV_REGION):
                rows.append((a, g, r, int(round(UNIVERSE_TOTAL * pa * pg * pr))))
    return rows


def build_panel(rng):
    households, panelists = [], []
    pid = 0
    for h in range(1, N_HOUSEHOLDS + 1):
        hh_id = f"H{h:05d}"
        region = rng.choice(REGIONS, p=PANEL_REGION)
        size = int(rng.choice([1, 2, 3, 4], p=[0.20, 0.35, 0.30, 0.15]))
        hh_tv_factor = float(np.clip(rng.lognormal(0, 0.35), 0.4, 2.5))
        households.append({"household_id": hh_id, "region": region,
                           "household_size": size, "_tv": hh_tv_factor})
        for _ in range(size):
            pid += 1
            panelists.append({
                "panelist_id": f"P{pid:06d}",
                "household_id": hh_id,
                "age_group": rng.choice(AGE_GROUPS, p=PANEL_AGE),
                "gender": rng.choice(GENDERS),
                "region": region,
                "_activity": float(np.clip(rng.lognormal(0, 0.30), 0.4, 2.2)),
                "_tv": hh_tv_factor,
            })
            person = panelists[-1]
            demo_pref = (np.array(BRAND_PREF[person["age_group"]])
                         * np.array(GENDER_MULT[person["gender"]]))
            person["_pref"] = rng.dirichlet(normalise(demo_pref) * BRAND_LOYALTY_CONCENTRATION
                                            + 0.05)
    return households, panelists


def meter_status(rng, region, day, restated=False):
    if day == OUTAGE_DATE and region == OUTAGE_REGION and not restated:
        return rng.choice(["OK", "NO_DATA"], p=[0.12, 0.88])
    return rng.choice(["OK", "NO_DATA", "FAULTY"], p=[0.93, 0.05, 0.02])


def make_session(rng, platform, day_start, brand_id, start_offset=None,
                 minutes=None):
    if start_offset is None:
        dp = rng.choice(list(DAYPARTS), p=DAYPART_PROB[platform])
        lo, hi = DAYPARTS[dp]
        start_offset = rng.uniform(lo, hi)
    if minutes is None:
        minutes = max(0.5, rng.lognormal(np.log(MEDIAN_MINUTES[platform]), 0.8))
    start = day_start + timedelta(minutes=float(start_offset))
    start = start.replace(microsecond=0)
    end = start + timedelta(seconds=int(minutes * 60))
    return platform, brand_id, start, end


def person_day_sessions(rng, person, day, day_start):
    a_idx = AGE_GROUPS.index(person["age_group"])
    weekend = day.weekday() >= 5
    brand_ids = [b[0] for b in BRANDS]
    pref = person["_pref"]
    sessions = []
    for platform in PLATFORMS:
        p = PLATFORM_PROB[platform][a_idx] * person["_activity"]
        if platform == "TV":
            p *= person["_tv"] * (1.15 if weekend else 1.0)
        elif platform == "Digital":
            p *= 0.7 if weekend else 1.0
        if rng.random() >= min(p, 0.97):
            continue
        available = np.array([platform in b[3] for b in BRANDS], dtype=float)
        probs = normalise(pref * available)
        n = 1 + rng.poisson(EXTRA_SESSIONS_LAMBDA[platform])
        for _ in range(n):
            brand = rng.choice(brand_ids, p=probs)
            sessions.append(make_session(rng, platform, day_start, brand))

    # Cricket final on PlayMax: 19:30 start, real audience spike
    if day == MATCH_DATE:
        boost = {"M": 0.40, "F": 0.22}[person["gender"]]
        for platform, mult in (("TV", 1.0), ("OTT", 0.30), ("Mobile", 0.25)):
            if rng.random() < boost * mult:
                start_offset = 810 + rng.uniform(0, 60)          # 19:30-20:30
                minutes = rng.uniform(60, 1035 - start_offset)   # until ~23:15
                sessions.append(make_session(rng, platform, day_start, "B03",
                                             start_offset, minutes))
    return sessions


def spell_platform(rng, platform):
    values, probs = PLATFORM_SPELLINGS[platform]
    return rng.choice(values, p=probs)


def spell_brand(rng, brand_id):
    name = next(b[1] for b in BRANDS if b[0] == brand_id)
    r = rng.random()
    if r < 0.85:
        return name
    if r < 0.90:
        return name.upper()
    if r < 0.94:
        return name + "  "
    return rng.choice(BRAND_ALIASES[brand_id])


def inject_dirt(rng, events, day, seq):
    """Add the kinds of problems real meter feeds have. Returns (events, last_seq)."""
    out = []
    for e in events:
        r = rng.random()
        dur = (e["end"] - e["start"]).total_seconds()
        # overlapping fragments of one session (meter reconnect)
        if r < 0.010 and dur > 600:
            cut1 = e["start"] + timedelta(seconds=int(dur * 0.6))
            cut2 = e["start"] + timedelta(seconds=int(dur * 0.5))
            out.append({**e, "end": cut1})
            out.append({**e, "start": cut2})
            continue
        if r < 0.013:          # end before / equal to start
            e = {**e, "end": e["start"] - timedelta(minutes=int(rng.integers(0, 30)))}
        elif r < 0.017 and e["platform_std"] == "TV":   # TV left on
            e = {**e, "end": e["start"] + timedelta(hours=float(rng.uniform(5, 14)))}
        elif r < 0.019:        # unknown brand
            e = {**e, "brand": rng.choice(["UNKNOWN_" + str(rng.integers(100, 999)), "", "N/A"])}
        elif r < 0.020:        # orphan panelist (not in panel master)
            e = {**e, "panelist_id": f"P9{rng.integers(10000, 99999)}"}
        elif r < 0.022:        # missing platform
            e = {**e, "platform": ""}
        elif r < 0.023:        # malformed timestamp
            e = {**e, "_bad_ts": True}
        out.append(e)

    for e in out:                      # assign event ids before duplicating
        seq += 1
        e["event_id"] = f"E{day:%Y%m%d}{seq:07d}"

    # exact duplicates (same event_id) - file re-sent
    dup_rate = 0.012 + (0.08 if day == REDELIVERY_DATE else 0.0)
    n_dup = int(len(out) * dup_rate)
    dup_idx = rng.choice(len(out), size=n_dup, replace=False)
    out.extend([dict(out[i]) for i in dup_idx])
    return out, seq


def write_csv(path, header, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def events_to_rows(events):
    rows = []
    for e in events:
        start_s = e["start"].strftime(TS_FMT)
        end_s = e["end"].strftime(TS_FMT)
        if e.get("_bad_ts"):
            start_s = e["start"].strftime("%d/%m/%Y %H:%M")
        rows.append([e["event_id"], e["panelist_id"], e["household_id"],
                     e["platform"], e["brand"], start_s, end_s])
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="data")
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)

    ref = os.path.join(args.out, "raw", "reference")
    universe = build_universe()
    write_csv(os.path.join(ref, "universe_estimates.csv"),
              ["age_group", "gender", "region", "universe"], universe)
    write_csv(os.path.join(ref, "brands.csv"), ["brand_id", "brand_name", "genre"],
              [(b[0], b[1], b[2]) for b in BRANDS])
    write_csv(os.path.join(ref, "brand_platforms.csv"), ["brand_id", "platform"],
              [(b[0], p) for b in BRANDS for p in b[3]])
    alias_rows = []
    for b in BRANDS:
        for alias in [b[1]] + BRAND_ALIASES[b[0]]:
            alias_rows.append((alias.lower(), b[0]))
    write_csv(os.path.join(ref, "brand_aliases.csv"), ["alias_norm", "brand_id"],
              sorted(set(alias_rows)))

    households, panelists = build_panel(rng)
    write_csv(os.path.join(ref, "households.csv"),
              ["household_id", "region", "household_size"],
              [(h["household_id"], h["region"], h["household_size"]) for h in households])
    write_csv(os.path.join(ref, "panelists.csv"),
              ["panelist_id", "household_id", "age_group", "gender", "region"],
              [(p["panelist_id"], p["household_id"], p["age_group"], p["gender"], p["region"])
               for p in panelists])
    members = {}
    for p in panelists:
        members.setdefault(p["household_id"], []).append(p)

    total_events = 0
    for d in range(N_DAYS):
        day = START_DATE + timedelta(days=d)
        day_start = datetime(day.year, day.month, day.day, 6, 0, 0)
        intab_rows, late_intab_rows = [], []
        events, late_events = [], []
        for h in households:
            status = meter_status(rng, h["region"], day)
            intab_rows.append((h["household_id"], day.isoformat(), status))
            outage_hh = (day == OUTAGE_DATE and h["region"] == OUTAGE_REGION
                         and status == "NO_DATA")
            if outage_hh:
                restated = meter_status(rng, h["region"], day, restated=True)
                late_intab_rows.append((h["household_id"], day.isoformat(), restated))
                status = restated
            if status == "NO_DATA":
                continue
            for person in members[h["household_id"]]:
                for platform, brand, start, end in person_day_sessions(rng, person, day, day_start):
                    e = {"panelist_id": person["panelist_id"],
                         "household_id": h["household_id"],
                         "platform_std": platform,
                         "platform": spell_platform(rng, platform),
                         "brand": spell_brand(rng, brand),
                         "start": start, "end": end}
                    (late_events if outage_hh else events).append(e)

        events, seq = inject_dirt(rng, events, day, 0)
        rng.shuffle(events)
        rows = events_to_rows(events)
        write_csv(os.path.join(args.out, "raw", "viewing", f"viewing_events_{day}.csv"),
                  ["event_id", "panelist_id", "household_id", "platform", "brand",
                   "start_ts", "end_ts"], rows)
        write_csv(os.path.join(args.out, "raw", "intab", f"intab_{day}.csv"),
                  ["household_id", "broadcast_date", "meter_status"], intab_rows)
        total_events += len(rows)

        if late_events:
            late_events, _ = inject_dirt(rng, late_events, day, 1_000_000)
            rng.shuffle(late_events)
            late_rows = events_to_rows(late_events)
            late = os.path.join(args.out, "late_delivery")
            write_csv(os.path.join(late, "viewing", f"viewing_events_{day}_late.csv"),
                      ["event_id", "panelist_id", "household_id", "platform", "brand",
                       "start_ts", "end_ts"], late_rows)
            write_csv(os.path.join(late, "intab", f"intab_{day}_restated.csv"),
                      ["household_id", "broadcast_date", "meter_status"], late_intab_rows)
        print(f"{day}  events={len(rows):>6}  late_events={len(late_events):>5}")

    print(f"\nHouseholds={len(households)}  Panelists={len(panelists)}  "
          f"Events={total_events}  Universe={sum(u[3] for u in universe):,}")


if __name__ == "__main__":
    main()
