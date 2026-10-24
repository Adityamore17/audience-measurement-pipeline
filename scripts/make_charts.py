#!/usr/bin/env python3
"""
Make the three README charts from the exported CSVs.

Usage: python3 scripts/make_charts.py      (after bin/run_pipeline.sh + bin/run_analysis.sh)
Output: docs/img/*.png
"""
import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXP = os.path.join(ROOT, "exports")
OUT = os.path.join(ROOT, "docs", "img")
os.makedirs(OUT, exist_ok=True)

SURFACE, INK, INK_2, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#898781", "#e1e0d9"
BLUE, ORANGE, AQUA, CRITICAL = "#2a78d6", "#eb6834", "#1baf7a", "#d03b3b"
OTHER = "#c9c8c1"

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "font.family": "DejaVu Sans", "font.size": 10, "text.color": INK,
    "axes.edgecolor": GRID, "axes.labelcolor": INK_2, "xtick.color": MUTED, "ytick.color": MUTED,
    "axes.spines.top": False, "axes.spines.right": False, "axes.spines.left": False,
    "axes.grid": True, "axes.grid.axis": "y", "grid.color": GRID, "grid.linewidth": 0.6,
})


def title(ax, main, sub):
    ax.set_title(main, loc="left", fontsize=13, fontweight="bold", color=INK, pad=24)
    ax.text(0, 1.02, sub, transform=ax.transAxes, fontsize=9.5, color=INK_2, va="bottom")


def chart_playmax_spike():
    df = pd.read_csv(os.path.join(EXP, "daily_brand_daypart.csv"), parse_dates=["broadcast_date"])
    tv = df[(df.platform == "TV") & (df.daypart == "Prime Time")]
    fig, ax = plt.subplots(figsize=(9, 4.4))
    for brand, g in tv.groupby("brand_name"):
        if brand != "PlayMax":
            ax.plot(g.broadcast_date, g.reach_pct, color=OTHER, lw=1.4, zorder=1)
    pm = tv[tv.brand_name == "PlayMax"].sort_values("broadcast_date")
    ax.plot(pm.broadcast_date, pm.reach_pct, color=BLUE, lw=2.2, zorder=3)
    peak = pm.loc[pm.reach_pct.idxmax()]
    ax.scatter([peak.broadcast_date], [peak.reach_pct], s=40, color=BLUE, zorder=4,
               edgecolor=SURFACE, linewidth=2)
    ax.annotate(f"Cricket final, 20 Sep\n{peak.reach_pct:.1f}% reached in prime time",
                (peak.broadcast_date, peak.reach_pct), xytext=(12, -6),
                textcoords="offset points", fontsize=9.5, color=INK, va="top")
    last = pm.iloc[-1]
    ax.text(last.broadcast_date + pd.Timedelta(hours=10), last.reach_pct, "PlayMax",
            color=INK, fontsize=9.5, va="center", fontweight="bold")
    ax.text(last.broadcast_date + pd.Timedelta(hours=10),
            tv[tv.broadcast_date == last.broadcast_date].reach_pct.max(),
            "Other 5 brands", color=MUTED, fontsize=9, va="center")
    ax.set_ylabel("Prime-time reach, % of population")
    ax.set_ylim(0, None)
    ax.xaxis.set_major_locator(mdates.WeekdayLocator(byweekday=mdates.MO))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%d %b"))
    title(ax, "A real spike: PlayMax prime time on TV",
          "All four regions rose together and panel in-tab was normal, so the audience was real")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "playmax_spike.png"), dpi=160)
    plt.close(fig)


def chart_east_outage():
    s = pd.read_csv(os.path.join(EXP, "daily_intab_summary.csv"), parse_dates=["broadcast_date"])
    east = (s[s.region == "East"].groupby("broadcast_date")[["intab", "panel_size"]].sum())
    east["pct"] = 100 * east.intab / east.panel_size

    # what the first delivery said for 17 Sep (original intab file, before restatement)
    hh = pd.read_csv(os.path.join(ROOT, "data/raw/reference/households.csv"))
    orig = pd.read_csv(os.path.join(ROOT, "data/raw/intab/intab_2026-09-17.csv")).merge(hh, on="household_id")
    pan = pd.read_csv(os.path.join(ROOT, "data/raw/reference/panelists.csv"))
    orig = pan.merge(orig[["household_id", "meter_status"]], on="household_id", how="left")
    orig_east = orig[orig.region == "East"]
    first_pct = 100 * (orig_east.meter_status == "OK").mean()

    fig, ax = plt.subplots(figsize=(9, 4.2))
    ax.plot(east.index, east.pct, color=BLUE, lw=2.2, zorder=2)
    day = pd.Timestamp("2026-09-17")
    ax.scatter([day], [first_pct], s=46, color=CRITICAL, zorder=4, edgecolor=SURFACE, linewidth=2)
    ax.vlines(day, first_pct, east.loc[day, "pct"], color=CRITICAL, lw=1, ls=(0, (2, 2)), zorder=1)
    ax.annotate(f"17 Sep as first delivered: {first_pct:.0f}% in-tab\n"
                "Pipeline stopped (ERROR below 50%)",
                (day, first_pct), xytext=(12, 0), textcoords="offset points",
                fontsize=9.5, color=INK, va="center")
    ax.annotate(f"After late files: {east.loc[day, 'pct']:.0f}%", (day, east.loc[day, "pct"]),
                xytext=(12, -16), textcoords="offset points", fontsize=9.5, color=INK_2)
    ax.axhline(50, color=MUTED, lw=0.8, ls=(0, (4, 3)))
    ax.text(east.index[0], 52, "50% stop threshold", color=MUTED, fontsize=8.5)
    ax.set_ylim(0, 100)
    ax.set_ylabel("East panelists in-tab, %")
    ax.xaxis.set_major_locator(mdates.WeekdayLocator(byweekday=mdates.MO))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%d %b"))
    title(ax, "A data artifact: the East meter outage",
          "Few in-tab panelists means each one stands for ~8x more people, so regional numbers swing")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "east_outage.png"), dpi=160)
    plt.close(fig)


def chart_cross_platform():
    x = pd.read_csv(os.path.join(EXP, "weekly_cross_platform.csv"), parse_dates=["week_start"])
    wk = x[x.week_start == x.week_start.max()].copy()
    for c in ["reach_tv_only", "reach_tv_and_digital", "reach_digital_only"]:
        wk[c + "_pct"] = 100 * wk[c] / wk.universe
    wk = wk.sort_values("reach_pct")
    parts = [("reach_tv_only_pct", "TV only", BLUE),
             ("reach_tv_and_digital_pct", "TV + digital", ORANGE),
             ("reach_digital_only_pct", "Digital only", AQUA)]
    fig, ax = plt.subplots(figsize=(9, 4.4))
    left = pd.Series(0.0, index=wk.index)
    for col, label, color in parts:
        ax.barh(wk.brand_name, wk[col], left=left, color=color, height=0.6,
                edgecolor=SURFACE, linewidth=2, label=label)
        for i, (v, l) in enumerate(zip(wk[col], left)):
            if v >= 5:
                ax.text(l + v / 2, i, f"{v:.0f}", ha="center", va="center", fontsize=8.5,
                        color="white" if color != AQUA else INK)
        left += wk[col]
    for i, total in enumerate(wk.reach_pct):
        ax.text(total + 1, i, f"{total:.0f}%", va="center", fontsize=9.5, color=INK, fontweight="bold")
    ax.set_xlim(0, 100)
    ax.set_axisbelow(True)
    ax.grid(axis="y", visible=False)
    ax.grid(axis="x", visible=True)
    ax.set_xlabel("Weekly reach, % of population (each person counted once)")
    ax.legend(loc="lower right", frameon=False, fontsize=9, ncol=3, bbox_to_anchor=(1, -0.32))
    week = wk.week_start.iloc[0]
    title(ax, "Unduplicated cross-platform reach",
          f"Week of {week:%d %b %Y}: where each brand's audience comes from")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "cross_platform.png"), dpi=160)
    plt.close(fig)


if __name__ == "__main__":
    chart_playmax_spike()
    chart_east_outage()
    chart_cross_platform()
    print(f"charts written to {OUT}")
