#!/usr/bin/env python3
"""Regression check for protected PatchHub packages readable by the IPA codec.

This is intentionally a format-level test: the actual AES-GCM decryption is
performed by PatchPackageCodec on iOS/macOS. The fixture is the protected
package that previously reached the IPA and was rejected before password
verification because keyAADVersion 3 was incorrectly limited to writable
versions (1..2).
"""
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
fixture = ROOT / "tests" / "fixtures" / "patchhub-schema3-protected.3105"
codec = ROOT / "ThreeOneOSFive" / "helpers" / "PatchPackageCodec.swift"
magic = b"3105PATCH\0"

data = fixture.read_bytes()
assert data.startswith(magic), "fixture does not use the 3105PATCH envelope"
envelope = plistlib.loads(data[len(magic):])
assert envelope["schemaVersion"] == 3, envelope.get("schemaVersion")
assert envelope["keyAADVersion"] == 3, envelope.get("keyAADVersion")
assert envelope["isPasswordProtected"] is True
assert len(envelope["kdfSalt"]) == 16
assert 100_000 <= envelope["kdfIterations"] <= 600_000
assert len(envelope["wrappedContentKey"]) >= 28
assert len(envelope["encryptedPayload"]) >= 28

source = codec.read_text()
expected = r"\(minimumSchemaVersion\.\.\.latestReadableSchemaVersion\)\.contains\("
assert re.search(expected, source), (
    "PatchPackageCodec must accept readable keyAAD versions through schema 3"
)
assert "latestWritableSchemaVersion).contains(" not in source[source.index("if envelope.isPasswordProtected"):source.index("} else {", source.index("if envelope.isPasswordProtected"))]
print("OK: protected PatchHub schema 3 envelope is accepted by the IPA validation contract")
