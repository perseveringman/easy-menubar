#!/usr/bin/env python3
"""Build disposable local apps for real menu bar tests; never included in Bar.app."""
from pathlib import Path
import plistlib, subprocess
root = Path(__file__).resolve().parents[1]
output = root / ".build/audit"
output.mkdir(parents=True, exist_ok=True)
binary = output / "BarAuditFixture"
subprocess.run(["xcrun", "swiftc", str(root / "Tests/Fixtures/ExperienceFixture.swift"), "-o", str(binary)], check=True)
for kind in ["utility", "regular", "refusing", "multiple", "unnamed"]:
    app = output / f"Bar Audit {kind.title()}.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    import shutil
    shutil.copy2(binary, contents / "MacOS/BarAuditFixture")
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": f"com.ryanbzhou.bar.audit.{kind}", "CFBundleExecutable": "BarAuditFixture",
        "CFBundleName": f"Bar Audit {kind.title()}", "CFBundleVersion": "1", "CFBundlePackageType": "APPL",
        "LSUIElement": kind not in ["regular", "refusing"], "AuditKind": kind,
    }))
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    print(app)
