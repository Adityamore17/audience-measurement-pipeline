# Investigations

Two moves in the numbers, two different answers. The method is the same
for both: **check the panel before believing the audience.**

All queries are in `sql/analysis/` and run with `bin/run_analysis.sh`.

---

## Case 1 - East region numbers jump on 17 Sep (data artifact)

### What happened

The pipeline stopped on 17 Sep at the staging checks:

```
ERROR | intab_critical_east   | 11.82 | 50 | Region in-tab collapsed - likely meter data outage in East
WARN  | intab_rate_pct_east   | 11.82 | 75 |
```

### Step 1 - Panel health (`01_intab_by_region.sql`)

Only **59 of 499** East panelists were in-tab, against ~94% on every other
day. North, South and West were normal (92-95%). One region failing on its
own points to meter data delivery, not to a change in viewing.

### Step 2 - What the numbers would have looked like

To measure the impact, the day was run once with a waiver
(`DQ_WAIVE=intab_critical_east@2026-09-17`), and East compared with the
same weekday a week earlier (`02_region_reach_vs_last_week.sql`):

| East, Total Day | 10 Sep reach (sample) | 17 Sep reach (sample) | Change |
|---|---|---|---|
| TV PlayMax | 1,121k (67) | 1,898k (14) | **+69%** |
| Mobile Sitara | 391k (23) | 814k (6) | **+108%** |
| Mobile PlayMax | 372k (23) | 0 (0) | **-100%** |

Large moves in both directions, each resting on a handful of panelists.

### Step 3 - Why (weighting diagnostics)

Raking still forced East to its 20% share of the population, so each of the
59 East panelists stood for **~135,600 people instead of ~17,000** (8×). The
weight checks flagged it: design effect **2.31** (normal 1.09), effective
sample size in East **59** (minimum 100), max/mean weight ratio 7.7.

National TV totals barely moved (Sitara 8.69M vs 9.06M after the fix,
about -4%), because weighting protects the market total. **The regional
numbers were the problem** - exactly what a client looking at East would
have seen.

### Step 4 - Fix and confirm

Data ops confirmed a meter outage in East and sent the missing data
(`data/late_delivery/`). The day was restated (SOP §6):

| | Before | After restatement |
|---|---|---|
| East in-tab | 11.8% | 94.0% |
| Design effect | 2.31 | 1.09 |
| Max weight | 135,644 | 27,916 |
| East TV brands vs last week | TV PlayMax +69% on 14 viewers | all six within -17% to +24% (PlayMax -2% on 68 viewers) |

### Outcome

- No bad East numbers were published: the check stopped the run first.
- Late data loaded through the normal process; nothing was edited by hand.
- Suggested follow-up: alert Data ops automatically when any region's
  in-tab drops below 75%, before the analyst finds it.

---

## Case 2 - PlayMax TV jumps on 20 Sep (real audience)

### What happened

The day passed every ERROR check, with one WARN:

```
WARN | week_on_week_anomalies | Reach moved >40% vs same day last week:
       TV PlayMax North +142%; TV PlayMax South +130%; TV PlayMax West +108%
```

### Step 1 - Panel health

In-tab on 20 Sep was normal in every region (91-93%), design effect 1.09.
So the panel was fine; the question becomes whether the *viewing* changed.

### Step 2 - Where did it happen? (`04_daypart_vs_baseline.sql`)

PlayMax on TV vs the same weekday in previous weeks:

| Daypart | Baseline rating | 20 Sep rating | Index |
|---|---|---|---|
| Morning | 0.53 | 0.50 | 0.94 |
| Daytime | 0.61 | 0.59 | 0.96 |
| **Prime Time** | **1.92** | **14.34** | **7.47** |
| Late Night | 0.64 | 0.67 | 1.05 |

Prime-time reach went from **11.4% to 37.5%**. Every other daypart was normal.

### Step 3 - Is it everywhere?

PlayMax TV prime-time reach, 13 Sep → 20 Sep:

| Region | 13 Sep | 20 Sep | Sample on 20 Sep |
|---|---|---|---|
| North | 1.37M | 4.75M | 263 |
| South | 1.09M | 3.66M | 305 |
| West | 1.22M | 3.84M | 258 |
| East | 0.75M | 2.76M | 160 |

All four regions rose 3-4×, on large samples. The OTT and Mobile apps
spiked in prime time too.

### Conclusion

A real event: the cricket final aired on PlayMax in prime time. Pattern of a
real audience change, as opposed to Case 1:

| | Case 1 (artifact) | Case 2 (real) |
|---|---|---|
| In-tab | collapsed in one region | normal everywhere |
| Regions | one region, random directions | all regions, same direction |
| Dayparts | all dayparts affected | only the event's time slot |
| Sample size | tiny | large |
| Other platforms | random | same brand up on OTT/Mobile at the same time |

Expected side effect: on 27 Sep the same check fires again (PlayMax -50% vs
20 Sep). That is the comparison base, not a drop, and is noted as expected.

Suggested follow-up: keep an events calendar (sports, launches) so known
events are marked automatically instead of raising warnings.
