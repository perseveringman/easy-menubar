#!/usr/bin/env python3
"""Render the shipping permission journey without changing Bar's TCC grant."""
from pathlib import Path
import plistlib
import subprocess

root = Path(__file__).resolve().parents[1]
app = root / ".build/audit/Bar Onboarding Audit.app"
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
sources = sorted(str(p) for p in (root / "Sources/Bar").glob("*.swift") if p.name != "BarApp.swift")
subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", *sources,
                str(root / "Tests/Fixtures/OnboardingFixture.swift"), "-o", str(contents / "MacOS/OnboardingAudit")], check=True)
(contents / "Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "com.ryanbzhou.bar.audit.onboarding", "CFBundleExecutable": "OnboardingAudit",
    "CFBundleName": "Bar Onboarding Audit", "CFBundleVersion": "1", "CFBundlePackageType": "APPL", "LSUIElement": True,
}))
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
print(app)
