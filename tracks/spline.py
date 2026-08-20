"""
MEngine clamped cubic B-spline format reader/writer.

Format (from reverse engineering all 60 bike world splines):
    Line 1: ---- Spline Data File ----
    Line 2: 3 <N> 0 0 3          (degree=3, N=num_spans)
    Line 3: <N+7> 0 0 0 0 1 2 3 ... N N N N   (clamped knot vector, N+7 values)
    Line 4: <N+3>                 (num_control_points = N+3)
    Lines 5+: X Y Z per control point

Scale: 1 game unit ≈ 3.0 real meters (calibrated against CityExpress 7287.86m / 2449 path units).
Y axis is elevation.
"""

from __future__ import annotations
import math
from dataclasses import dataclass

# Calibrated against bike2's CityExpress: SetLevelLengthMeters(7287.86) vs ~7434
# spline units → ~0.98 m/unit. (The old 2.975 over-counted distance ~3x.)
METERS_PER_UNIT = 0.98


@dataclass
class Spline:
    points: list[tuple[float, float, float]]

    def path_length_units(self) -> float:
        total = 0.0
        for i in range(1, len(self.points)):
            dx = self.points[i][0] - self.points[i - 1][0]
            dy = self.points[i][1] - self.points[i - 1][1]
            dz = self.points[i][2] - self.points[i - 1][2]
            total += math.sqrt(dx * dx + dy * dy + dz * dz)
        return total

    def path_length_meters(self) -> float:
        return self.path_length_units() * METERS_PER_UNIT

    def elevation_range_meters(self) -> tuple[float, float]:
        ys = [p[1] for p in self.points]
        return min(ys) * METERS_PER_UNIT, max(ys) * METERS_PER_UNIT


def read(path: str) -> Spline:
    points = []
    with open(path) as f:
        lines = f.readlines()
    for line in lines[4:]:
        parts = line.split()
        if len(parts) == 3:
            points.append((float(parts[0]), float(parts[1]), float(parts[2])))
    return Spline(points=points)


def write(spline: Spline, path: str) -> None:
    pts = spline.points
    n_pts = len(pts)
    n_spans = n_pts - 3
    n_knots = n_pts + 4

    with open(path, "w") as f:
        f.write("---- Spline Data File ----\n")
        f.write(f"3 {n_spans} 0 0 3\n")

        knots = [0, 0, 0, 0] + list(range(1, n_spans + 1)) + [n_spans, n_spans, n_spans]
        f.write(f"{n_knots} " + " ".join(str(k) for k in knots) + "\n")

        f.write(f"{n_pts}\n")
        for x, y, z in pts:
            f.write(f"{x:.3f} {y:.3f} {z:.3f}\n")


def meters_to_units(meters: float) -> float:
    return meters / METERS_PER_UNIT


def units_to_meters(units: float) -> float:
    return units * METERS_PER_UNIT
