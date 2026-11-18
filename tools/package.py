"""Builds the CurseForge zip: BudgetTools and its CraftScout module, side by side.

    python tools/package.py [output folder]      (default: your Desktop)

The zip holds two top-level folders, BudgetTools/ and BudgetTools_CraftScout/,
as they must sit in Interface/AddOns. CraftScout is loaded on demand from the
BudgetTools options (off by default), so shipping it costs nothing to players
who leave it off.

Each folder gets its .toc and every file its .toc lists, plus:
  BudgetTools             Bindings.xml, Media/
  BudgetTools_CraftScout  LICENSE.txt, NOTICE.txt, docs/LICENSES.md,
                          docs/third_party/ (CraftScout is GPL-3.0; its Data/
                          files derive from ForeverDB.net (GPL-3.0 with an
                          attribution term) and WhatsTraining (MIT): see
                          NOTICE.txt in that folder)
Tests, tools, docs, git and Python files stay out.

The zip is named after the BudgetTools version (## Version in its .toc) and an
existing zip is never overwritten: raise the version first.
"""
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ADDONS = os.path.dirname(os.path.dirname(HERE))

FOLDERS = {
    "BudgetTools": ["Bindings.xml", "Media"],
    "BudgetTools_CraftScout": ["LICENSE.txt", "NOTICE.txt", "docs/LICENSES.md", "docs/third_party"],
}


def toc_info(folder):
    path = os.path.join(ADDONS, folder, folder + ".toc")
    if not os.path.isfile(path):
        sys.exit("missing: " + path)
    version, files = None, []
    with open(path, encoding="utf-8-sig") as handle:
        for raw in handle:
            line = raw.strip()
            if line.startswith("## Version:"):
                version = line.split(":", 1)[1].strip()
            elif line and not line.startswith("#"):
                files.append(line.replace("\\", "/"))
    return version, files


def collect(folder, extras):
    root = os.path.join(ADDONS, folder)
    _, listed = toc_info(folder)
    wanted = [folder + ".toc"] + listed
    for extra in extras:
        full = os.path.join(root, extra)
        if os.path.isdir(full):
            for base, _, names in os.walk(full):
                for name in sorted(names):
                    wanted.append(os.path.relpath(os.path.join(base, name), root).replace("\\", "/"))
        else:
            wanted.append(extra)
    seen, files = set(), []
    for rel in wanted:
        if rel in seen:
            continue
        seen.add(rel)
        if not os.path.isfile(os.path.join(root, rel)):
            sys.exit("%s: file listed but missing: %s" % (folder, rel))
        files.append(rel)
    return files


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.expanduser("~"), "Desktop")
    version, _ = toc_info("BudgetTools")
    if not version:
        sys.exit("BudgetTools.toc has no ## Version line")
    target = os.path.join(out_dir, "BudgetTools-%s.zip" % version)
    if os.path.exists(target):
        sys.exit("already exists, raise ## Version first: " + target)
    count = 0
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for folder, extras in FOLDERS.items():
            for rel in collect(folder, extras):
                archive.write(os.path.join(ADDONS, folder, rel), folder + "/" + rel)
                count += 1
    print("%s: %d files" % (target, count))


if __name__ == "__main__":
    main()
