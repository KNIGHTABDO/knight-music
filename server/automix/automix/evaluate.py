"""Batch quality check over the analysed library: plan random pairs, render beat-matched ones and measure lock.

  python -m automix.evaluate [--pairs 40] [--render 12] [--out ~/automix/previews]
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import random

from . import planner
from .service import DATA_DIR, Store, navidrome_tracks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pairs", type=int, default=40)
    ap.add_argument("--render", type=int, default=10)
    ap.add_argument("--out", default=os.path.expanduser("~/automix/previews"))
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    store = Store(os.path.join(DATA_DIR, "analysis.db"))
    meta = {t["id"]: t for t in navidrome_tracks()}
    analysed = [i for i in meta if store.get(i)]
    print(f"{len(analysed)} analysed tracks")
    rng = random.Random(args.seed)
    modes = collections.Counter()
    reasons = collections.Counter()
    beatmatched = []
    for _ in range(args.pairs):
        a_id, b_id = rng.sample(analysed, 2)
        plan = planner.plan(store.get(a_id), store.get(b_id), meta[a_id], meta[b_id])
        modes[plan["mode"]] += 1
        reasons[plan.get("reason", "").split(",")[0] if plan["mode"] != "beatmatch" else "beatmatch"] += 1
        if plan["mode"] == "beatmatch":
            beatmatched.append((a_id, b_id, plan))
    print("modes:", dict(modes))
    print("reasons:", dict(reasons))
    if not args.render:
        return
    from .render import render, verify, write_mp3
    os.makedirs(args.out, exist_ok=True)
    results = []
    for a_id, b_id, plan in beatmatched[:args.render]:
        audio, marks = render(meta[a_id]["path"], meta[b_id]["path"], plan)
        v = verify(marks)
        name = f"{os.path.splitext(os.path.basename(meta[a_id]['path']))[0][:40]} -> " \
               f"{os.path.splitext(os.path.basename(meta[b_id]['path']))[0][:40]}.mp3".replace("/", "_")
        write_mp3(audio, os.path.join(args.out, name))
        results.append({"pair": name, "reason": plan["reason"], **v})
        print(json.dumps(results[-1], ensure_ascii=False))
    locked = [r for r in results if r.get("locked")]
    print(f"locked {len(locked)}/{len(results)}")


if __name__ == "__main__":
    main()
