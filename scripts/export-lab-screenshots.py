#!/usr/bin/env python3
"""Export only deliberately named app screenshots, never automatic failure captures."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("xcresult", type=Path)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
args.destination.mkdir(parents=True, exist_ok=True)
manifest_path = args.destination / "manifest.json"
previous = json.loads(manifest_path.read_text()) if manifest_path.exists() else {"schemaVersion": 1, "simulated": True, "screenshots": []}
entries = {item["file"]: item for item in previous["screenshots"]}
with tempfile.TemporaryDirectory(prefix="tactile-screenshots-") as scratch:
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(args.xcresult),
                    "--output-path", scratch, "--filter", "*.png"], check=True, stdout=subprocess.DEVNULL)
    for case in json.loads((Path(scratch) / "manifest.json").read_text()):
        for attachment in case["attachments"]:
            name = attachment["suggestedHumanReadableName"].split("_")[0]
            if not name.startswith(("light-normal-", "dark-normal-", "light-minimum-", "dark-minimum-", "about-graphite-icon")):
                continue
            if attachment.get("isAssociatedWithFailure"):
                continue
            filename = name + ".png"
            source = Path(scratch) / attachment["exportedFileName"]
            shutil.copy2(source, args.destination / filename)
            entries[filename] = {"file": filename, "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                                 "sourceResult": args.xcresult.name, "test": case["testIdentifier"]}
previous["screenshots"] = sorted(entries.values(), key=lambda item: item["file"])
manifest_path.write_text(json.dumps(previous, indent=2) + "\n")
print(f"Saved {len(entries)} named app captures to {args.destination}")
