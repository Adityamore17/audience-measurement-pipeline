#!/usr/bin/env python3
"""
Panel weighting by raking (iterative proportional fitting).

THE PROBLEM
The panel is not a perfect mini-copy of the population: young people and
the South are over-represented, and each day some meters fail to report.
If we just counted panelists, results would be biased.

THE FIX
Give every in-tab panelist a weight = "how many people in the population
this panelist stands for". Raking adjusts the weights one dimension at a
time (age, then gender, then region) until the weighted panel matches the
universe estimates on all three at once.

Then trimming: a panelist standing for too many people makes estimates
unstable, so weights above TRIM_FACTOR x mean are capped and the raking is
repeated.

Input  : --respondents CSV (panelist_id, age_group, gender, region)
         --universe    CSV (age_group, gender, region, universe)
Output : --out         CSV (panelist_id, weight)
         --diag        CSV (one row of diagnostics)
"""
import argparse
import sys

import numpy as np
import pandas as pd

DIMENSIONS = ["age_group", "gender", "region"]


def rake(df, targets, max_iter=100, tol=1e-6):
    """Adjust df['weight'] until weighted totals match targets on every dimension."""
    for it in range(1, max_iter + 1):
        max_gap = 0.0
        for dim in DIMENSIONS:
            current = df.groupby(dim)["weight"].sum()
            factor = targets[dim] / current
            df["weight"] *= df[dim].map(factor)
            max_gap = max(max_gap, float((factor - 1).abs().max()))
        if max_gap < tol:
            return it, True
    return max_iter, False


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--respondents", required=True)
    ap.add_argument("--universe", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--diag", required=True)
    ap.add_argument("--trim-factor", type=float, default=5.0)
    ap.add_argument("--trim-rounds", type=int, default=5)
    args = ap.parse_args()

    resp = pd.read_csv(args.respondents)
    univ = pd.read_csv(args.universe)
    if resp.empty:
        sys.exit("No in-tab respondents - cannot weight this period")

    targets = {dim: univ.groupby(dim)["universe"].sum() for dim in DIMENSIONS}
    for dim in DIMENSIONS:
        missing = set(targets[dim].index) - set(resp[dim].unique())
        if missing:
            sys.exit(f"No respondents for {dim} = {sorted(missing)} - cannot weight")

    total = univ["universe"].sum()
    resp["weight"] = total / len(resp)          # start: everyone equal

    iterations, converged = rake(resp, targets)
    trimmed = 0
    for _ in range(args.trim_rounds):
        cap = args.trim_factor * resp["weight"].mean()
        over = resp["weight"] > cap
        if not over.any():
            break
        trimmed = max(trimmed, int(over.sum()))
        resp.loc[over, "weight"] = cap
        it, converged = rake(resp, targets)
        iterations += it

    w = resp["weight"].to_numpy()
    ess = w.sum() ** 2 / (w ** 2).sum()
    diag = pd.DataFrame([{
        "n_respondents": len(w),
        "sum_weight": round(w.sum(), 2),
        "min_weight": round(w.min(), 2),
        "max_weight": round(w.max(), 2),
        "mean_weight": round(w.mean(), 2),
        "eff_sample_size": round(ess, 1),
        "design_effect": round(len(w) / ess, 3),
        "iterations": iterations,
        "n_trimmed": trimmed,
        "converged": converged,
    }])
    resp[["panelist_id", "weight"]].round({"weight": 4}).to_csv(args.out, index=False)
    diag.to_csv(args.diag, index=False)
    print(diag.to_string(index=False))


if __name__ == "__main__":
    main()
