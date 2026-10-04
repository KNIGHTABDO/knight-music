"""An ordered chain of library songs in which every song blends *beat-matched* into the next: the AutoMix
Showcase playlist. Uses the planner's own decisions, so each transition in it is a real AutoMix."""
from __future__ import annotations

import math
import threading
import time

from . import planner

_lock = threading.Lock()
_cache: dict = {"at": 0.0, "key": None, "ids": []}


def _gap(a: dict, b: dict) -> float:
    ratio = b["bpm"] / a["bpm"]
    per = min((0.5, 1.0, 2.0), key=lambda k: abs(math.log(ratio / k)))
    return abs(ratio / per - 1)


def build(analyses: dict[str, dict], meta: dict[str, dict], limit: int = 50, starts: int = 4) -> list[str]:
    usable = {i: d for i, d in analyses.items()
              if d.get("bpm") and d.get("steadiness", 0) >= planner.MIN_STEADINESS}
    max_gap = 2 * planner.MAX_STRETCH + 0.005
    partners = {i: [j for j in usable if j != i and _gap(usable[i], usable[j]) <= max_gap] for i in usable}
    best: list[str] = []
    for start in sorted(partners, key=lambda i: -len(partners[i]))[:starts]:
        chain, used = [start], {start}
        while len(chain) < limit:
            cur = chain[-1]
            # Closest tempos first; among working blends prefer songs that still have partners left.
            candidates = sorted((j for j in partners[cur] if j not in used), key=lambda j: _gap(usable[cur], usable[j]))
            found = []
            for j in candidates[:14]:
                plan = planner.plan(usable[cur], usable[j], meta.get(cur, {}), meta.get(j, {}))
                if plan["mode"] == "beatmatch":
                    found.append((-sum(1 for k in partners[j] if k not in used), j))
                    if len(found) >= 3:
                        break
            if not found:
                break
            nxt = min(found)[1]
            chain.append(nxt)
            used.add(nxt)
        if len(chain) > len(best):
            best = chain
    return best if len(best) >= 2 else []


def cached(store, worker, limit: int = 50) -> list[str]:
    """Rebuilt when the set of analysed songs changed, at most every 2 minutes."""
    counts = store.counts().get("ok", 0)
    with _lock:
        fresh = _cache["key"] == counts and time.time() - _cache["at"] < 600
        if fresh or (_cache["ids"] and time.time() - _cache["at"] < 120):
            return _cache["ids"][:limit]
    analyses = {i: store.get(i) for i in list(worker.meta)}
    analyses = {i: d for i, d in analyses.items() if d}
    ids = build(analyses, worker.meta, limit=max(limit, 50))
    with _lock:
        _cache.update(at=time.time(), key=counts, ids=ids)
    return ids[:limit]
