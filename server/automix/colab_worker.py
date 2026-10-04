"""Analyse the AutoMix backlog on a Colab GPU: pulls each pending song from the Navidrome host through a secret
batch link, runs the very same analysis as the server (Beat This! on the GPU) and posts the result back.

  python colab_worker.py https://<host>/automix/v1/batch/<token>
"""
import concurrent.futures as cf
import json
import os
import sys
import tempfile
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from automix import analyze as A  # noqa: E402

base = sys.argv[1].rstrip("/")


def get(url, timeout=120):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read()


def download(track):
    data = get(f"{base}/file/{track['id']}", timeout=300)
    fd, path = tempfile.mkstemp(suffix=track["suffix"] or ".mp3")
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    return track, path


def post(track_id, result):
    body = json.dumps(result, separators=(",", ":")).encode()
    req = urllib.request.Request(f"{base}/result/{track_id}", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=120).read()


def main():
    import torch
    from beat_this.inference import Audio2Beats
    device = "cuda" if torch.cuda.is_available() else "cpu"
    A._beat_model = Audio2Beats(checkpoint_path="final0", device=device, dbn=False)
    manifest = json.loads(get(f"{base}/manifest"))
    tracks = manifest["tracks"]
    assert manifest["version"] == A.ANALYSIS_VERSION, "server and notebook analysis versions differ"
    print(f"{len(tracks)} songs to analyse on {device}", flush=True)
    started, done = time.time(), 0
    # Downloads run ahead in threads; analysis (GPU beats + CPU features) runs one song at a time.
    with cf.ThreadPoolExecutor(4) as pool:
        for future in [pool.submit(download, t) for t in tracks]:
            try:
                track, path = future.result()
                result = A.analyze(path)
                post(track["id"], result)
                done += 1
                rate = (time.time() - started) / done
                print(f"[{done}/{len(tracks)}] {result.get('bpm') or 0:.1f} BPM  {rate:.1f}s/song  "
                      f"~{rate * (len(tracks) - done) / 60:.0f} min left", flush=True)
            except Exception as exc:  # one bad file must not stop the batch
                print("skipped:", exc, flush=True)
            finally:
                try:
                    os.remove(path)
                except Exception:
                    pass
    print(f"finished {done} songs in {(time.time() - started) / 60:.1f} min", flush=True)


if __name__ == "__main__":
    main()
