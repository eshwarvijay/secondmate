#!/usr/bin/env python3
"""Render clone-history.json as a smooth cumulative-downloads SVG chart.

Usage: make-chart.py <history.json> <out.svg>
       make-chart.py --selftest
No deps — stdlib only. Committed SVG is embedded in the README.
"""
import json, sys

W, H = 760, 260
PAD_L, PAD_R, PAD_T, PAD_B = 52, 56, 44, 40
PLOT_W, PLOT_H = W - PAD_L - PAD_R, H - PAD_T - PAD_B
BASE = PAD_T + PLOT_H
PURPLE, INK, MUTE = "#5436DA", "#1b1240", "#8a8aa0"


def _smooth(pts):
    """Catmull-Rom → cubic bezier path, y-clamped so it never overshoots."""
    if len(pts) < 3:
        return "M " + " L ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    d = f"M {pts[0][0]:.1f},{pts[0][1]:.1f}"
    for i in range(len(pts) - 1):
        p0 = pts[i - 1] if i else pts[0]
        p1, p2 = pts[i], pts[i + 1]
        p3 = pts[i + 2] if i + 2 < len(pts) else pts[-1]
        c1x, c1y = p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6
        c2x, c2y = p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6
        clamp = lambda y: min(max(y, PAD_T), BASE)
        d += f" C {c1x:.1f},{clamp(c1y):.1f} {c2x:.1f},{clamp(c2y):.1f} {p2[0]:.1f},{p2[1]:.1f}"
    return d


def _build_empty_svg() -> str:
    """No history yet (e.g. tracker just installed): still 760x260, same
    title/colors, but a "0" total and a placeholder message instead of a
    crash on days[0]/days[-1] against an empty list."""
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif">
  <defs>
    <linearGradient id="area" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{PURPLE}" stop-opacity="0.30"/>
      <stop offset="1" stop-color="{PURPLE}" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="stroke" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#7a5cff"/>
      <stop offset="1" stop-color="{PURPLE}"/>
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="{W}" height="{H}" rx="14" fill="#faf9ff"/>
  <text x="{PAD_L}" y="24" font-size="14" font-weight="700" fill="{INK}">plugin downloads</text>
  <line x1="{PAD_L}" y1="{BASE}" x2="{W-PAD_R}" y2="{BASE}" stroke="{MUTE}" stroke-opacity="0.18" stroke-dasharray="3 4"/>
  <text x="{PAD_L-10}" y="{BASE+4}" text-anchor="end" font-size="11" fill="{MUTE}">0</text>
  <text x="{W/2:.1f}" y="{PAD_T + PLOT_H/2:.1f}" text-anchor="middle" font-size="13" fill="{MUTE}">no downloads recorded yet</text>
  <text x="{W-PAD_R-8:.1f}" y="{BASE-10:.1f}" text-anchor="end" font-size="15" font-weight="800" fill="{PURPLE}">0</text>
</svg>'''


def build_svg(history: dict) -> str:
    days = sorted(history)
    if not days:
        return _build_empty_svg()

    cum, running = [0], 0          # lead with 0 so the line rises from the baseline
    for d in days:
        running += history[d]
        cum.append(running)

    total = running or 1
    n = len(cum)
    x = lambda i: PAD_L + (PLOT_W * i / (n - 1) if n > 1 else PLOT_W / 2)
    y = lambda v: PAD_T + PLOT_H - PLOT_H * v / total
    pts = [(x(i), y(v)) for i, v in enumerate(cum)]
    path = _smooth(pts)
    area = f"{path} L {pts[-1][0]:.1f},{BASE} L {pts[0][0]:.1f},{BASE} Z"

    grid = ""
    for v in (total // 2, total):
        gy = y(v)
        grid += (
            f'<line x1="{PAD_L}" y1="{gy:.1f}" x2="{W-PAD_R}" y2="{gy:.1f}" '
            f'stroke="{MUTE}" stroke-opacity="0.18" stroke-dasharray="3 4"/>'
            f'<text x="{PAD_L-10}" y="{gy+4:.1f}" text-anchor="end" font-size="11" fill="{MUTE}">{v}</text>'
        )

    lx, ly = pts[-1]
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif">
  <defs>
    <linearGradient id="area" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{PURPLE}" stop-opacity="0.30"/>
      <stop offset="1" stop-color="{PURPLE}" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="stroke" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#7a5cff"/>
      <stop offset="1" stop-color="{PURPLE}"/>
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="{W}" height="{H}" rx="14" fill="#faf9ff"/>
  <text x="{PAD_L}" y="24" font-size="14" font-weight="700" fill="{INK}">plugin downloads</text>
  {grid}
  <text x="{PAD_L}" y="{H-14}" font-size="11" fill="{MUTE}">{days[0]}</text>
  <text x="{W-PAD_R}" y="{H-14}" text-anchor="end" font-size="11" fill="{MUTE}">{days[-1]}</text>
  <path d="{area}" fill="url(#area)"/>
  <path d="{path}" fill="none" stroke="url(#stroke)" stroke-width="3" stroke-linecap="round"/>
  <circle cx="{lx:.1f}" cy="{ly:.1f}" r="6" fill="{PURPLE}" fill-opacity="0.18"/>
  <circle cx="{lx:.1f}" cy="{ly:.1f}" r="3.5" fill="{PURPLE}"/>
  <text x="{lx-8:.1f}" y="{ly-10:.1f}" text-anchor="end" font-size="15" font-weight="800" fill="{PURPLE}">{total}</text>
</svg>'''


def selftest():
    svg = build_svg({"2026-06-24": 95, "2026-06-25": 3, "2026-06-26": 7})
    assert "<path" in svg and ">105<" in svg, svg
    assert build_svg({"2026-06-24": 5}).count("<path") == 2  # single day still renders
    empty = build_svg({})
    assert "no downloads recorded yet" in empty, empty
    assert f'width="{W}" height="{H}"' in empty, empty
    assert ">0<" in empty, empty
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--selftest"]:
        selftest()
    else:
        with open(sys.argv[1]) as f:
            history = json.load(f)
        with open(sys.argv[2], "w") as f:
            f.write(build_svg(history))
