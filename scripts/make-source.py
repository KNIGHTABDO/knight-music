#!/usr/bin/env python3
"""Writes the SideStore/AltStore source (apps.json) for a release, derived from the built app bundle.

SideStore refuses an install whose entitlements or privacy prompts aren't declared by the source, so
both are read from the bundle (plus its extensions) instead of being maintained by hand.

usage: make-source.py <Payload/KnightMusic.app> <Duet.ipa> <tag> <notes-file> <out.json>
"""
import datetime, glob, json, os, plistlib, re, subprocess, sys

REPO = "KNIGHTABDO/knight-music"
ENTITLEMENT_FILES = ["KnightMusic/Resources/KnightMusic.entitlements", "KnightMusicWidgets/KnightMusicWidgets.entitlements"]
PRIVACY_KEY = re.compile(r"^NS\w+UsageDescription$")

app, ipa, tag, notes_file, out = sys.argv[1:6]
bundles = [app] + sorted(glob.glob(os.path.join(app, "PlugIns", "*.appex")))

def info(bundle):
    with open(os.path.join(bundle, "Info.plist"), "rb") as f:
        return plistlib.load(f)

main = info(app)
privacy = {}
entitlements = set()
for bundle in bundles:
    for key, value in info(bundle).items():
        if PRIVACY_KEY.match(key):
            privacy[key] = value
    try:
        signed = subprocess.run(["codesign", "-d", "--entitlements", ":-", bundle], capture_output=True)
        if signed.returncode == 0 and signed.stdout.strip():
            entitlements.update(plistlib.loads(signed.stdout).keys())
    except (FileNotFoundError, plistlib.InvalidFileException):
        pass  # unsigned build / no codesign: the repo's .entitlements files below are the source of truth
for path in ENTITLEMENT_FILES:
    if os.path.exists(path):
        with open(path, "rb") as f:
            entitlements.update(plistlib.load(f).keys())

notes = open(notes_file).read().strip() or f"Duet {tag}"
base = f"https://github.com/{REPO}"
version = {
    "version": main["CFBundleShortVersionString"],
    "buildVersion": str(main["CFBundleVersion"]),
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": notes,
    "downloadURL": f"{base}/releases/download/{tag}/{os.path.basename(ipa)}",
    "size": os.path.getsize(ipa),
    "minOSVersion": main.get("MinimumOSVersion", "26.0"),
}
source = {
    "name": "Duet",
    "subtitle": "Music and movies. One app.",
    "sourceURL": f"{base}/releases/latest/download/apps.json",
    "website": "https://streamora-5w5.pages.dev",
    "iconURL": f"https://raw.githubusercontent.com/{REPO}/main/KnightMusic/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    "tintColor": "FA2D48",
    "apps": [{
        "name": "Duet",
        "bundleIdentifier": main["CFBundleIdentifier"],
        "developerName": "KNIGHTABDO",
        "subtitle": "Music and movies. One app.",
        "localizedDescription": "Your Navidrome music and Streamora movies in one Liquid Glass app. Shake to switch. Offline library, AutoMix, synced lyrics, animated artwork, and a full movie player with VLC.",
        "iconURL": f"https://raw.githubusercontent.com/{REPO}/main/KnightMusic/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
        "tintColor": "FA2D48",
        "category": "entertainment",
        "versions": [version],
        "appPermissions": {"entitlements": sorted(entitlements), "privacy": privacy},
    }],
    "news": [],
}
with open(out, "w") as f:
    json.dump(source, f, indent=2)
print(json.dumps(source["apps"][0]["appPermissions"], indent=2))
print(f"source: {version['version']} ({version['buildVersion']}), {version['size']} bytes")
