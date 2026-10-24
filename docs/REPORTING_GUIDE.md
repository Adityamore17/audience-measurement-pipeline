# Reporting guide: Power BI dashboard + Excel report

Build these yourself on top of the pipeline's exports. Screenshots go in
`docs/img/` and get linked from the README.

---

## Part A - Power BI dashboard

### 1. Get the data

Either:
- **Get Data → Text/CSV** for each file in `exports/`, or
- **Get Data → PostgreSQL** → server `localhost:5432`, database `audience`,
  then pick tables from the `mart`, `ref` and `audit` schemas (refreshes from
  the live database).

Load: `daily_brand_daypart_demo` (main fact), `weekly_brand_reach_demo`,
`weekly_cross_platform_demo`, `daily_intab_summary`, `dq_results`,
`dim_brands`, `dim_dayparts`.

### 2. Model

- `dim_brands[brand_id]` 1 → * `daily_brand_daypart_demo[brand_id]` (and the weekly tables)
- `dim_dayparts[daypart]` 1 → * `daily_brand_daypart_demo[daypart]`;
  sort `daypart` by `sort_order` (Column tools → Sort by column)
- Add a Date table (`CALENDAR(DATE(2026,8,31), DATE(2026,9,27))`) related
  to `broadcast_date`.

### 3. Measures (DAX)

The fact table has one row per demo cell, so reach can be **summed across
demo cells only**. These measures enforce that.

```dax
// Projected universe for the cells in the filter, averaged over days
Universe =
AVERAGEX (
    VALUES ( daily_brand_daypart_demo[broadcast_date] ),
    CALCULATE (
        SUMX (
            SUMMARIZE ( daily_brand_daypart_demo,
                daily_brand_daypart_demo[age_group],
                daily_brand_daypart_demo[gender],
                daily_brand_daypart_demo[region] ),
            CALCULATE ( MAX ( daily_brand_daypart_demo[universe] ) )
        )
    )
)

// Reach is only valid for ONE day, daypart, platform and brand.
// Anything else would double-count people -> blank on purpose.
Reach =
IF (
    HASONEVALUE ( daily_brand_daypart_demo[broadcast_date] )
        && HASONEVALUE ( daily_brand_daypart_demo[daypart] )
        && HASONEVALUE ( daily_brand_daypart_demo[platform] )
        && HASONEVALUE ( daily_brand_daypart_demo[brand_id] ),
    SUM ( daily_brand_daypart_demo[reach_persons] )
)

Reach % = DIVIDE ( [Reach], [Universe] ) * 100

// Average of daily reach across the selected dates
Avg Daily Reach =
AVERAGEX ( VALUES ( daily_brand_daypart_demo[broadcast_date] ),
           CALCULATE ( SUM ( daily_brand_daypart_demo[reach_persons] ) ) )

// AMA adds up across brands and demo cells; average it across days
AMA =
IF ( HASONEVALUE ( daily_brand_daypart_demo[daypart] ),
     AVERAGEX ( VALUES ( daily_brand_daypart_demo[broadcast_date] ),
                CALCULATE ( SUM ( daily_brand_daypart_demo[ama] ) ) ) )

Rating % = DIVIDE ( [AMA], [Universe] ) * 100

Share % =
DIVIDE ( [AMA],
         CALCULATE ( [AMA], REMOVEFILTERS ( dim_brands ),
                     REMOVEFILTERS ( daily_brand_daypart_demo[brand_id] ),
                     REMOVEFILTERS ( daily_brand_daypart_demo[brand_name] ) ) ) * 100

Sample Viewers = SUM ( daily_brand_daypart_demo[sample_viewers] )

Low Sample = IF ( [Sample Viewers] < 30, "Low sample", "" )

Rating vs Last Week % =
VAR lw = CALCULATE ( [Rating %], DATEADD ( 'Date'[Date], -7, DAY ) )
RETURN DIVIDE ( [Rating %] - lw, lw ) * 100
```

### 4. Pages

| Page | Visuals | Filters |
|---|---|---|
| **Daily overview** | KPI cards: Reach %, Rating %, Share % (TV, Total Day). Line: Rating % by day per brand. | Date, platform |
| **Dayparts & demos** | Matrix: brand × daypart showing Rating %, with `Low Sample` as a warning column. Bar: Reach % by age group. | Date, platform, age, gender, region |
| **Weekly & cross-platform** | Bar: weekly reach % by brand and platform. Stacked bar: TV only / TV + digital / digital only (from `weekly_cross_platform_demo`). | Week, age group |
| **Data quality** | Table of failed checks from `dq_results`. Line: in-tab % by region by day from `daily_intab_summary`. | Date |

Tips: one accent colour for the brand in focus and grey for the rest; put
slicers in one row at the top; no dual-axis charts.

### 5. Things to be able to explain

- Why `Reach` goes blank when two dayparts are selected (people would be counted twice).
- Why `Rating %` is lower than `Reach %` (average minute vs anyone who watched).
- What the Data quality page showed on 17 Sep.

---

## Part B - Excel report ("Daily Brand Report")

Use `exports/daily_brand_daypart.csv`. Goal: one workbook a manager could
open every morning.

| Sheet | Build | Skill shown |
|---|---|---|
| `Data` | **Data → From Text/CSV** (Power Query). Change types; filter `platform = TV`. Load as a Table named `tblDaily`. | Power Query, Tables |
| `Brands` | Paste `dim_brands.csv`. In `Data`, add Genre with `=XLOOKUP([@brand_id], Brands[brand_id], Brands[genre])`. | XLOOKUP |
| `Daily` | Cell B1 = report date (data validation list of dates). Table of brands with Reach %, Rating %, Share % for Total Day using `SUMIFS(tblDaily[rating_pct], tblDaily[brand_name], A4, tblDaily[broadcast_date], $B$1, tblDaily[daypart], "Total Day")`. | SUMIFS, data validation |
| `Daily` | Next to it: last week's value (`$B$1-7`) and % change; conditional formatting red/green arrows; grey out rows where sample < 30. | Conditional formatting |
| `Pivot` | PivotTable: rows = brand, columns = daypart, values = average rating_pct; slicer on platform. | PivotTables, slicers |
| `Trend` | Line chart of Total Day rating by day for one brand chosen in a dropdown (`FILTER` + chart). | Dynamic arrays, charts |

Refresh test: replace the CSV with a newer export → **Data → Refresh All**
→ every sheet updates with no manual edits.
