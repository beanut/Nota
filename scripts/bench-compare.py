#!/usr/bin/env python3
"""Compares an ink benchmark run with a stored baseline (see Packages/InkKit/README.md › Benchmarks).

    scripts/bench-compare.py RESULTS.json --baseline BASELINE.json [--threshold 0.10] [--summary FILE]
                             [--only PREFIX ...]
    scripts/bench-compare.py RESULTS.json --write-baseline BASELINE.json

Every metric is lower-is-better. The run fails (exit 1) when a metric is more than `threshold` worse than
the baseline (ignoring changes below a small absolute noise floor), when a budget the baseline met is now
missed, or when a baseline metric is missing from the run. Budgets the baseline already missed are reported
but don't fail the run, so a known gap doesn't hide new regressions; the budget column shows how far over
they are, so work towards a budget shows from run to run. A missing baseline reports the run and passes,
so the first run of a new environment can be recorded.

Single-frame worsts (`*_max_ms`, e.g. the canvas benchmarks' `zoom.pinch_1x_6x.frame_max_ms`) swing with
one scheduler hiccup, so a regression on them is reported (`noisy`) but doesn't fail the run; their budgets
still count. `--only zoom. pan.` compares just the metrics with those prefixes, for a partial run
(`-only-testing:InkKitBenchmarks/CanvasBenchmarks`).
"""

import argparse
import json
import os
import sys

# Changes smaller than this are noise whatever the percentage (a 0.06 ms p50 moving by 10% is 6 µs).
NOISE_FLOOR = {"ms": 0.05, "us": 5.0, "MB": 2.0}
# Metrics whose regressions are reported but never fail the run (see the docstring).
NOISY_SUFFIXES = ("_max_ms",)


def load(path):
    with open(path) as f:
        return json.load(f)


def fmt(value, unit):
    if value is None:
        return "–"
    return f"{value:,.3f} {unit}" if value < 10 else f"{value:,.1f} {unit}"


def selected(metrics, prefixes):
    if not prefixes:
        return metrics
    return {k: v for k, v in metrics.items() if k.startswith(tuple(prefixes))}


def over_budget(value, budget):
    """How far over its budget a value is, as a multiple ("12.3× over"), or "" when within it."""
    if not budget or value < budget:
        return ""
    return f" ({value / budget:,.1f}× over)"


def compare(results, baseline, threshold, only=None):
    rows, failures = [], []
    current = selected(results.get("metrics", {}), only)
    base = selected((baseline or {}).get("metrics", {}), only)
    for name in sorted(set(current) | set(base)):
        now, then = current.get(name), base.get(name)
        unit = (now or then)["unit"]
        budget = (now or then).get("budget")
        value = now["value"] if now else None
        reference = then["value"] if then else None
        change, status = "", "new" if then is None else "ok"

        if now is None:
            status = "missing"
            failures.append(f"{name} is in the baseline but missing from this run")
        elif reference is not None:
            delta = value - reference
            change = f"{delta / reference:+.1%}" if reference else ""
            if reference and delta / reference > threshold and delta > NOISE_FLOOR.get(unit, 0):
                if name.endswith(NOISY_SUFFIXES):
                    status = "worse (noisy)"
                else:
                    status = "REGRESSED"
                    failures.append(f"{name}: {fmt(reference, unit)} → {fmt(value, unit)} ({change})")
            elif reference and delta / reference < -threshold and -delta > NOISE_FLOOR.get(unit, 0):
                status = "improved"

        budget_cell = ""
        if budget is not None and value is not None:
            met = value < budget
            budget_cell = f"{'✅' if met else '❌'} < {fmt(budget, unit)}{over_budget(value, budget)}"
            if not met:
                if reference is not None and reference < budget:
                    status = "OVER BUDGET"
                    failures.append(f"{name}: {fmt(value, unit)} misses its {fmt(budget, unit)} budget, "
                                    f"which the baseline met")
                else:
                    # Missed in the baseline too (or a new metric): known, so it doesn't fail the run.
                    known = {"ok": "over budget (known)", "improved": "over budget (known, improved)",
                             "new": "over budget (new)"}
                    status = known.get(status, status)
        rows.append((name, fmt(reference, unit), fmt(value, unit), change, budget_cell, status))
    return rows, failures


def markdown(results, baseline, baseline_path, rows, failures, threshold):
    env = results.get("environment", {})
    lines = ["## Ink benchmarks", ""]
    lines.append("Run on `{}` · {} · host {} · {} build · corpus: {}".format(
        env.get("device", "?"), env.get("os", "?"), env.get("host_cpu", "?"),
        env.get("configuration", "?"), env.get("corpus", "?")))
    if baseline is None:
        lines += ["", f"No baseline at `{baseline_path}`: nothing to compare. Record this run as the baseline "
                      "with `--write-baseline` (or commit the `baseline.json` artifact)."]
    else:
        benv = baseline.get("environment", {})
        lines.append(f"Baseline `{baseline_path}` from `{benv.get('device', '?')}` · {benv.get('os', '?')} · "
                     f"host {benv.get('host_cpu', '?')}")
        differs = [k for k in ("device", "host_cpu", "configuration", "corpus") if env.get(k) != benv.get(k)]
        if differs:
            lines.append(f"⚠️ The environment differs from the baseline's ({', '.join(differs)}); "
                         "numbers may not be comparable.")
    lines += ["", f"Fails on a regression of more than {threshold:.0%} or a newly missed budget.", "",
              "| Metric | Baseline | This run | Change | Budget | Status |",
              "| --- | ---: | ---: | ---: | --- | --- |"]
    lines += [f"| `{r[0]}` | {r[1]} | {r[2]} | {r[3]} | {r[4]} | {r[5]} |" for r in rows]
    budgeted = [r for r in rows if r[4]]
    met = sum(1 for r in budgeted if r[4].startswith("✅"))
    lines += ["", f"Budgets: {met} of {len(budgeted)} met."]
    if failures:
        lines += ["", "**Failed:**", ""] + [f"- {f}" for f in failures]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("results")
    parser.add_argument("--baseline")
    parser.add_argument("--threshold", type=float, default=0.10)
    parser.add_argument("--summary", help="also append the markdown report to this file")
    parser.add_argument("--write-baseline", metavar="PATH", help="save the results as a baseline and exit")
    parser.add_argument("--only", nargs="+", metavar="PREFIX",
                        help="compare only the metrics whose names start with one of these prefixes")
    args = parser.parse_args()

    results = load(args.results)
    if results.get("environment", {}).get("configuration") != "release":
        print("error: results come from a Debug build; benchmark with -configuration Release", file=sys.stderr)
        return 2
    if not results.get("metrics"):
        print("error: the results file has no metrics", file=sys.stderr)
        return 2

    if args.write_baseline:
        os.makedirs(os.path.dirname(os.path.abspath(args.write_baseline)), exist_ok=True)
        with open(args.write_baseline, "w") as f:
            json.dump(results, f, indent=2, sort_keys=True)
            f.write("\n")
        print(f"Wrote baseline {args.write_baseline} ({len(results['metrics'])} metrics)")
        return 0

    baseline = load(args.baseline) if args.baseline and os.path.exists(args.baseline) else None
    rows, failures = compare(results, baseline, args.threshold, args.only)
    report = markdown(results, baseline, args.baseline, rows, failures, args.threshold)
    print(report)
    if args.summary:
        with open(args.summary, "a") as f:
            f.write(report)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
