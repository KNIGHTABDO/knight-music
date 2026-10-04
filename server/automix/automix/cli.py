"""automix analyze FILE | plan FILE_A FILE_B [--preview OUT.mp3] [--verify] | status"""
from __future__ import annotations

import argparse
import json

import hashlib
import os

from . import planner
from .analyze import ANALYSIS_VERSION
from .analyze import analyze as _analyze

CACHE = os.path.expanduser("~/automix/cache")


def analyze(path: str) -> dict:
    st = os.stat(path)
    key = hashlib.sha1(f"{path}|{st.st_size}|{st.st_mtime}|{ANALYSIS_VERSION}".encode()).hexdigest()
    cached = os.path.join(CACHE, key + ".json")
    if os.path.exists(cached):
        with open(cached) as f:
            return json.load(f)
    data = _analyze(path)
    os.makedirs(CACHE, exist_ok=True)
    with open(cached, "w") as f:
        json.dump(data, f)
    return data


def summary(d: dict) -> dict:
    return {k: v for k, v in d.items() if k not in ("beats", "downbeats", "bars")}


def main():
    ap = argparse.ArgumentParser(prog="automix")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("analyze")
    a.add_argument("file")
    p = sub.add_parser("plan")
    p.add_argument("a")
    p.add_argument("b")
    p.add_argument("--preview")
    p.add_argument("--verify", action="store_true")
    args = ap.parse_args()

    if args.cmd == "analyze":
        print(json.dumps(summary(analyze(args.file)), indent=1))
        return
    da, db = analyze(args.a), analyze(args.b)
    result = planner.plan(da, db, {"duration": da["duration"]}, {"duration": db["duration"]})
    print(json.dumps({"a": summary(da), "b": summary(db)}, indent=1))
    print(json.dumps(result, indent=1))
    if args.preview or args.verify:
        from .render import render, verify, write_mp3
        audio, marks = render(args.a, args.b, result)
        if args.preview:
            write_mp3(audio, args.preview)
            print("preview:", args.preview, marks)
        if args.verify and result["mode"] == "beatmatch":
            print("verify:", verify(marks))


if __name__ == "__main__":
    main()
