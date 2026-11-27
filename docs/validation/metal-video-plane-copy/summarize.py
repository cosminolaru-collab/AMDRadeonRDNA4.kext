"""Recalculate timing tables from the archived samples with Python 3."""
import csv
from math import ceil
from pathlib import Path
from statistics import median

data = Path(__file__).resolve().parent / "data"

def rows(filename):
    with (data / filename).open(newline="") as stream:
        return list(csv.DictReader(stream))

def report(label, values, expected):
    values = sorted(map(float, values))
    if len(values) != expected:
        raise ValueError(f"{label} has {len(values)} samples, expected {expected}")
    p95 = values[ceil(len(values) * 0.95) - 1]
    above = sum(value > 50 for value in values)
    print(f"{label:40s} {len(values):3d} {median(values):8.2f} {p95:8.2f} {values[-1]:8.2f} {above:4d}")

print("workload / build / operation                n   median      p95      max  >50   (ms)")
frame = rows("frame-timings.csv")
for workload in ("fixed", "sequence"):
    for build, name in (("bf0ed7e", "bf0ed7e"), ("port", "e065c37")):
        for operation in ("copy_and_mips", "mips"):
            selected = [r["ms"] for r in frame if (r["workload"], r["build"], r["operation"]) == (workload, build, operation)]
            report(f"{workload} {name} {operation}", selected, 72)

wallpaper = rows("wallpaper-timings.csv")
for build in ("bf0ed7e", "e065c37"):
    for series in ("1", "2", "3", "all"):
        for operation in ("move_ms", "read_ms"):
            selected = [r[operation] for r in wallpaper if r["build"] == build and (series == "all" or r["series"] == series)]
            report(f"Wallpaper {build} {series} {operation}", selected, 108 if series == "all" else 36)
