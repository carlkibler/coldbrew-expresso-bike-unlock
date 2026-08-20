"""
Generate a flat-feel "pedal and read" spline, built from scratch.

The ride: travel on a steady gentle grade (mild constant resistance) along a path
that weaves by only a few degrees — reads as "basically straight and flat" but is
never mathematically straight, because the Inca engine derives the camera/orientation
frame from spline curvature and a perfectly straight line makes it spin/point-down.

Nothing here is borrowed from CityExpress except the start coordinate + spawn heading
(so the rider spawns facing along the path). The path itself is ours.
"""
from __future__ import annotations

import math

from . import spline

# Start coordinate + initial heading. ORIGIN is a known-good spawn point; START_HEADING
# is the spline's initial tangent in the "0°=+Z, +ve toward +X" convention, chosen so a
# SetStartline heading of 238 (the engine value for this direction) faces the rider down
# the track at spawn.
ORIGIN = (1299.44, 748.07, -4474.28)
START_HEADING_DEG = 62.8
POINT_SPACING_M = 14.0


def generate(
    length_m: float = 30000.0,
    grade_pct: float = 1.0,
    weave_amp_deg: float = 8.0,
    weave_wavelength_m: float = 2500.0,
    start_heading_deg: float = START_HEADING_DEG,
) -> spline.Spline:
    """Integrate a path: heading weaves gently around start_heading; Y climbs at grade_pct."""
    n = max(4, round(length_m / POINT_SPACING_M))
    ds = spline.meters_to_units(length_m) / n          # ~14 m per control point
    dy = (grade_pct / 100.0) * ds                       # steady grade → steady resistance
    x, y, z = ORIGIN
    pts = [(x, y, z)]
    for i in range(1, n + 1):
        s_m = (length_m / n) * i
        hdg = math.radians(
            start_heading_deg + weave_amp_deg * math.sin(2 * math.pi * s_m / weave_wavelength_m)
        )
        x += math.sin(hdg) * ds
        z += math.cos(hdg) * ds
        y += dy
        pts.append((x, y, z))
    return spline.Spline(points=pts)
