"""Linux loopback regression probe for the production YouTube loader methods.

The production serve/content-range code is extracted verbatim. AVFoundation and resolver
objects are minimal seams; this does not test AVPlayer decoding or iOS lifecycle behavior.
Run from any directory with: python3 scripts/tests/youtube_loader_probe.py
"""
from pathlib import Path
import hashlib
import http.server
import json
import subprocess
import tempfile
import threading

root = Path(__file__).resolve().parents[2]
loader = (root / "KnightMusic/Core/YouTube/YouTubeResourceLoader.swift").read_text()
music = (root / "KnightMusic/Core/YouTube/YouTubeMusic.swift").read_text()
models = music[music.index("enum YouTubeError:"):music.index("/// YouTube Music over InnerTube:")]
methods = loader[loader.index("    private func serve("):loader.index("/// Whole-file download")]
expected = b"0123456789abcdef"
requests = []


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        raw = self.headers.get("Range", "")
        start, end = map(int, raw.removeprefix("bytes=").split("-"))
        requests.append({"fixture": self.path, "range": raw})
        if self.path == "/short200":
            body, status = expected[:4], 200
        elif self.path == "/complete200":
            body, status = expected, 200
        elif self.path == "/short206":
            body, status = expected[start:start + 2], 206
        else:
            body, status = expected[start:end + 1], 206
        self.send_response(status)
        if status == 206:
            content_range = f"bytes 0-3/16" if self.path == "/wrong-range" else f"bytes {start}-{end}/16"
            self.send_header("Content-Range", content_range)
        self.send_header("Content-Type", "audio/mp4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
stubs = '''
import Foundation
import FoundationNetworking
struct Logger { func warning(_ s:String) {} }
enum Log { static let playback=Logger() }
enum AVFileType:String { case m4a="public.mpeg-4-audio" }
final class ContentInfo { var contentType:String?;var contentLength:Int64=0;var isByteRangeAccessSupported=false }
final class DataRequest {
 var currentOffset:Int64=0;let requestedOffset:Int64=0;let requestedLength=16;let requestsAllDataToEndOfResource=true
 var received=Data()
 func respond(with data:Data) { received.append(data);currentOffset+=Int64(data.count) }
}
final class AVAssetResourceLoadingRequest {
 var contentInformationRequest:ContentInfo?=ContentInfo();var dataRequest:DataRequest?=DataRequest()
 var outcome="pending"
 func finishLoading(){outcome="success"}
 func finishLoading(with error:Error){outcome="failure:"+error.localizedDescription}
}
actor YouTubeMusic {
 static let shared=YouTubeMusic()
 func stream(videoId:String) async throws -> YTStream {
  YTStream(url:URL(string:CommandLine.arguments[1])!,userAgent:nil,contentLength:16,client:"fixture",expires:.distantFuture,chunkSize:4)
 }
 func invalidate(videoId:String){}
}
final class YouTubeResourceLoader {
 let session=URLSession(configuration:.ephemeral)
 func run(_ r:AVAssetResourceLoadingRequest) async { await serve(r,videoId:"fixture") }
'''
main = '''
@main struct Probe {
 static func main() async {
  let r=AVAssetResourceLoadingRequest();await YouTubeResourceLoader().run(r)
  let out:[String:Any] = ["outcome":r.outcome,"receivedBytes":r.dataRequest!.received.count,
    "bytesBase64":r.dataRequest!.received.base64EncodedString(),"declaredLength":r.contentInformationRequest!.contentLength]
  let data=try! JSONSerialization.data(withJSONObject:out,options:[.sortedKeys]);print(String(data:data,encoding:.utf8)!)
 }
}
'''
try:
    with tempfile.TemporaryDirectory(prefix="km-loader-probe-") as temp:
        source = Path(temp) / "Probe.swift"
        binary = Path(temp) / "probe"
        source.write_text(stubs.replace("final class YouTubeResourceLoader {", models + "\nfinal class YouTubeResourceLoader {") + methods + main)
        build = subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(binary)],
                               capture_output=True, text=True, timeout=120)
        if build.returncode:
            raise RuntimeError(build.stderr)
        output = {
            "source_sha256": hashlib.sha256(loader.encode()).hexdigest(),
            "scope": "Verbatim production serve/contentRange methods with resolver and AVFoundation request seams; Linux loopback only.",
            "cases": [],
        }
        for case in ("correct", "wrong-range", "short206", "short200", "complete200"):
            before = len(requests)
            run = subprocess.run([str(binary), f"http://127.0.0.1:{server.server_port}/{case}"],
                                 capture_output=True, text=True, timeout=30)
            if run.returncode:
                raise RuntimeError(run.stderr)
            result = json.loads(run.stdout)
            output["cases"].append({"fixture": case, "result": result, "requests": requests[before:]})
        outcomes = {item["fixture"]: item["result"]["outcome"] for item in output["cases"]}
        assert outcomes == {
            "correct": "success",
            "wrong-range": "failure:YouTube Music sent something unexpected.",
            "short206": "failure:YouTube Music sent something unexpected.",
            "short200": "failure:YouTube Music sent something unexpected.",
            "complete200": "success",
        }, outcomes
        by_fixture = {item["fixture"]: item["result"] for item in output["cases"]}
        expected_b64 = "MDEyMzQ1Njc4OWFiY2RlZg=="
        assert by_fixture["correct"]["bytesBase64"] == expected_b64
        assert by_fixture["complete200"]["bytesBase64"] == expected_b64
        assert by_fixture["wrong-range"]["receivedBytes"] < 16
        assert by_fixture["short206"]["receivedBytes"] == 0
        assert by_fixture["short200"]["receivedBytes"] == 0
        print(json.dumps(output, indent=2))
finally:
    server.shutdown()
    server.server_close()
