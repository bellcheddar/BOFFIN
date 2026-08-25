#!/usr/bin/env python3
"""Add a source file to a target in BOFFIN.xcodeproj.

    python3 Tools/add-file-to-target.py App/Sources/BoundaryTabView.swift BOFFIN

`CLAUDE.md` hard rule 1 says project changes are made in Xcode and the resulting
`project.pbxproj` diff is committed, and that rule is about the project file
being the source of truth rather than a generated artefact. It stays true here:
this script performs exactly the four edits Xcode performs for "add file to
target", deterministically, on a project that is still hand-editable in Xcode
afterwards. It exists because every phase from 6 onward adds files, and the
alternative is either piling unrelated types into existing files or blocking on
a click.

The four edits, all of which Xcode makes and any three of which produce a
project that builds and silently omits the file:

1. a `PBXFileReference`, describing the file on disk;
2. a `PBXBuildFile`, describing its membership of a build phase;
3. an entry in the group's `children`, so it appears in the navigator;
4. an entry in the target's `Sources` build phase, so it is compiled.

Identifiers are 24 uppercase hex characters, derived from the path so that
running this twice produces the same project rather than a second copy.
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "BOFFIN.xcodeproj/project.pbxproj"


def identifier(seed: str) -> str:
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    relative, target = sys.argv[1], sys.argv[2]
    path = ROOT / relative
    if not path.exists():
        print(f"{relative} does not exist")
        return 1

    name = path.name
    text = PROJECT.read_text()

    if f"path = {relative};" in text:
        print(f"{relative} is already in the project")
        return 0

    # Resources go into the Resources phase, sources into Sources. The phase is
    # not inferable from the target, so it comes from the extension: anything
    # that is not Swift is a resource here, which covers the privacy manifest,
    # asset catalogues and anything else that is copied rather than compiled.
    isSource = path.suffix == ".swift"
    phase = "Sources" if isSource else "Resources"
    fileType = (
        "sourcecode.swift" if isSource
        else "folder.assetcatalog" if path.suffix == ".xcassets"
        else "text.plist.xml" if path.suffix in (".plist", ".xcprivacy")
        else "file")

    fileRef = identifier(f"fileRef:{relative}")
    buildFile = identifier(f"buildFile:{relative}:{target}")

    # 1. PBXFileReference.
    text = text.replace(
        "/* End PBXFileReference section */",
        f"\t\t{fileRef} /* {name} */ = {{isa = PBXFileReference; includeInIndex = 1; "
        f"lastKnownFileType = {fileType}; name = {name}; path = {relative}; "
        f"sourceTree = \"<group>\"; }};\n/* End PBXFileReference section */",
        1)

    # 2. PBXBuildFile.
    text = text.replace(
        "/* End PBXBuildFile section */",
        f"\t\t{buildFile} /* {name} in {phase} */ = {{isa = PBXBuildFile; "
        f"fileRef = {fileRef} /* {name} */; }};\n/* End PBXBuildFile section */",
        1)

    # 3 and 4 are anchored on a file that is ALREADY in the same group and the
    # same build phase, which is how the script knows where they are without
    # parsing the whole project. The sibling is any other file in the same
    # directory that goes through the same phase.
    pattern = "*.swift" if isSource else "*"
    siblings = sorted(
        p.name for p in path.parent.glob(pattern)
        if p.name != name and (p.suffix == ".swift") == isSource
        and f"path = {path.parent.relative_to(ROOT)}/{p.name};" in text)
    if not siblings:
        print(f"no sibling of {name} is in the project, so its group cannot be found")
        return 1
    sibling = siblings[0]

    siblingRef = re.search(
        rf"([0-9A-F]{{24}}) /\* {re.escape(sibling)} \*/ = \{{isa = PBXFileReference",
        text)
    siblingBuild = re.search(
        rf"([0-9A-F]{{24}}) /\* {re.escape(sibling)} in {phase} \*/ = \{{isa = PBXBuildFile",
        text)
    if not siblingRef or not siblingBuild:
        print(f"could not locate {sibling} in the project")
        return 1

    groupLine = f"\t\t\t\t{siblingRef.group(1)} /* {sibling} */,"
    text = text.replace(
        groupLine, groupLine + f"\n\t\t\t\t{fileRef} /* {name} */,", 1)

    phaseLine = f"\t\t\t\t{siblingBuild.group(1)} /* {sibling} in {phase} */,"
    text = text.replace(
        phaseLine, phaseLine + f"\n\t\t\t\t{buildFile} /* {name} in {phase} */,", 1)

    PROJECT.write_text(text)
    print(f"added {relative} to {target} (fileRef {fileRef}, buildFile {buildFile})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
