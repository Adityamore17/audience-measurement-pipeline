# Metric definitions

Plain-language definitions of every number the pipeline produces, with the
SQL that computes it. Universe in this project = 40,000,000 persons aged 15+.

## Panel terms

| Term | Meaning | In this project |
|---|---|---|
| **Universe estimate (UE)** | How many people in the real population belong to each demographic group. Comes from census-type sources. | `ref.universe_estimates`, 40 cells (5 age × 2 gender × 4 region) |
| **Panel** | The recruited households whose viewing is measured by meters. | 1,200 households, 2,882 people |
| **In-tab** | A panelist whose meter sent good data for the day. Only in-tab panelists are used. | `stg.daily_intab.is_intab`; normally ~93% |
| **Weight** | How many people in the population one in-tab panelist represents. | ~15,000 on a normal day |
| **Raking** | Adjusting weights one dimension at a time (age → gender → region, repeated) until the weighted panel matches the UE on all three. | `scripts/rake_weights.py` |
| **Trimming** | Capping very large weights (here 5 × mean), then re-raking, so one panelist can't dominate. | `--trim-factor 5` |
| **Effective sample size (ESS)** | How many equally weighted panelists the weighted panel is "worth": (Σw)² / Σw². Unequal weights lose precision. | `audit.weighting_diagnostics` |
| **Design effect** | n / ESS. 1.0 = no precision lost. | ~1.09 normally; 2.3 on the outage day |
| **Projected universe** | Sum of weights in a demo cell. Equals the UE exactly for every age, gender and region total. | `universe` column in the marts |

## Audience metrics

| Metric | Definition | Example question it answers |
|---|---|---|
| **Qualifier** | Minimum viewing to count as "reached". | 60 seconds (`QUALIFIER_SEC`) |
| **Reach (persons)** | Σ weights of people who viewed ≥ qualifier in the period. | "How many people watched Sitara on TV yesterday?" |
| **Reach %** | Reach ÷ universe × 100. | "What share of the population was that?" |
| **Weighted minutes** | Σ (weight × minutes viewed). | |
| **AMA (average minute audience)** | Weighted minutes ÷ minutes in the daypart = how many people were watching in an average minute. | "How big was the audience at any moment in prime time?" |
| **Rating %** | AMA ÷ universe × 100. | "PlayMax prime-time rating was 14.3 on 20 Sep." |
| **Share %** | Brand AMA ÷ total AMA of all measured brands on that platform in that daypart. | "Of people watching these channels, what % chose Sitara?" |
| **Avg minutes per viewer** | Weighted minutes ÷ reach. | "How long did viewers stay?" |
| **Frequency (avg days viewed)** | Among people reached in the week, average number of days they viewed (1-7). | "Do viewers come back?" |
| **Unduplicated reach** | People who viewed the brand on at least one platform, each counted once. | "Total audience across TV + digital?" |
| **Duplication %** | (Σ platform reaches − unduplicated reach) ÷ unduplicated reach. | "How much overlap between platforms?" |
| **TV only / Digital only / Both** | Split of unduplicated reach by where people watched. Digital = Digital + Mobile + OTT. | "Who would we miss with a TV-only plan?" |
| **Sample viewers** | Unweighted count of panelists behind an estimate. | Below 30 → `low_sample_flag` |

## Dayparts (broadcast day runs 06:00 → 06:00)

| Daypart | Time |
|---|---|
| Morning | 06:00-12:00 |
| Daytime | 12:00-18:00 |
| Prime Time | 18:00-23:00 |
| Late Night | 23:00-06:00 |
| Total Day | 06:00-06:00 |

## Rules worth remembering

1. **Reach is not additive** across dayparts, days or platforms. Morning reach
   + Prime Time reach double-counts people who watched both. Only demo cells
   add up (each person is in exactly one cell).
2. **Rating ≤ reach %.** Every person in the AMA was reached; the reverse is
   not true. A DQ check enforces this at market level.
3. **Weighted minutes are additive** across dayparts: the four dayparts add
   up to Total Day exactly. A DQ check enforces this.
4. **Small samples swing.** A 60% jump on 6 sample viewers is noise until
   proven otherwise. Always look at `sample_viewers` before reporting a change.
