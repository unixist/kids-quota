#!/usr/bin/env python3
"""Render MDM examples using real release identities; never install profiles."""
import argparse
import json
from pathlib import Path
import plistlib
import re
from urllib.parse import urlparse
import uuid


def profile(identifier, name, payload):
    payload = dict(payload, PayloadIdentifier=identifier + ".payload", PayloadUUID=str(uuid.uuid4()).upper(), PayloadVersion=1, PayloadDisplayName=name)
    return dict(PayloadType="Configuration", PayloadVersion=1, PayloadIdentifier=identifier, PayloadUUID=str(uuid.uuid4()).upper(), PayloadDisplayName=name, PayloadScope="System", PayloadContent=[payload])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--chrome-extension-id", required=True)
    parser.add_argument("--chrome-update-url", default="https://clients2.google.com/service/update2/crx")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--non-removable", action="store_true", help="Add macOS 15+ system-extension removal prevention (requires SIP).")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        parser.error("Use the actual 10-character Apple developer team ID.")
    if not re.fullmatch(r"[a-p]{32}", args.chrome_extension_id):
        parser.error("Use the actual 32-letter Chrome extension ID, from a-p.")
    update = urlparse(args.chrome_update_url)
    if update.scheme != "https" or not update.hostname or update.username or update.password or ";" in args.chrome_update_url:
        parser.error("Use a valid HTTPS extension update URL without credentials or semicolons.")
    args.output.mkdir(parents=True, exist_ok=True)
    chrome = profile("com.kidsquota.chrome-policy", "Kids Quota Chrome Extension", {
        "PayloadType": "com.google.Chrome",
        "ExtensionInstallForcelist": [args.chrome_extension_id + ";" + args.chrome_update_url],
        "NativeMessagingUserLevelHosts": False,
    })
    extension = "com.kidsquota.app.networkfilter"
    system = {"PayloadType": "com.apple.system-extension-policy", "AllowedSystemExtensions": {args.team_id: [extension]}}
    if args.non_removable:
        system["NonRemovableSystemExtensions"] = {args.team_id: [extension]}
    system = profile("com.kidsquota.system-extension-policy", "Kids Quota Network Extension", system)
    for filename, data in [("chrome-force-install.mobileconfig", chrome), ("system-extension-approval.mobileconfig", system)]:
        (args.output / filename).write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False))
    safari = {
        "Type": "com.apple.configuration.safari.extensions.settings",
        "Identifier": "com.kidsquota.safari-extension-policy",
        "ServerToken": str(uuid.uuid4()),
        "Payload": {"ManagedExtensions": {
            "com.kidsquota.app.safari (" + args.team_id + ")": {
                "State": "AlwaysOn", "PrivateBrowsing": "AlwaysOn", "AllowedDomains": ["*"]
            }
        }},
    }
    (args.output / "safari-always-on.json").write_text(json.dumps(safari, indent=2) + "\n")
    print("Rendered three examples. Deploy through MDM after reviewing scope and compatibility; no system settings changed.")


if __name__ == "__main__":
    main()
