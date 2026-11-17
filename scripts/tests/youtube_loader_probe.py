"""Linux loopback regression probe for the production YouTube loader methods.

The production serve/content-range code is extracted verbatim. Linux FoundationNetworking
lacks URLSession.AsyncBytes, so the shim materializes only loopback fixture bodies; its byte
counter measures bytes consumed by the extracted production loop, not socket read-ahead.
AVFoundation and resolver objects are minimal seams; this does not test AVPlayer/iOS behavior.
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
        path = self.path.split("?", 1)[0]
        requests.append({"fixture": path, "range": raw})
        if path in ("/short200", "/complete200"):
            body = expected[:4] if path == "/short200" else expected
            status = 200
        elif path == "/renew-changed":
            body, status = b"", 403
        elif path == "/renew-same":
            body, status = b"", 403
        elif path == "/renew-changed-next" or path == "/renew-same-next":
            body, status = expected[start:end + 1], 206
        elif path == "/short206":
            body, status = expected[start:start + 2], 206
        else:
            body, status = expected[start:end + 1], 206
        self.send_response(status)
        if status == 206:
            if path == "/wrong-range":
                content_range = f"bytes {start + 1}-{end + 1}/16"
            elif path == "/wrong-total":
                content_range = f"bytes {start}-{end}/32"
            else:
                content_range = f"bytes {start}-{end}/16"
            self.send_header("Content-Range", content_range)
            if path == "/etag-change":
                self.send_header("ETag", '"v1"' if start == 0 else '"v2"')
            elif path in ("/renew-changed-next", "/renew-same-next"):
                self.send_header("ETag", '"stable"')
            elif path not in ("/wrong-range", "/wrong-total"):
                self.send_header("ETag", '"stable"')
        self.send_header("Content-Type", "audio/mp4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
stubs = r'''
import Foundation
import FoundationNetworking
enum ProbeMetrics { static var bytesRead=0 }
final class ProbeDataTask { func cancel() {} }
struct ProbeAsyncBytes: AsyncSequence {
 typealias Element=UInt8
 struct AsyncIterator: AsyncIteratorProtocol {
  var iterator:Data.Iterator
  mutating func next() async throws -> UInt8? {
   let next=iterator.next()
   if next != nil { ProbeMetrics.bytesRead += 1 }
   return next
  }
 }
 let data:Data
 let task=ProbeDataTask()
 func makeAsyncIterator()->AsyncIterator { AsyncIterator(iterator:data.makeIterator()) }
}
extension URLSession {
 func bytes(for request:URLRequest) async throws -> (ProbeAsyncBytes,URLResponse) {
  let (data,response)=try await self.data(for:request)
  return (ProbeAsyncBytes(data:data),response)
 }
}
struct Logger { func warning(_ s:String) {} }
enum Log { static let playback=Logger() }
enum AVFileType:String { case m4a="public.mpeg-4-audio" }
final class ContentInfo { var contentType:String?;var contentLength:Int64=0;var isByteRangeAccessSupported=false }
final class DataRequest {
 var currentOffset:Int64=0;let requestedOffset:Int64=0;let requestedLength=Int(CommandLine.arguments[2])!;let requestsAllDataToEndOfResource=true
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
 var calls=0
 func stream(videoId:String) async throws -> YTStream {
  calls += 1
  var url=URL(string:CommandLine.arguments[1])!
  let originalPath=url.path
  if originalPath.hasPrefix("/renew-") {
   url=URL(string:url.absoluteString + (calls == 1 ? "?itag=140" : "-next?itag=\(originalPath == "/renew-same" ? 140 : 141)"))!
  }
  return YTStream(url:url,userAgent:nil,contentLength:16,client:"fixture",expires:.distantFuture,chunkSize:4)
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
    "bytesBase64":r.dataRequest!.received.base64EncodedString(),"declaredLength":r.contentInformationRequest!.contentLength,
    "bodyBytesRead":ProbeMetrics.bytesRead]
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
            "scope": "Verbatim production serve/contentRange methods with resolver and AVFoundation request seams; Linux loopback only. AsyncBytes shim materializes fixture bodies, while bodyBytesRead counts production-loop consumption.",
            "cases": [],
        }
        for case in ("correct", "wrong-range", "wrong-total", "short206", "short200", "complete200",
                     "zero-length-all", "etag-change", "renew-same", "renew-changed"):
            before = len(requests)
            case_path = "correct" if case == "zero-length-all" else case
            requested_length = "0" if case == "zero-length-all" else "16"
            run = subprocess.run([str(binary), f"http://127.0.0.1:{server.server_port}/{case_path}", requested_length],
                                 capture_output=True, text=True, timeout=30)
            if run.returncode:
                raise RuntimeError(run.stderr)
            result = json.loads(run.stdout)
            output["cases"].append({"fixture": case, "result": result, "requests": requests[before:]})
        outcomes = {item["fixture"]: item["result"]["outcome"] for item in output["cases"]}
        assert outcomes == {
            "correct": "success",
            "wrong-range": "failure:YouTube Music sent something unexpected.",
            "wrong-total": "failure:YouTube Music sent something unexpected.",
            "short206": "failure:YouTube Music sent something unexpected.",
            "short200": "failure:The YouTube audio server did not honor a byte-range request. Retry playback.",
            "complete200": "failure:The YouTube audio server did not honor a byte-range request. Retry playback.",
            "zero-length-all": "success",
            "etag-change": "failure:The YouTube audio changed while recovering. Retry playback.",
            "renew-same": "success",
            "renew-changed": "failure:The YouTube audio changed while recovering. Retry playback.",
        }, (outcomes, output["cases"])
        by_fixture = {item["fixture"]: item["result"] for item in output["cases"]}
        expected_b64 = "MDEyMzQ1Njc4OWFiY2RlZg=="
        assert by_fixture["correct"]["bytesBase64"] == expected_b64
        assert by_fixture["zero-length-all"]["bytesBase64"] == expected_b64
        assert by_fixture["renew-same"]["bytesBase64"] == expected_b64
        assert by_fixture["wrong-range"]["receivedBytes"] == 0
        assert by_fixture["wrong-range"]["bodyBytesRead"] == 0
        assert by_fixture["wrong-total"]["receivedBytes"] == 0
        assert by_fixture["short206"]["receivedBytes"] == 0
        assert by_fixture["short200"]["receivedBytes"] == 0
        assert by_fixture["complete200"]["receivedBytes"] == 0
        assert by_fixture["short200"]["bodyBytesRead"] == 0
        assert by_fixture["complete200"]["bodyBytesRead"] == 0
        assert by_fixture["renew-changed"]["receivedBytes"] == 0
        print(json.dumps(output, indent=2))
finally:
    server.shutdown()
    server.server_close()
