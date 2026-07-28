#!/usr/bin/env python3
"""Verify every documentation link and sidebar entry resolves to a real page.

`bun run docs:build` renders whatever it is given; it does not notice that
`/features/langauge` has no page behind it, or that a sidebar entry points at a
file someone renamed. A dead link in a status page is the same class of problem
as a stale number: the page looks authoritative and is wrong.

Three link kinds are checked, each against the thing it actually resolves
against:

  * site-absolute links inside `docs/` (`/advanced/embedding`) -> a matching
    `docs/**/<path>.md` or `docs/**/<path>/index.md`;
  * relative links inside `docs/` (`./api.md`, `../.data/run.tsv`) -> a real
    path next to the referring file;
  * repo-relative links in the root Markdown files and in `.claude/skills/`
    (`docs/features/index.md`, `../../../src/gc.zig`) -> a real repo path.

Anchors (`#section`) are stripped before resolution; their targets are not
verified. External `http(s)://` and `mailto:` links are skipped — this gate is
about internal consistency, not reachability of the internet.

Sidebar entries come from `docs.config.ts`, parsed with a link regex rather than
by executing TypeScript, so this stays a dependency-free Python gate.

Usage:
  tools/docs-link-check.py [--quiet]

Exit status is 1 when any link fails to resolve.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
CONFIG = ROOT / "docs.config.ts"

# Root-level Markdown that links into the repository by relative path.
ROOT_DOCS = ["README.md", "CONTRIBUTING.md", "CLAUDE.md"]
SKILL_GLOB = ".claude/skills/**/*.md"

# `[text](target)` — target stops at whitespace or the closing paren, so titled
# links (`[t](/a "Title")`) keep only the path.
LINK = re.compile(r"\[[^\]]*\]\(\s*([^)\s]+)")
# `link: '/features/'` in docs.config.ts.
SIDEBAR_LINK = re.compile(r"link:\s*['\"]([^'\"]+)['\"]")

SKIP_PREFIXES = ("http://", "https://", "mailto:", "#", "data:", "tel:")


def is_external(target: str) -> bool:
    return target.startswith(SKIP_PREFIXES)


def strip_fragment(target: str) -> str:
    return target.split("#", 1)[0].split("?", 1)[0]


def resolve_site_absolute(target: str) -> bool:
    """A `/features/language` style link, resolved against `docs/`."""
    rel = target.strip("/")
    if not rel:
        return (DOCS / "index.md").exists()
    return (DOCS / f"{rel}.md").exists() or (DOCS / rel / "index.md").exists()


def check_file(path: Path, *, site_absolute_root: bool) -> list[str]:
    """Return a list of failure messages for one Markdown file."""
    failures: list[str] = []
    text = path.read_text(encoding="utf-8", errors="replace")
    for raw in LINK.findall(text):
        if is_external(raw):
            continue
        target = strip_fragment(raw)
        if not target:
            continue  # pure anchor
        if target.startswith("/"):
            if site_absolute_root:
                ok = resolve_site_absolute(target)
            else:
                # An absolute path outside the docs site is a filesystem path,
                # which is never what a repo-relative document means.
                ok = False
            if not ok:
                failures.append(f"{path.relative_to(ROOT)} -> {raw}")
            continue
        if not (path.parent / target).exists():
            failures.append(f"{path.relative_to(ROOT)} -> {raw}")
    return failures


def check_sidebar() -> list[str]:
    if not CONFIG.exists():
        return [f"{CONFIG.name} not found"]
    failures = []
    for target in SIDEBAR_LINK.findall(CONFIG.read_text(encoding="utf-8")):
        if is_external(target):
            continue
        if not resolve_site_absolute(strip_fragment(target)):
            failures.append(f"docs.config.ts -> {target}")
    return failures


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--quiet", action="store_true", help="only print failures")
    args = ap.parse_args()

    failures: list[str] = []
    checked = 0

    for md in sorted(DOCS.rglob("*.md")):
        failures += check_file(md, site_absolute_root=True)
        checked += 1

    for name in ROOT_DOCS:
        path = ROOT / name
        if path.exists():
            failures += check_file(path, site_absolute_root=False)
            checked += 1

    for md in sorted(ROOT.glob(SKILL_GLOB)):
        failures += check_file(md, site_absolute_root=False)
        checked += 1

    failures += check_sidebar()

    if failures:
        print(f"docs-link-check: {len(failures)} unresolved link(s)", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1

    if not args.quiet:
        print(f"docs-link-check: {checked} files, all links resolve")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
