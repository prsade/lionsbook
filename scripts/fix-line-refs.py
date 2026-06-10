#!/usr/bin/env python3
"""
fix-line-refs.py

Robust post-processor for the Lions Commentary plastex HTML output.

It fixes two things:
1. Turns bare line number markers produced by the LaTeX source
   (typically rendered as <dt>2184:</dt> inside <dl class="description">)
   into clickable links that open the corresponding line in all.html
   (the flat source view).

2. Repairs previously broken links created by the old fragile sed command
   (the ones that look like: <a href="...line2184" target="source" <dt>2184:</dt></a>).

Design goals:
- Idempotent (safe to run multiple times).
- Works on the currently mangled HTML in the repo.
- Uses 4-digit zero-padded line numbers to match the anchors in all.html
  (line0100, line0857, line2184, ...).
- Computes the correct relative path to all.html automatically
  (../all.html from lionc/, ../../all.html from lionc/pol/, etc.).
- Produces valid, nice HTML:
    <dt><a href="..." target="source" class="line-ref" data-line="2184">2184:</a></dt>
- Only depends on beautifulsoup4 (added to pyproject.toml).

Usage (from repo root):
    uv run python scripts/fix-line-refs.py
    uv run python scripts/fix-line-refs.py --input-dir lionc
    uv run python scripts/fix-line-refs.py --input-dir lionc/pol --all-html ../../all.html
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable

try:
    from bs4 import BeautifulSoup, Tag
except ImportError:
    print("ERROR: beautifulsoup4 is required. Run: uv add beautifulsoup4", file=sys.stderr)
    sys.exit(1)


# Matches a clean <dt>1234:</dt> or <dt>0857:</dt> (the ideal plastex output)
CLEAN_DT_RE = re.compile(r"^(\d{1,4}):$")

# Matches the horribly broken output of the old sed:
# <a href="../all.html#line2184" target="source" <dt>2184:</dt></a>
BROKEN_A_RE = re.compile(
    r'<a\s+href="([^"]*?#line)(\d+)"\s+target="([^"]*)"\s*<dt>(\d+):</dt></a>',
    re.IGNORECASE,
)


def zero_pad_line(num: int | str) -> str:
    """Return 4-digit zero-padded line number (matches all.html anchors)."""
    n = int(num)
    return f"{n:04d}"


def find_all_html_relative(start: Path, all_html_name: str = "all.html") -> str:
    """
    Compute a relative href from a generated HTML file to all.html.

    Examples:
        lionc/sect0010.html          -> ../all.html
        lionc/pol/sect0001.html      -> ../../all.html
        (run from inside lionc/)     -> ../all.html
    """
    # Use the directory containing the HTML file, not the file itself.
    parent = start.parent.resolve()
    try:
        parts = list(parent.parts)
        idx = parts.index("lionc")
        # How many directories are we below the 'lionc' directory itself?
        #   lionc/          (parent == .../lionc)          → levels=0 → "../all.html"
        #   lionc/pol/      (parent == .../lionc/pol)      → levels=1 → "../../all.html"
        levels = len(parts) - idx - 1
        return ("../" * (levels + 1)) + all_html_name
    except ValueError:
        # Not inside a 'lionc' tree — conservative fallback
        return f"../{all_html_name}"


def process_html_file(
    path: Path,
    all_html_href: str | None = None,
    dry_run: bool = False,
) -> bool:
    """
    Process a single plastex-generated HTML file.

    Returns True if the file was (or would be) modified.
    """
    try:
        html = path.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        print(f"  [!] Cannot read {path}: {e}")
        return False

    soup = BeautifulSoup(html, "html.parser")
    changed = False

    # ------------------------------------------------------------------
    # 0. Normalize accidents from previous bad repair runs
    #    (double <dt><dt> or <dt><dt><a> nesting we introduced while fixing)
    # ------------------------------------------------------------------
    for dt in list(soup.find_all("dt")):
        # direct child dt (not recursive to avoid deep surprises)
        inner = dt.find("dt", recursive=False)
        if inner:
            # Move inner's contents up to this dt, then remove the inner wrapper
            for child in list(inner.contents):
                dt.append(child)
            inner.decompose()
            changed = True

    # ------------------------------------------------------------------
    # 1. Repair already-broken <a ... <dt>NNN:</dt></a> constructs
    # ------------------------------------------------------------------
    for a in list(soup.find_all("a")):
        # Structural guard: the *old broken* pattern had the <a> sitting directly
        # as a child of the <dl class="description"> (masquerading as <dt>).
        # Good content has <dt> as direct child of the dl.
        parent = a.parent
        if not parent or parent.name != "dl":
            continue
        if not a.get("href") or "#line" not in (a.get("href") or ""):
            continue

        text = a.get_text(strip=True)
        if not re.fullmatch(r"\d{1,4}:", text):
            continue

        # This is (or was) a line reference anchor in the broken form.
        href = a.get("href", "")
        m = re.search(r"#line(\d+)$", href)
        if not m:
            continue

        line_num = m.group(1)
        padded = zero_pad_line(line_num)

        if all_html_href is None:
            target_href = re.sub(r"#line\d+$", f"#line{padded}", href)
        else:
            target_href = f"{all_html_href}#line{padded}"

        new_dt = soup.new_tag("dt")
        new_a = soup.new_tag(
            "a",
            href=target_href,
            target=a.get("target", "source"),
            attrs={"class": "line-ref", "data-line": line_num},
        )
        new_a.string = f"{line_num}:"
        new_dt.append(new_a)

        a.replace_with(new_dt)
        changed = True

    # ------------------------------------------------------------------
    # 2. Process clean <dt>1234:</dt> (what a fresh plastex run produces)
    # ------------------------------------------------------------------
    for dt in soup.find_all("dt"):
        text = dt.get_text(strip=True)
        m = CLEAN_DT_RE.match(text)
        if not m:
            continue

        line_num = m.group(1)
        padded = zero_pad_line(line_num)

        existing_a = dt.find("a", class_="line-ref")

        if all_html_href is None:
            rel = find_all_html_relative(path)
            target_href = f"{rel}#line{padded}"
        else:
            target_href = f"{all_html_href}#line{padded}"

        if existing_a:
            # Update href in case the relative path was previously wrong
            # (this fixes links after we improved the relative-path logic)
            if existing_a.get("href") != target_href:
                existing_a["href"] = target_href
                changed = True
            continue

        # Build clean linked version (first time)
        new_a = soup.new_tag(
            "a",
            href=target_href,
            target="source",
            attrs={"class": "line-ref", "data-line": line_num},
        )
        new_a.string = f"{line_num}:"

        dt.clear()
        dt.append(new_a)
        changed = True

    # Inject (or ensure) a minimal style for the line reference links so they
    # are visibly clickable even if the plastex theme doesn't style .line-ref.
    head = soup.head or soup.new_tag("head")
    if not soup.head:
        if soup.html:
            soup.html.insert(0, head)
        else:
            soup.insert(0, head)

    style_id = "line-ref-style"
    if not soup.find("style", id=style_id):
        style = soup.new_tag("style", id=style_id)
        style.string = (
            ".line-ref { color: #0066cc; text-decoration: none; font-weight: 500; }\n"
            ".line-ref:hover { text-decoration: underline; background-color: #f0f7ff; }\n"
        )
        head.append(style)
        changed = True

    if not changed:
        return False

    if dry_run:
        print(f"  [dry] would update {path}")
        return True

    path.write_text(str(soup), encoding="utf-8")
    print(f"  [+] fixed line references in {path}")
    return True


def iter_html_files(root: Path) -> Iterable[Path]:
    """Yield .html files under root, skipping obvious non-content dirs."""
    for p in sorted(root.rglob("*.html")):
        # Skip if it's inside a hidden or build dir we don't care about
        if any(part.startswith(".") for part in p.parts):
            continue
        yield p


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Fix line number references in plastex-generated Lions Commentary HTML."
    )
    parser.add_argument(
        "--input-dir",
        "-i",
        type=Path,
        default=Path("lionc"),
        help="Directory containing the generated .html files (default: lionc)",
    )
    parser.add_argument(
        "--all-html",
        "-a",
        type=str,
        default=None,
        help="Explicit relative path to all.html from the processed files "
             "(e.g. ../all.html). If omitted, it is computed automatically.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Only report what would be changed, do not write files.",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Print more details.",
    )
    args = parser.parse_args()

    input_dir: Path = args.input_dir
    if not input_dir.exists():
        print(f"ERROR: input directory does not exist: {input_dir}", file=sys.stderr)
        sys.exit(2)

    print(f"Scanning {input_dir} for HTML files with line references...")
    files = list(iter_html_files(input_dir))
    if not files:
        print("No .html files found.")
        return

    modified = 0
    for html_path in files:
        rel = args.all_html
        if rel is None:
            # Auto-compute per file for mixed depths (lionc/ vs lionc/pol/)
            rel = find_all_html_relative(html_path)

        if args.verbose:
            print(f"  -> {html_path} (using {rel})")

        if process_html_file(html_path, all_html_href=rel, dry_run=args.dry_run):
            modified += 1

    action = "Would modify" if args.dry_run else "Modified"
    print(f"\n{action} {modified} file(s).")


if __name__ == "__main__":
    main()
