#!/usr/bin/env python3
"""Folds every audit-<device>-<orientation> artifact into one small report: summary.md + contact sheets.

Usage: audit-summary.py <dir with audit-* folders> <out dir>
Contact sheets need ImageMagick's `montage`; without it only the text report is written.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys

src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sheets = out / "sheets"
sheets.mkdir(parents=True, exist_ok=True)
lines = ["# UI audit summary", ""]
failures = 0


def crash_info(path):
    """Exception, abort reason and top frames of the crashed thread from an .ips report."""
    text = path.read_text(errors="replace")
    try:
        body = json.loads(text.split("\n", 1)[1])
    except (IndexError, ValueError):
        return ["  (unreadable crash report)"]
    exc = body.get("exception", {})
    info = [f"  - {exc.get('type', '?')} {exc.get('signal', '')}"]
    for value in (body.get("asi") or {}).values():
        info += [f"    {v[:300]}" for v in (value if isinstance(value, list) else [value])]
    images = body.get("usedImages", [])
    for thread in body.get("threads", []):
        if not thread.get("triggered"):
            continue
        for frame in thread.get("frames", [])[:12]:
            image = images[frame["imageIndex"]].get("name", "?") if frame.get("imageIndex", -1) < len(images) else "?"
            info.append(f"    {image}: {frame.get('symbol', hex(frame.get('imageOffset', 0)))}")
    return info


for job in sorted(p for p in src.iterdir() if p.is_dir()):
    name = job.name.removeprefix("audit-")
    log = next(job.glob("*-test.log"), None)
    cases = []
    if log:
        for l in log.read_text(errors="replace").splitlines():
            m = re.search(r"Test Case '.*?(test_\w+)\]' (passed|failed) \(([\d.]+)", l)
            if m:
                cases.append(f"{m[1]} {m[2]} {float(m[3]):.0f}s")
    events = [e for f in sorted(job.glob("*-events.txt")) for e in f.read_text(errors="replace").splitlines() if e.strip()]
    crashes = sorted(job.glob("*.ips"))
    errors = []
    if log:
        errors = sorted({l.strip()[:300] for l in log.read_text(errors="replace").splitlines()
                         if " error: " in l and "ScreenAuditTests" in l})
    ok = cases and all(" passed " in c for c in cases) and not events and not crashes
    failures += not ok
    lines.append(f"## {'OK' if ok else 'FAIL'} {name}")
    lines.append("- " + (", ".join(cases) if cases else "no test results (job died or timed out)"))
    lines += [f"- event: {e}" for e in events[:40]]
    lines += [f"- {e}" for e in errors[:20] if not any(ev.split(': ', 1)[-1] in e for ev in events)]
    for c in crashes:
        lines.append(f"- crash `{c.name}`")
        lines += crash_info(c)
    shots = sorted(job.glob("*.png"))
    lines.append(f"- {len(shots)} screenshots")
    if shots and shutil.which("montage"):
        for page in range(0, len(shots), 40):
            sheet = sheets / f"{name}-{page // 40 + 1}.jpg"
            subprocess.run(["montage", "-label", "%t", *map(str, shots[page:page + 40]), "-geometry", "240x240>+4+4",
                            "-tile", "8x", "-pointsize", "11", "-background", "#222", "-fill", "#ddd",
                            "-quality", "70", str(sheet)], check=False)
        lines.append(f"- sheets: {name}-*.jpg")
    lines.append("")

lines.insert(2, f"**{failures} of {len(list(src.iterdir()))} jobs need attention**\n")
(out / "summary.md").write_text("\n".join(lines))
print("\n".join(lines))
