#!/usr/bin/env python3
"""Refresh public, licensed capability metadata. Never reads a vault or sends account data.
Pass --retrieved-at from the handoff system clock; output is reviewed and shipped with the app.
"""
import argparse
import datetime
import io
import json
import pathlib
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "crates/vault-core/data"


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "PasswordVault-security-catalog"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(64 * 1024 * 1024 + 1)
    if len(data) > 64 * 1024 * 1024:
        raise ValueError("Upstream response exceeds limit")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--retrieved-at", required=True)
    args = parser.parse_args()
    datetime.date.fromisoformat(args.retrieved_at)
    sites = {}
    sources = []
    licenses = {}
    for repo, feature, license_name in [("twofactorauth", "twoFactor", "MIT"), ("passkeys", "passkey", "CC-BY-4.0")]:
        revision = json.loads(fetch(f"https://api.github.com/repos/2factorauth/{repo}/commits/HEAD"))["sha"]
        archive = tarfile.open(fileobj=io.BytesIO(fetch(f"https://codeload.github.com/2factorauth/{repo}/tar.gz/{revision}")), mode="r:gz")
        source_url = f"https://github.com/2factorauth/{repo}/tree/{revision}"
        sources.append({"name": f"2factorauth/{repo}", "url": source_url, "revision": revision, "license": license_name, "retrievedAt": args.retrieved_at})
        for member in archive:
            parts = pathlib.PurePosixPath(member.name).parts
            if not member.isfile():
                continue
            if len(parts) == 2 and parts[-1] == "LICENSE.md":
                licenses[f"{repo}-LICENSE.md"] = archive.extractfile(member).read().decode()
            if len(parts) < 3 or parts[1] != "entries" or not parts[-1].endswith(".json"):
                continue
            content = json.load(archive.extractfile(member))
            for name, entry in content.items():
                host = entry.get("domain") or (parts[-1][:-5] if feature == "passkey" else None)
                if not host or "/" in host or ":" in host:
                    continue
                enabled = bool(entry.get("tfa")) if feature == "twoFactor" else True
                if not enabled:
                    continue
                permalink = f"https://github.com/2factorauth/{repo}/blob/{revision}/{'/'.join(parts[1:])}"
                site = sites.setdefault(host.lower(), {"host": host.lower(), "name": name, "verifiedAt": args.retrieved_at, "source": permalink})
                site[feature] = True
                site[f"{feature}Source"] = entry.get("documentation") if str(entry.get("documentation", "")).startswith("https://") else permalink
    if len(sites) < 100 or sum(bool(v.get("passkey")) for v in sites.values()) < 10 or len(licenses) != 2:
        raise ValueError("Incomplete upstream snapshot")
    catalog = {"version": 1, "updatedAt": args.retrieved_at, "license": "2FA data: MIT; Passkey data: CC-BY-4.0; see bundled licenses and source attribution", "coverage": "community-maintained, incomplete; absence is unknown", "sources": sources, "changes": "Normalized domain and capability booleans; omitted icons and other fields. No account configuration or breach status is inferred.", "sites": sorted(sites.values(), key=lambda value: value["host"])}
    DESTINATION.mkdir(parents=True, exist_ok=True)
    for filename, license_text in licenses.items():
        (DESTINATION / filename).write_text(license_text)
    (DESTINATION / "security-catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"Wrote {len(sites)} domains with pinned source revisions and license texts")


if __name__ == "__main__":
    main()
