#!/usr/bin/env python3
"""XcodeGen 2.44 does not yet infer Icon Composer's opaque file type."""
from pathlib import Path
import re

project = Path(__file__).resolve().parent.parent / "TactileLab.xcodeproj/project.pbxproj"
source = project.read_text()
pattern = r'(isa = PBXFileReference; )(?:lastKnownFileType = [^;]+; )?(path = TactileLab\.icon;)'
updated, count = re.subn(pattern, r'\1lastKnownFileType = folder.iconcomposer.icon; \2', source)
if count != 1:
    raise SystemExit(f"Expected one opaque Icon Composer reference; found {count}")
project.write_text(updated)
