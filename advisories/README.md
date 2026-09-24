# Notices

`advisories.json` is what Parallex tells people without shipping an update:
a note on an app whose copies misbehave (shown when making or looking at an
instance of it) and one-time messages for particular Parallex versions.

```json
{
  "issued": "2026-10-01T09:00:00Z",
  "apps": [
    { "bundleID": "com.microsoft.teams2", "versions": ">=25000", "level": "unsupported",
      "message": "Copies of Teams quit at launch.", "website": "https://teams.microsoft.com" }
  ],
  "messages": [
    { "id": "window-bug", "parallex": "0.16.1...0.17.0", "title": "Update Parallex",
      "body": "0.17.1 fixes the window growing taller than the screen.", "link": "https://parallex.mandip.dev" }
  ]
}
```

- `level`: `warning` (copies have trouble) or `unsupported` (they don't work).
- `versions` / `parallex`: `*`, `4.2`, `<4.2`, `<=4.2`, `>4.2`, `>=4.2` or `4.1...4.3`, comma-separated for several; missing means all.
- `website`: offered as a website instance instead.
- Raise `issued` with every change: Parallex ignores a file older than the one it has.

Publish with `make advisories deploy-site`. The file is signed with the
release key (together with the label `parallex advisories`), and Parallex
reads it only if the signature checks out, so no one else can change it.
