#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
merge_snap2html.py - Consolidate two or more Snap2HTML snapshot files into one.

Snap2HTML (http://www.rlvision.com) generates self-contained HTML snapshots of a
folder tree. The snapshot data lives in a JavaScript array `dirs` where every
element is itself an array:

    [ "dirpath*0*modified date",            # item 0 (forward slashes)
      "filename*size*modified date",        # one item per file directly inside
      ...
      <int: total size of the files above>,
      "id1*id2*..."                        # indices (into dirs) of subfolders,
    ]                                      # "" when there are none

Index 0 is always the snapshot's root folder. All other folders are referenced
exactly once by their parent's subfolder list. The header stats are derived
from the data: folder count == dirs.length, file count == sum(len(e) - 3),
total size == sum(e[-2]).

This script merges snapshots of the SAME root folder:

  * folders of subsequent snapshots are appended, with every subfolder
    reference id remapped to the new indices
  * the root entry (and any folder that exists in more than one snapshot) is
    merged: file lists are unioned (by name), sizes are summed, subfolder
    references are unioned
  * header stats (N files in M folders, total size) are recomputed
  * subfolder reference lists are sorted by folder name (case-insensitive) so
    the tree view shows a natural A-Z listing, matching Snap2HTML's own
    output order (disable with --keep-order)

The first input file is used as the template for the output; everything
outside the data block and the counters is preserved byte-for-byte.

Usage:
    python3 merge_snap2html.py -o OUTPUT.html INPUT1.html INPUT2.html [INPUT3.html ...]

Example:
    python3 merge_snap2html.py -o shows/shows-A_Z.html \\
        shows/shows-A_R.html shows/shows-S_Z.html
"""

from __future__ import annotations

import argparse
import ast
import datetime
import json
import re
import sys
from pathlib import Path

MARKER_START = "Array.prototype.p = Array.prototype.push;"
MARKER_END = "delete(Array.prototype.p)"

DATA_LINE_RE = re.compile(r"^D\.p\(.*$", re.M)


class SnapshotError(Exception):
    """Raised when a file cannot be parsed or violates the expected format."""


class Snapshot:
    """A parsed Snap2HTML file: raw text, dirs data and header metadata."""

    def __init__(self, path: Path, text: str, dirs: list, meta: dict):
        self.path = path
        self.text = text
        self.dirs = dirs
        self.meta = meta

    # -- convenience accessors ---------------------------------------------

    @property
    def root_path(self) -> str:
        return self.dirs[0][0].split("*", 1)[0]

    @property
    def num_files(self) -> int:
        return sum(len(e) - 3 for e in self.dirs)

    @property
    def num_dirs(self) -> int:
        return len(self.dirs)

    @property
    def total_bytes(self) -> int:
        return sum(e[-2] for e in self.dirs)

    @staticmethod
    def path_of(entry) -> str:
        return entry[0].split("*", 1)[0]

    @staticmethod
    def name_of(entry) -> str:
        p = Snapshot.path_of(entry)
        return p.rsplit("/", 1)[-1] if "/" in p else p


def human_size(n: int) -> str:
    """Same formatting as the template's bytesToSize()."""
    kb, mb, gb, tb = 1024, 1024**2, 1024**3, 1024**4
    if 0 <= n < kb:
        return f"{n} bytes"
    if n < mb:
        return f"{n / kb:.0f} KB"
    if n < gb:
        return f"{n / mb:.1f} MB"
    if n < tb:
        return f"{n / gb:.2f} GB"
    return f"{n / tb:.2f} TB"


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def _require(condition: bool, path: Path, message: str):
    if not condition:
        raise SnapshotError(f"{path}: {message}")


def _search1(pattern: str, text: str, what: str, path: Path) -> str:
    m = re.search(pattern, text)
    _require(m is not None, path, f"could not find {what}")
    return m.group(1)


def parse_snapshot(path: Path) -> Snapshot:
    """Parse one Snap2HTML file, validating the data structure."""
    try:
        raw = path.read_bytes()
    except OSError as e:
        raise SnapshotError(f"cannot read {path}: {e}")

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        raise SnapshotError(f"{path}: file is not valid UTF-8 ({e})")

    _require(MARKER_START in text and MARKER_END in text, path,
             "does not look like a Snap2HTML snapshot (data markers missing)")

    start = text.index(MARKER_START)
    end = text.index(MARKER_END)

    dirs = []
    for line in text[start:end].split("\n"):
        stripped = line.strip()
        if not (stripped.startswith("D.p([") and stripped.endswith(")")):
            continue
        try:
            entry = ast.literal_eval(stripped[4:-1])
        except (SyntaxError, ValueError) as e:
            raise SnapshotError(f"{path}: cannot parse data line "
                                f"{stripped[:60]!r}...: {e}")
        dirs.append(entry)

    _require(len(dirs) >= 1, path, "no D.p(...) data lines found")
    _validate_dirs(dirs, path)

    meta = {
        "title": _search1(r"<title>(.*?)</title>", text, "<title>", path),
        "numberOfFiles": int(_search1(r"var numberOfFiles\s*=\s*(\d+);", text,
                                      "numberOfFiles variable", path)),
        "linkFiles": _search1(r'var linkFiles\s*=\s*([^;]+);', text,
                              "linkFiles variable", path).strip(),
        "linkProtocol": _search1(r'var linkProtocol\s*=\s*"([^"]*)";', text,
                                 "linkProtocol variable", path),
        "linkRoot": _search1(r'var linkRoot\s*=\s*"([^"]*)";', text,
                             "linkRoot variable", path),
        "sourceRoot": _search1(r'var sourceRoot\s*=\s*"([^"]*)";', text,
                               "sourceRoot variable", path),
    }

    m = re.search(r">(\d+) files in (\d+) folders\s*"
                  r'\(<span id="tot_size">(\d+)</span>\)', text)
    _require(m is not None, path, "could not find the header stats line")
    meta["statsFiles"] = int(m.group(1))
    meta["statsDirs"] = int(m.group(2))
    meta["statsBytes"] = int(m.group(3))

    # Cross-check the header counters against the actual data.
    snap = Snapshot(path, text, dirs, meta)
    _require(meta["numberOfFiles"] == snap.num_files, path,
             f"numberOfFiles is {meta['numberOfFiles']} but the data contains "
             f"{snap.num_files} files")
    _require(meta["statsFiles"] == snap.num_files, path,
             "header file count does not match the data")
    _require(meta["statsDirs"] == snap.num_dirs, path,
             "header folder count does not match the data")
    _require(meta["statsBytes"] == snap.total_bytes, path,
             "header total size does not match the data")
    _require(snap.root_path == meta["sourceRoot"], path,
             f"root entry path ({snap.root_path}) does not match "
             f"sourceRoot ({meta['sourceRoot']})")

    return snap


def _validate_dirs(dirs: list, path: Path):
    """Structural validation of a dirs array."""
    seen_paths = set()
    referenced = set()

    for idx, entry in enumerate(dirs):
        _require(isinstance(entry, list) and len(entry) >= 3, path,
                 f"dirs[{idx}] is malformed (must be a list of >= 3 items)")
        _require(isinstance(entry[0], str) and entry[0].count("*") >= 2, path,
                 f"dirs[{idx}][0] must be 'path*0*date'")
        for item in entry[1:-2]:
            _require(isinstance(item, str) and item.count("*") >= 2, path,
                     f"dirs[{idx}] has a malformed file item: {item!r}")
        _require(isinstance(entry[-2], int) and not isinstance(entry[-2], bool),
                 path, f"dirs[{idx}] size field must be an integer")
        _require(isinstance(entry[-1], str), path,
                 f"dirs[{idx}] subfolder reference field must be a string")

        p = Snapshot.path_of(entry)
        _require(p not in seen_paths, path, f"duplicate folder path: {p}")
        seen_paths.add(p)

        for ref in (int(x) for x in entry[-1].split("*") if x != ""):
            _require(0 < ref < len(dirs), path,
                     f"dirs[{idx}] references invalid subfolder id {ref}")
            _require(ref != idx, path,
                     f"dirs[{idx}] references itself")
            _require(ref not in referenced, path,
                     f"folder {ref} ({Snapshot.path_of(dirs[ref])}) is "
                     f"referenced by more than one parent")
            referenced.add(ref)

    orphans = set(range(1, len(dirs))) - referenced
    if orphans:
        names = ", ".join(Snapshot.path_of(dirs[i]) for i in sorted(orphans)[:5])
        print(f"WARNING: {path}: {len(orphans)} folder(s) are not referenced "
              f"by any parent and will not show in the tree view: {names}",
              file=sys.stderr)


# ---------------------------------------------------------------------------
# Merging
# ---------------------------------------------------------------------------

def merge_snapshots(snaps: list, sort_refs: bool = True) -> list:
    """Merge multiple snapshots (same root) into one dirs array."""
    base_path = snaps[0].root_path
    for s in snaps[1:]:
        _require(s.root_path == base_path, s.path,
                 f"root folder is {s.root_path!r} but the first snapshot uses "
                 f"{base_path!r} - only snapshots of the same root can be merged")

    merged = [list(e) for e in snaps[0].dirs]
    path_index = {Snapshot.path_of(e): i for i, e in enumerate(merged)}

    merged_folders = 0
    merged_files = 0

    for snap in snaps[1:]:
        # Pass 1: decide the target index of every incoming folder. Folders
        # whose path already exists are merged into the existing entry;
        # new folders are appended (placeholder None, filled in pass 2).
        targets = []
        for entry in snap.dirs:
            p = Snapshot.path_of(entry)
            target = path_index.get(p)
            if target is None:
                target = len(merged)
                merged.append(None)
                path_index[p] = target
            targets.append(target)

        # Pass 2: fill new entries (with remapped subfolder ids) and merge
        # entries whose path already exists.
        for i, entry in enumerate(snap.dirs):
            target = targets[i]
            child_refs = [targets[r] for r in
                          (int(x) for x in entry[-1].split("*") if x != "")]

            if merged[target] is None:
                new_entry = list(entry)
                new_entry[-1] = "*".join(str(r) for r in child_refs)
                merged[target] = new_entry
            else:
                current = merged[target]
                existing_names = {f.split("*", 1)[0] for f in current[1:-2]}
                added = [f for f in entry[1:-2]
                         if f.split("*", 1)[0] not in existing_names]
                added_size = sum(int(f.split("*", 2)[1]) for f in added)
                ref_set = ({int(x) for x in current[-1].split("*") if x != ""}
                           | set(child_refs))
                merged_folders += 1
                merged_files += len(added)
                merged[target] = ([current[0]]
                                  + current[1:-2] + added
                                  + [current[-2] + added_size,
                                     "*".join(str(r) for r in sorted(ref_set))])

    _require(all(e is not None for e in merged), snaps[0].path,
             "internal error: unfilled placeholder entries after merge")

    if sort_refs:
        # The tree view lists subfolders in reference order; sort each list by
        # folder name so the merged snapshot is ordered like Snap2HTML's own
        # output (case-insensitive A-Z).
        for entry in merged:
            if entry[-1]:
                refs = [int(x) for x in entry[-1].split("*") if x != ""]
                refs.sort(key=lambda r: Snapshot.name_of(merged[r]).lower())
                entry[-1] = "*".join(str(r) for r in refs)

    return merged


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def render_output(base: Snapshot, merged: list, input_names: list,
                  merged_folders: int) -> str:
    """Produce the output HTML from the base file's text and the merged data."""
    text = base.text

    # --- 1. replace the data block (only the D.p(...) lines) ---------------
    ds = text.index("D.p([")
    de = text.index(MARKER_END)
    region = text[ds:de]
    matches = list(DATA_LINE_RE.finditer(region))
    if not matches:
        raise SnapshotError(f"{base.path}: could not locate data lines to replace")

    last = matches[-1]
    # Detect the line terminator used by the data lines ('\n' or '\r\n').
    line_term = "\r\n" if last.group(0).endswith("\r") else "\n"
    # Cut just past the last data line's terminator. Note: when the match ends
    # with '\r', the '\r' is already consumed and the '\n' still follows.
    cut = ds + last.end() + 1

    lines = ["D.p(%s)" % json.dumps(e, ensure_ascii=False, separators=(",", ":"))
             for e in merged]
    new_block = line_term.join(lines) + line_term
    text = text[:ds] + new_block + text[cut:]

    # --- 2. update the counters --------------------------------------------
    n_files = sum(len(e) - 3 for e in merged)
    n_dirs = len(merged)
    n_bytes = sum(e[-2] for e in merged)

    text, n = re.subn(r"var numberOfFiles\s*=\s*\d+;",
                      f"var numberOfFiles = {n_files};", text, count=1)
    if n != 1:
        raise SnapshotError(f"{base.path}: numberOfFiles variable not found")

    stats_repl = (f">{n_files} files in {n_dirs} folders "
                  f'(<span id="tot_size">{n_bytes}</span>)')
    text, n = re.subn(r">\d+ files in \d+ folders\s*"
                      r'\(<span id="tot_size">\d+</span>\)',
                      stats_repl, text, count=1)
    if n != 1:
        raise SnapshotError(f"{base.path}: header stats line not found")

    # --- 3. add a provenance comment next to the original one --------------
    today = datetime.date.today().isoformat()
    names = ", ".join(input_names)
    note = (f"<!-- Merged from {len(input_names)} snapshots ({names}) "
            f"using merge_snap2html.py on {today} -->")
    text, n = re.subn(r"(?m)^(<!-- This file was generated by .*?-->\r?)$",
                      r"\1" + line_term + note, text, count=1)

    return text


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Consolidate two or more Snap2HTML snapshot files "
                    "(of the same root folder) into a single snapshot.")
    parser.add_argument("inputs", nargs="+", type=Path, metavar="INPUT",
                        help="snapshot files to merge; the first one is used "
                             "as the template for the output")
    parser.add_argument("-o", "--output", type=Path, default=Path("merged.html"),
                        help="output file (default: merged.html)")
    parser.add_argument("--keep-order", action="store_true",
                        help="keep snapshot order in folder listings instead "
                             "of sorting folders by name")
    args = parser.parse_args(argv)

    if len(args.inputs) < 2:
        parser.error("at least two input files are required")

    try:
        snaps = [parse_snapshot(p) for p in args.inputs]

        # All snapshots must link to files the same way.
        for s in snaps[1:]:
            for key in ("linkFiles", "linkProtocol", "linkRoot", "sourceRoot"):
                _require(s.meta[key] == snaps[0].meta[key], s.path,
                         f"{key} is {s.meta[key]!r} but the first snapshot "
                         f"uses {snaps[0].meta[key]!r}")
            if s.meta["title"] != snaps[0].meta["title"]:
                print(f"NOTE: {s.path}: title differs from the first snapshot; "
                      f"keeping {snaps[0].meta['title']!r}", file=sys.stderr)

        merged = merge_snapshots(snaps, sort_refs=not args.keep_order)
        output_text = render_output(snaps[0], merged,
                                    [p.name for p in args.inputs], 0)

        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(output_text.encode("utf-8"))

        # --- verify the result by re-parsing it ---------------------------
        result = parse_snapshot(args.output)
        expected_paths = {Snapshot.path_of(e) for s in snaps for e in s.dirs}
        actual_paths = {Snapshot.path_of(e) for e in result.dirs}
        if expected_paths != actual_paths:
            missing = expected_paths - actual_paths
            extra = actual_paths - expected_paths
            raise SnapshotError(f"verification failed: folder set mismatch "
                                f"(missing: {sorted(missing)[:3]}, "
                                f"unexpected: {sorted(extra)[:3]})")

        print(f"Merged {len(args.inputs)} snapshots into {args.output}")
        parts = " + ".join(str(s.num_dirs) for s in snaps)
        print(f"  Folders: {parts} -> {result.num_dirs} "
              f"({snaps[0].num_dirs + sum(s.num_dirs for s in snaps[1:]) - result.num_dirs} root/duplicate merged)")
        parts = " + ".join(str(s.num_files) for s in snaps)
        print(f"  Files:   {parts} -> {result.num_files}")
        print(f"  Total:   {human_size(result.total_bytes)}")
        print(f"  Output verified OK (all {result.num_dirs} folders reachable, "
              f"references and counters consistent).")

    except SnapshotError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
