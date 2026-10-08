#!/usr/bin/env python3
"""Writes the third-party notices the app carries: the licence (and any NOTICE file) of every
Swift package it is built from and every package bundled into its web interface.

    Tools/Release/make-notices.py <output file>

Run after `swift build` and `npm ci`, which fetch the packages this reads. The Lighthouse runtime
needs nothing from here: its tarball keeps Node's and each npm package's own licence files.
"""
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[2]
package_build = root / "Packages/CrawlspaceKit/.build"
web = root / "Web"

LICENCE_NAMES = ("license", "license.txt", "license.md", "licence", "copying")
NOTICE_NAMES = ("notice", "notice.txt", "notice.md")


def find(folder, names):
    files = {path.name.lower(): path for path in folder.iterdir() if path.is_file()}
    return next((files[name] for name in names if name in files), None)


def section(title, source, folder):
    licence = find(folder, LICENCE_NAMES)
    if licence is None:
        sys.exit(f"No licence file for {title} in {folder}")
    parts = [f"{title}\n{source}\n\n{licence.read_text(errors='replace').strip()}"]
    notice = find(folder, NOTICE_NAMES)
    if notice is not None:
        parts.append(notice.read_text(errors="replace").strip())
    return "\n\n".join(parts)


sections = []

state = json.loads((package_build / "workspace-state.json").read_text())
for dependency in sorted(state["object"]["dependencies"], key=lambda d: d["packageRef"]["identity"]):
    reference = dependency["packageRef"]
    version = dependency["state"].get("checkoutState", {}).get("version") or ""
    title = f"{reference['name']} {version}".strip()
    sections.append(section(title, reference["location"], package_build / "checkouts" / dependency["subpath"]))

lock = json.loads((web / "package-lock.json").read_text())
for path, package in sorted(lock["packages"].items()):
    # Only what ships in the built interface; build tools are left out.
    if not path or package.get("dev") or package.get("devOptional"):
        continue
    name = path.removeprefix("node_modules/")
    sections.append(section(f"{name} {package.get('version', '')}".strip(), f"https://www.npmjs.com/package/{name}", web / path))

rule = "\n\n" + "-" * 78 + "\n\n"
header = ("Crawlspace includes the following open-source software. Each is used under the licence\n"
          "reproduced with it.")
pathlib.Path(sys.argv[1]).write_text(header + rule + rule.join(sections) + "\n")
print(f"Wrote notices for {len(sections)} packages to {sys.argv[1]}")
