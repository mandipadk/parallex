#!/usr/bin/env python3
"""Merge notices drafted in Mission Control into advisories/advisories.json.

  Support/merge-notices.py <drafts.json from wrangler> <advisories.json>

Each ready draft replaces a notice for the same app and versions, or is
added; `issued` moves to now so Parallex takes the new file. Prints the ids
merged, one per line.
"""
import json
import sys
from datetime import datetime, timezone

drafts_path, advisories_path = sys.argv[1], sys.argv[2]
rows = json.load(open(drafts_path))[0]["results"]
if not rows:
    sys.exit(0)
advisories = json.load(open(advisories_path))
apps = advisories.setdefault("apps", [])
for row in rows:
    notice = {"bundleID": row["bundle_id"], "level": row["level"], "message": row["message"]}
    if row["versions"] and row["versions"] != "*":
        notice["versions"] = row["versions"]
    if row.get("website"):
        notice["website"] = row["website"]
    apps[:] = [a for a in apps if not (a.get("bundleID") == notice["bundleID"] and a.get("versions", "*") == notice.get("versions", "*"))]
    apps.append(notice)
    print(row["id"])
advisories["issued"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(advisories_path, "w") as out:
    json.dump(advisories, out, indent=2, ensure_ascii=False)
    out.write("\n")
