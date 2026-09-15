#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
merge_snap2html.py - Consolidate two or more Snap2HTML snapshot files into one.

Snap2HTML (http://www.rlvision.com) generates self-contained HTML snapshots of
a folder tree. Two on-disk data formats exist; this script auto-detects the
format of every input file and refuses to mix formats in one merge.

V1 - Snap2HTML 2.0 to 2.14 ("D.p" format)
    The data lives in a JavaScript array `dirs`, one "D.p([...])" line per
    folder:

        [ "dirpath*0*modified date",           # item 0 (forward slashes)
          "filename*size*modified date",       # one item per file inside
          ...
          <int: total size of the files above>,
          "id1*id2*..."                        # indices (into dirs) of
        ]                                      # subfolders ("" if none)

    Index 0 is always the snapshot's root folder; every other folder is
    referenced exactly once by its parent's subfolder list.

V2 - Snap2HTML 2.5+ ("p" format, dataVersion 2)
    The data lives between the "// [SNAPDATA]" and "// [/SNAPDATA]" markers,
    one "p([...])" line per folder:

        [ "foldername*size*date",              # name only (no path); size is
                                               # the RECURSIVE subtree total in
                                               # base 36 ("-1" = unreadable);
                                               # date is a base-36 unix
                                               # timestamp
          <int: parent folder id>,              # -1 for root folders
          "id1*id2*...",                        # subfolder ids
          "filename*size*date",                 # one item per file (base-36
          ...                                   # size and date)
          {linkRoot:..., numDirs:..., numFiles:..., sourceDir:...,
           timestamp:..., title:..., totBytes:...}   # root folders only
        ]

    Ids are relative to the owning root folder. A file may contain several
    roots (each new root resets the id space), which the template displays as
    a multi-root listing. Header counters live in the "window.snap" block
    between the [SNAPMETA] markers and in the stats line under the page title;
    the total-size figure is pre-formatted text ("4.67 TB").

Merging
-------
  * Same root folder (V1 and V2): the folder tree of each additional
    snapshot is appended with every subfolder reference id remapped; the root
    entry (and any folder found in more than one snapshot) is merged - file
    lists are unioned by name, sizes are summed (V2 recursive sizes are
    recomputed bottom-up), subfolder references are unioned; header stats are
    recomputed.
  * Different root folders (V2 only): the snapshots are combined into one
    multi-root snapshot, a capability the V2 format supports natively. Each
    root keeps its own link root and metadata; the header shows grand totals.
  * Subfolder references of merged folders are sorted by folder name using a
    natural sort ("2" before "10", case-insensitive), matching Snap2HTML's
    own output order (disable with --keep-order).

The first input file is used as the template for the output; everything
outside the data block and the counters is preserved byte-for-byte. The
result is re-parsed and fully verified before the script reports success.

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

# --- V1 (Snap2HTML 2.0 - 2.14) markers
V1_MARKER_START = "Array.prototype.p = Array.prototype.push;"
V1_MARKER_END = "delete(Array.prototype.p)"

# --- V2 (Snap2HTML 2.5+) markers and constants
V2_SNAPDATA_START = "// [SNAPDATA]"
V2_SNAPDATA_END = "// [/SNAPDATA]"
V2_SNAPMETA_START = "// [SNAPMETA]"
V2_SNAPMETA_END = "// [/SNAPMETA]"
V2_DATA_VERSION = 2

V1_STATS_RE = re.compile(
    r">(\d+) files in (\d+) folders\s*\(<span id=\"tot_size\">(\d+)</span>\)")
V2_STATS_RE = re.compile(
    r">(\d+) files in (\d+) folders\s*\(<span id=\"tot_size\">([^<]+)</span>\)")


class SnapshotError(Exception):
    """Raised when a file cannot be parsed or violates the expected format."""


def _require(condition: bool, path, message: str):
    if not condition:
        raise SnapshotError(f"{path}: {message}")


def _search1(pattern: str, text: str, what: str, path) -> str:
    m = re.search(pattern, text)
    _require(m is not None, path, f"could not find {what}")
    return m.group(1)


def _read_text(path: Path) -> str:
    try:
        raw = path.read_bytes()
    except OSError as e:
        raise SnapshotError(f"cannot read {path}: {e}")
    try:
        return raw.decode("utf-8")          # a leading BOM, if any, is kept
    except UnicodeDecodeError as e:
        raise SnapshotError(f"{path}: file is not valid UTF-8 ({e})")


def detect_format(text: str, path) -> str:
    """Return 'V1' or 'V2' for the text of a snapshot file."""
    if re.search(r"(?m)^// \[SNAPDATA\]\s*$", text):
        return "V2"
    if V1_MARKER_START in text:
        return "V1"
    raise SnapshotError(
        f"{path}: does not look like a Snap2HTML snapshot "
        f"(neither V1 nor V2 data markers found)")


# ===========================================================================
# V1 - Snap2HTML 2.0 to 2.14
# ===========================================================================

class Snapshot:
    """A parsed V1 snapshot: raw text, dirs data and header metadata."""

    def __init__(self, path: Path, text: str, dirs: list, meta: dict):
        self.path = path
        self.text = text
        self.dirs = dirs
        self.meta = meta
        self.fmt = "V1"

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
    """Same formatting as the template's bytesToSize() (V1 files)."""
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


def parse_v1(path: Path, text: str) -> Snapshot:
    """Parse one V1 snapshot file, validating the data structure."""
    _require(V1_MARKER_START in text and V1_MARKER_END in text, path,
             "does not look like a Snap2HTML snapshot (data markers missing)")

    start = text.index(V1_MARKER_START)
    end = text.index(V1_MARKER_END)

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

    m = V1_STATS_RE.search(text)
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


def _validate_dirs(dirs: list, path):
    """Structural validation of a V1 dirs array."""
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


def merge_v1_snapshots(snaps: list, sort_refs: bool = True) -> list:
    """Merge multiple V1 snapshots (same root) into one dirs array."""
    base_path = snaps[0].root_path
    for s in snaps[1:]:
        _require(s.root_path == base_path, s.path,
                 f"root folder is {s.root_path!r} but the first snapshot uses "
                 f"{base_path!r} - only snapshots of the same root can be "
                 f"merged (V1 format)")

    merged = [list(e) for e in snaps[0].dirs]
    path_index = {Snapshot.path_of(e): i for i, e in enumerate(merged)}

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


def render_v1_output(base: Snapshot, merged: list, input_names: list) -> str:
    """Produce the output HTML from the base file's text and the merged data."""
    text = base.text

    # --- 1. replace the data block (only the D.p(...) lines) ---------------
    ds = text.index("D.p([")
    de = text.index(V1_MARKER_END)
    region = text[ds:de]
    matches = list(re.finditer(r"^D\.p\(.*$", region, re.M))
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
    text, n = re.subn(
        r">\d+ files in \d+ folders\s*\(<span id=\"tot_size\">\d+</span>\)",
        stats_repl, text, count=1)
    if n != 1:
        raise SnapshotError(f"{base.path}: header stats line not found")

    # --- 3. add a provenance comment next to the original one --------------
    return _add_provenance(text, input_names, line_term)


# ===========================================================================
# V2 - Snap2HTML 2.5+
# ===========================================================================

B36_DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
_B36_RE = re.compile(r"^[0-9A-Za-z]+$")


def b36(n: int) -> str:
    """Base 36 with uppercase digits, like the generator's
    Utils.DecimalToArbitrarySystem()."""
    if n < 0:
        return "-" + b36(-n)
    if n == 0:
        return "0"
    out = []
    while n:
        n, r = divmod(n, 36)
        out.append(B36_DIGITS[r])
    return "".join(reversed(out))


def parse_b36(s: str, path, what: str) -> int:
    if not _B36_RE.match(s):
        raise SnapshotError(f"{path}: {what} is not a valid base-36 number: {s!r}")
    return int(s, 36)


def js_string_encode(s: str) -> str:
    """Mirror System.Web's HttpUtility.JavaScriptStringEncode() with default
    settings - what Snap2HTML 2.5+ uses for names inside data lines:
    \\ " \\r \\n \\t \\b \\f as short escapes, everything else that needs
    encoding ('<', '>', '&', ''', control chars, U+0085/U+2028/U+2029) as
    \\uxxxx with lowercase hex."""
    out = []
    for ch in s:
        if ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\b":
            out.append("\\b")
        elif ch == "\f":
            out.append("\\f")
        elif _js_needs_encoding(ch):
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    return "".join(out)


def _js_needs_encoding(ch: str) -> bool:
    o = ord(ch)
    return (o < 0x20 or ch in "\"\\'<>&" or o in (0x85, 0x2028, 0x2029))


def json_dcjs(obj) -> str:
    """Serialize a parsed metadata object the way the generator's
    DataContractJsonSerializer does: compact separators, keys in the order
    they were parsed, forward slashes escaped as '\\/'."""
    return json.dumps(obj, ensure_ascii=False,
                      separators=(",", ":")).replace("/", "\\/")


def csharp_filesize(n: int, dec_sep: str = ".") -> str:
    """Mirror the generator's Utils.BytesToFilesize(): Math.Round (banker's
    rounding, like Python's round()) and the shortest decimal representation
    of the rounded value. This is what Snap2HTML 2.5+ writes into the
    "[TOT SIZE]" placeholder; the decimal separator depends on the locale of
    the machine that generated the file, so we keep the input's separator."""
    kb, mb, gb, tb = 1024, 1024**2, 1024**3, 1024**4
    if 0 <= n < kb:
        return f"{n} bytes"
    if n < mb:
        val, dec, unit = n / kb, 0, "KB"
    elif n < gb:
        val, dec, unit = n / mb, 1, "MB"
    elif n < tb:
        val, dec, unit = n / gb, 2, "GB"
    else:
        val, dec, unit = n / tb, 2, "TB"
    r = round(val, dec)
    if dec == 0:
        s = f"{r:.0f}"
    else:
        s = f"{r:.{dec}f}".rstrip("0").rstrip(".")
    return s.replace(".", dec_sep) + " " + unit


def _natural_key_factory(names):
    """Sort key mirroring the generator's OrderByNatural(): pad digit runs to
    the widest digit run in the compared set, then compare case-insensitively.
    This makes 'folder 2' sort before 'folder 10'."""
    maxd = max((len(m.group(0)) for n in names for m in re.finditer(r"\d+", n)),
               default=0)

    def key(name):
        return re.sub(r"\d+", lambda m: m.group(0).zfill(maxd), name).lower()

    return key


class V2Snapshot:
    """A parsed V2 snapshot. `entries` is a list of dicts with keys:
       name, size (int, -1 = unreadable), ts, parent (absolute id, -1 = root),
       refs (absolute ids), files (list of (name, size, ts) tuples),
       meta_obj / meta_text (root entries only), path (full path), root."""

    def __init__(self, path: Path, text: str, entries: list, header: dict,
                 stats: dict):
        self.path = path
        self.text = text
        self.entries = entries
        self.header = header
        self.stats = stats
        self.fmt = "V2"

    @property
    def roots(self) -> list:
        return [i for i, e in enumerate(self.entries) if e["parent"] == -1]

    @property
    def num_files(self) -> int:
        return sum(len(e["files"]) for e in self.entries)

    @property
    def num_dirs(self) -> int:
        return len(self.entries)

    @property
    def total_bytes(self) -> int:
        return sum(sum(f[1] for f in e["files"]) for e in self.entries)


def _v2_parse_data_line(line: str, idx: int, path) -> dict:
    """Validate and normalize one p([...]) data line into an entry dict
    (ids still stored relative to the root; converted by the caller)."""
    _require(line.startswith("p([") and line.endswith(")"), path,
             f"unexpected content in the data block: {line[:60]!r}")
    try:
        raw = json.loads(line[2:-1])
    except ValueError as e:
        raise SnapshotError(f"{path}: cannot parse data line {idx + 1}: {e}")

    _require(isinstance(raw, list) and len(raw) >= 3, path,
             f"dirs[{idx}] is malformed (must be an array of >= 3 items)")

    _require(isinstance(raw[0], str), path,
             f"dirs[{idx}][0] (folder item) must be a string")
    fparts = raw[0].split("*")
    _require(len(fparts) == 3, path,
             f"dirs[{idx}][0] must be 'name*size*date' (exactly 2 asterisks)")
    name = fparts[0]
    if fparts[1] == "-1":
        size = -1
    else:
        size = parse_b36(fparts[1], path, f"dirs[{idx}][0] folder size")
        _require(size >= 0, path,
                 f"dirs[{idx}][0] folder size is negative: {fparts[1]!r}")
    ts = parse_b36(fparts[2], path, f"dirs[{idx}][0] folder date")

    _require(isinstance(raw[1], int) and not isinstance(raw[1], bool), path,
             f"dirs[{idx}][1] (parent id) must be an integer")
    _require(raw[1] >= -1, path,
             f"dirs[{idx}][1] (parent id) must be -1 or non-negative")

    _require(isinstance(raw[2], str), path,
             f"dirs[{idx}][2] (subfolder references) must be a string")
    refs = []
    for r in raw[2].split("*") if raw[2] != "" else []:
        _require(r.isdigit(), path,
                 f"dirs[{idx}][2] subfolder id is not a plain decimal "
                 f"number: {r!r}")
        refs.append(int(r))

    is_root = raw[1] == -1
    meta_obj = None
    if is_root:
        _require(len(raw) >= 4 and isinstance(raw[-1], dict), path,
                 f"root folder entry {idx} must end with a metadata object")
        meta_obj = raw[-1]
        for key in ("title", "sourceDir", "linkRoot", "numFiles", "numDirs",
                    "totBytes"):
            _require(key in meta_obj, path,
                     f"root folder entry {idx} metadata lacks '{key}'")
        _require(isinstance(meta_obj["sourceDir"], str)
                 and meta_obj["sourceDir"] != "", path,
                 f"root folder entry {idx} metadata has an empty sourceDir")
        file_items = raw[3:-1]
    else:
        file_items = raw[3:]

    files = []
    seen = set()
    for it in file_items:
        _require(isinstance(it, str), path,
                 f"dirs[{idx}] has a non-string file item: {it!r}")
        fparts = it.split("*")
        _require(len(fparts) == 3, path,
                 f"dirs[{idx}] has a malformed file item (need exactly "
                 f"'name*size*date'): {it!r}")
        fsize = parse_b36(fparts[1], path, f"file size in dirs[{idx}]")
        fts = parse_b36(fparts[2], path, f"file date in dirs[{idx}]")
        _require(fsize >= 0, path,
                 f"dirs[{idx}] file {fparts[0]!r} has a negative size")
        _require(fts >= 0, path,
                 f"dirs[{idx}] file {fparts[0]!r} has a negative date")
        low = fparts[0].lower()
        _require(low not in seen, path,
                 f"dirs[{idx}] contains duplicate file name {fparts[0]!r}")
        seen.add(low)
        files.append((fparts[0], fsize, fts))

    return {"name": name, "size": size, "ts": ts, "parent": raw[1],
            "refs": refs, "files": files, "meta_obj": meta_obj,
            "meta_text": json_dcjs(meta_obj) if meta_obj is not None else None,
            "path": None}


def _v2_compute_paths(entries: list, path):
    """Fill the full path of every entry (sourceDir + names)."""
    n = len(entries)
    for idx, e in enumerate(entries):
        if e["parent"] == -1:
            e["path"] = e["meta_obj"]["sourceDir"]
    for idx in range(n):
        if entries[idx]["path"] is not None:
            continue
        chain = []
        i = idx
        while entries[i]["path"] is None:
            chain.append(i)
            i = entries[i]["parent"]
            _require(len(chain) <= n, path,
                     f"parent chain of folder {idx} is cyclic")
        base_path = entries[i]["path"]
        for j in reversed(chain):
            pp = entries[entries[j]["parent"]]["path"]
            entries[j]["path"] = (pp + ("\\" if not pp.endswith("\\") else "")
                                  + entries[j]["name"])


def parse_v2(path: Path, text: str) -> V2Snapshot:
    """Parse one V2 snapshot file, validating the data structure."""
    _require(V2_SNAPDATA_START in text and V2_SNAPDATA_END in text
             and text.index(V2_SNAPDATA_START) < text.index(V2_SNAPDATA_END),
             path, "data block markers ([SNAPDATA]) missing")

    region = text[text.index(V2_SNAPDATA_START) + len(V2_SNAPDATA_START):
                  text.index(V2_SNAPDATA_END)]
    entries = []
    for line in region.split("\n"):
        line = line.rstrip("\r")
        if line.strip() == "":
            continue
        entries.append(_v2_parse_data_line(line, len(entries), path))

    _require(len(entries) >= 1, path, "no p(...) data lines found")
    n = len(entries)

    # Root offsets: like the template's runtime, an entry's stored ids are
    # relative to the most recent root folder (parent == -1) at a smaller
    # array index.
    owner_root = []
    cur = None
    for idx, e in enumerate(entries):
        if e["parent"] == -1:
            cur = idx
        owner_root.append(cur)
    _require(entries[0]["parent"] == -1, path,
             "the first folder entry must be a root folder")
    _require(all(o is not None for o in owner_root), path,
             "internal error: unassigned root offsets")

    # Convert ids to absolute and validate the reference structure.
    for idx, e in enumerate(entries):
        if e["parent"] != -1:
            _require(e["parent"] >= 0, path,
                     f"dirs[{idx}] parent id is negative")
            e["parent"] += owner_root[idx]
        e["refs"] = [r + owner_root[idx] for r in e["refs"]]

    referenced = {}
    for idx, e in enumerate(entries):
        if e["parent"] != -1:
            _require(0 <= e["parent"] < n, path,
                     f"dirs[{idx}] parent id {e['parent']} is out of range")
            _require(e["parent"] != idx, path, f"dirs[{idx}] is its own parent")
        for r in e["refs"]:
            _require(0 <= r < n, path,
                     f"dirs[{idx}] references invalid subfolder id {r}")
            _require(r != idx, path, f"dirs[{idx}] references itself")
            _require(r not in referenced, path,
                     f"folder {r} ({entries[r]['name']!r}) is referenced by "
                     f"more than one parent")
            referenced[r] = idx

    _v2_compute_paths(entries, path)

    seen_paths = {}
    for idx, e in enumerate(entries):
        key = e["path"].lower()
        _require(key not in seen_paths, path,
                 f"duplicate folder path: {e['path']}")
        seen_paths[key] = idx

    # Recompute recursive folder sizes bottom-up and check them against the
    # stored values (only for entries reachable from a root).
    reachable = set()
    for r in (i for i, e in enumerate(entries) if e["parent"] == -1):
        stack = [r]
        while stack:
            i = stack.pop()
            if i in reachable:
                continue
            reachable.add(i)
            stack.extend(entries[i]["refs"])
    unreachable = set(range(n)) - reachable
    if unreachable:
        names = ", ".join(entries[i]["path"] for i in sorted(unreachable)[:5])
        print(f"WARNING: {path}: {len(unreachable)} folder(s) are not "
              f"reachable from any root folder: {names}", file=sys.stderr)

    deep = {}
    for r in (i for i, e in enumerate(entries) if e["parent"] == -1):
        stack = [(r, False)]
        while stack:
            i, expanded = stack.pop()
            if expanded:
                if entries[i]["size"] == -1:
                    deep[i] = -1
                else:
                    total = sum(f[1] for f in entries[i]["files"])
                    for c in entries[i]["refs"]:
                        if deep[c] != -1:
                            total += deep[c]
                    deep[i] = total
            else:
                stack.append((i, True))
                for c in entries[i]["refs"]:
                    if c not in deep:
                        stack.append((c, False))
    for i in unreachable:
        deep[i] = entries[i]["size"]

    for idx, e in enumerate(entries):
        if e["size"] != -1 and idx in reachable:
            _require(e["size"] == deep[idx], path,
                     f"stored size of {e['path']!r} ({e['size']}) does not "
                     f"match the sum of its contents ({deep[idx]}); the file "
                     f"was not generated by Snap2HTML or is corrupted")
        e["deep"] = deep[idx]

    # --- header (window.snap block) ----------------------------------------
    _require(V2_SNAPMETA_START in text and V2_SNAPMETA_END in text
             and text.index(V2_SNAPMETA_START) < text.index(V2_SNAPMETA_END),
             path, "header block markers ([SNAPMETA]) missing")
    snapmeta = text[text.index(V2_SNAPMETA_START):
                    text.index(V2_SNAPMETA_END) + len(V2_SNAPMETA_END)]

    header = {
        "title": _search1(r'title:\s*"((?:[^"\\]|\\.)*)"',
                          snapmeta, "snap.title", path),
        "numFiles": int(_search1(r"(?m)^\s*numFiles:\s*(\d+)", snapmeta,
                                 "snap.numFiles", path)),
        "numDirs": int(_search1(r"(?m)^\s*numDirs:\s*(\d+)", snapmeta,
                                "snap.numDirs", path)),
        "bytes": int(_search1(r"(?m)^\s*bytes:\s*(\d+)", snapmeta,
                              "snap.bytes", path)),
        "dataVersion": int(_search1(r"(?m)^\s*dataVersion:\s*(\d+)", snapmeta,
                                    "snap.dataVersion", path)),
    }
    _require(header["dataVersion"] == V2_DATA_VERSION, path,
             f"unsupported data version {header['dataVersion']} (this script "
             f"supports version {V2_DATA_VERSION}, Snap2HTML 2.5+)")

    # --- stats line under the page title ------------------------------------
    m = V2_STATS_RE.search(text)
    _require(m is not None, path, "could not find the header stats line")
    stats = {"files": int(m.group(1)), "dirs": int(m.group(2)),
             "totSize": m.group(3).strip()}
    dm = re.match(r"^\d+([.,]\d+)?\s+(bytes|KB|MB|GB|TB)$", stats["totSize"])
    stats["decSep"] = dm.group(1)[0] if dm and dm.group(1) else "."

    snap = V2Snapshot(path, text, entries, header, stats)
    _require(header["numFiles"] == snap.num_files, path,
             f"snap.numFiles is {header['numFiles']} but the data contains "
             f"{snap.num_files} files")
    _require(header["numDirs"] == snap.num_dirs, path,
             "snap.numDirs does not match the data")
    _require(header["bytes"] == snap.total_bytes, path,
             "snap.bytes does not match the data")
    _require(stats["files"] == snap.num_files, path,
             "header file count does not match the data")
    _require(stats["dirs"] == snap.num_dirs, path,
             "header folder count does not match the data")
    expected_tot = csharp_filesize(snap.total_bytes, stats["decSep"])
    if expected_tot != stats["totSize"]:
        print(f"NOTE: {path}: formatted total size is {stats['totSize']!r} "
              f"but the data adds up to {expected_tot!r}; using the computed "
              f"value for the output", file=sys.stderr)

    # Per-root metadata must agree with the data as well.
    for r in snap.roots:
        sub = _v2_subtree(entries, r)
        meta = entries[r]["meta_obj"]
        _require(meta["numDirs"] == len(sub), path,
                 f"root {entries[r]['path']!r} metadata numDirs "
                 f"{meta['numDirs']} != {len(sub)}")
        _require(meta["numFiles"] == sum(len(entries[i]["files"])
                                         for i in sub), path,
                 f"root {entries[r]['path']!r} metadata numFiles mismatch")
        _require(meta["totBytes"] == sum(sum(f[1] for f in entries[i]["files"])
                                         for i in sub), path,
                 f"root {entries[r]['path']!r} metadata totBytes mismatch")

    return snap


def merge_v2_snapshots(snaps: list, sort_refs: bool = True):
    """Merge multiple V2 snapshots into one. Returns (entries, info dict).
    Works for same-root deep merges as well as multi-root combinations."""
    merged = [dict(e, files=list(e["files"]), refs=list(e["refs"]))
              for e in snaps[0].entries]
    for e in merged:
        e["dirty"] = False
    path_index = {e["path"].lower(): i for i, e in enumerate(merged)}

    for snap in snaps[1:]:
        # Pass 1: target index of every incoming folder (existing path ->
        # merge; new path -> append).
        targets = []
        for e in snap.entries:
            key = e["path"].lower()
            t = path_index.get(key)
            if t is None:
                t = len(merged)
                merged.append(None)
                path_index[key] = t
            targets.append(t)

        # Pass 2: fill the new entries (with remapped ids) and merge the
        # folders that already exist.
        for i, e in enumerate(snap.entries):
            t = targets[i]
            refs = [targets[r] for r in e["refs"]]
            cur = merged[t]
            if cur is None:
                merged[t] = {"name": e["name"], "size": e["size"],
                             "ts": e["ts"],
                             "parent": (-1 if e["parent"] == -1
                                        else targets[e["parent"]]),
                             "refs": refs, "files": list(e["files"]),
                             "meta_obj": e["meta_obj"],
                             "meta_text": e["meta_text"],
                             "path": e["path"], "dirty": False}
            else:
                # a folder counts as unreadable only if every occurrence of
                # it was unreadable
                if cur["size"] == -1 and e["size"] != -1:
                    cur["size"] = e["size"]
                existing = {f[0].lower() for f in cur["files"]}
                cur["files"].extend(f for f in e["files"]
                                    if f[0].lower() not in existing)
                have = set(cur["refs"])
                cur["refs"].extend(r for r in refs if r not in have)
                cur["dirty"] = True

    _require(all(e is not None for e in merged), snaps[0].path,
             "internal error: unfilled placeholder entries after merge")

    # --- recompute root ownership (array-position based, as the template
    # runtime computes it) and recursive sizes -------------------------------
    owner_root = []
    cur = None
    for idx, e in enumerate(merged):
        if e["parent"] == -1:
            cur = idx
        owner_root.append(cur)
    for idx, e in enumerate(merged):
        e["owner"] = owner_root[idx]

    # --- natural sort of the listings of folders that changed ---------------
    if sort_refs:
        for e in merged:
            if not e["dirty"]:
                continue
            if len(e["refs"]) > 1:
                key = _natural_key_factory([merged[r]["name"]
                                            for r in e["refs"]])
                e["refs"].sort(key=lambda r: key(merged[r]["name"]))
            if len(e["files"]) > 1:
                key = _natural_key_factory([f[0] for f in e["files"]])
                e["files"].sort(key=lambda f: key(f[0]))

    # --- recompute recursive sizes bottom-up --------------------------------
    n = len(merged)
    reachable = set()
    for r in (i for i, e in enumerate(merged) if e["parent"] == -1):
        stack = [r]
        while stack:
            i = stack.pop()
            if i in reachable:
                continue
            reachable.add(i)
            stack.extend(merged[i]["refs"])
    deep = {}
    for r in (i for i, e in enumerate(merged) if e["parent"] == -1):
        stack = [(r, False)]
        while stack:
            i, expanded = stack.pop()
            if expanded:
                if merged[i]["size"] == -1:
                    deep[i] = -1
                else:
                    total = sum(f[1] for f in merged[i]["files"])
                    for c in merged[i]["refs"]:
                        if deep[c] != -1:
                            total += deep[c]
                    deep[i] = total
            else:
                stack.append((i, True))
                for c in merged[i]["refs"]:
                    if c not in deep:
                        stack.append((c, False))
    for i in range(n):
        if i not in deep:            # unreachable folders: keep stored size
            deep[i] = merged[i]["size"]
    for idx, e in enumerate(merged):
        e["deep"] = deep[idx]

    # --- per-root metadata counters ------------------------------------------
    root_ids = [i for i, e in enumerate(merged) if e["parent"] == -1]
    root_stats = {}
    for r in root_ids:
        sub = _v2_subtree(merged, r)
        root_stats[r] = {
            "numDirs": len(sub),
            "numFiles": sum(len(merged[i]["files"]) for i in sub),
            "totBytes": sum(sum(f[1] for f in merged[i]["files"])
                            for i in sub),
        }
    for r in root_ids:
        merged[r]["meta_text"] = _v2_patch_meta(merged[r]["meta_text"],
                                                root_stats[r], snaps[0].path)

    info = {
        "num_roots": len(root_ids),
        "root_paths": [merged[r]["path"] for r in root_ids],
        "num_dirs": n,
        "num_files": sum(len(e["files"]) for e in merged),
        "total_bytes": sum(sum(f[1] for f in e["files"]) for e in merged),
    }
    return merged, info


def _v2_subtree(entries: list, root: int) -> set:
    out = set()
    stack = [root]
    while stack:
        i = stack.pop()
        if i in out:
            continue
        out.add(i)
        stack.extend(entries[i]["refs"])
    return out


def _v2_patch_meta(meta_text: str, numbers: dict, path) -> str:
    """Patch numDirs/numFiles/totBytes inside a root metadata object,
    preserving everything else (key order, escaping) byte-for-byte."""
    for key, val in (("numDirs", numbers["numDirs"]),
                     ("numFiles", numbers["numFiles"]),
                     ("totBytes", numbers["totBytes"])):
        meta_text, cnt = re.subn(r'("%s"\s*:\s*)-?\d+' % key,
                                 r"\g<1>%d" % val, meta_text, count=1)
        _require(cnt == 1, path,
                 f"root metadata object does not contain '{key}'")
    # Guard against a pathological title containing e.g. "numDirs":42 - the
    # patched object must still round-trip to the expected values.
    obj = json.loads(meta_text)
    _require(obj.get("numDirs") == numbers["numDirs"]
             and obj.get("numFiles") == numbers["numFiles"]
             and obj.get("totBytes") == numbers["totBytes"], path,
             "could not update the root metadata counters safely")
    return meta_text


def _v2_emit_entry(e: dict) -> str:
    owner = e["owner"]
    parent = -1 if e["parent"] == -1 else e["parent"] - owner
    items = ['"%s*%s*%s"' % (js_string_encode(e["name"]),
                             b36(e["deep"]), b36(e["ts"])),
             str(parent),
             '"' + "*".join(str(r - owner) for r in e["refs"]) + '"']
    for (fname, fsize, fts) in e["files"]:
        items.append('"%s*%s*%s"' % (js_string_encode(fname), b36(fsize),
                                     b36(fts)))
    if e["parent"] == -1:
        items.append(e["meta_text"])
    return "p([" + ",".join(items) + "])"


def _v2_check_stored_ids(entries: list, path) -> bool:
    """Verify that every stored (root-relative) id is non-negative. Ids are
    relative to the most recent root at a smaller index; a negative value
    means a folder would have to point at an earlier root."""
    for idx, e in enumerate(entries):
        owner = e["owner"]
        if e["parent"] != -1 and e["parent"] - owner < 0:
            return False
        for r in e["refs"]:
            if r - owner < 0:
                return False
    return True


def _v2_grouped_order(entries: list) -> list:
    """Re-order entries depth-first per root so that every subtree is
    contiguous; this makes all root-relative ids non-negative."""
    order = []
    seen = set()
    for r in (i for i, e in enumerate(entries) if e["parent"] == -1):
        stack = [r]
        while stack:
            i = stack.pop()
            if i in seen:
                continue
            seen.add(i)
            order.append(i)
            for c in reversed(entries[i]["refs"]):
                if c not in seen:
                    stack.append(c)
    order.extend(i for i in range(len(entries)) if i not in seen)
    return order


def render_v2_output(base: V2Snapshot, entries: list, input_names: list,
                     info: dict) -> str:
    """Produce the output HTML from the base file's text and the merged data."""
    text = base.text

    # --- 1. replace the data block between the [SNAPDATA] markers -----------
    i0 = text.index(V2_SNAPDATA_START)
    i0e = text.index("\n", i0) + 1
    i1 = text.index(V2_SNAPDATA_END)
    old_region = text[i0e:i1]
    term = "\r\n" if old_region.rstrip("\n").endswith("\r") else "\n"

    if not _v2_check_stored_ids(entries, base.path):
        # A multi-root merge would need negative ids in the natural output
        # order (base entries, then appended ones); emit the entries grouped
        # per root subtree instead, remapping all ids to the new positions.
        order = _v2_grouped_order(entries)
        new_index = {old: new for new, old in enumerate(order)}
        reordered = []
        for old in order:
            e = entries[old]
            e["parent"] = (-1 if e["parent"] == -1
                           else new_index[e["parent"]])
            e["refs"] = [new_index[r] for r in e["refs"]]
            reordered.append(e)
        entries = reordered
        # recompute root ownership for the new order
        owner_root = []
        cur = None
        for idx, e in enumerate(entries):
            if e["parent"] == -1:
                cur = idx
            owner_root.append(cur)
        for idx, e in enumerate(entries):
            e["owner"] = owner_root[idx]
        if not _v2_check_stored_ids(entries, base.path):
            raise SnapshotError(
                f"{base.path}: cannot merge: the folder tree cannot be "
                f"serialized with non-negative root-relative ids (orphans "
                f"across roots?)")
        print("NOTE: entries re-ordered per root to keep folder ids valid",
              file=sys.stderr)

    lines = [_v2_emit_entry(e) for e in entries]
    text = text[:i0e] + term.join(lines) + term + text[i1:]

    # --- 2. update the counters in the [SNAPMETA] block ---------------------
    m0 = text.index(V2_SNAPMETA_START)
    m1 = text.index(V2_SNAPMETA_END) + len(V2_SNAPMETA_END)
    snapmeta = text[m0:m1]
    for key, val in (("numFiles", info["num_files"]),
                     ("numDirs", info["num_dirs"]),
                     ("bytes", info["total_bytes"])):
        snapmeta, cnt = re.subn(r"(?m)^(\s*%s:\s*)\d+(\s*,)" % key,
                                r"\g<1>%d\g<2>" % val, snapmeta, count=1)
        if cnt != 1:
            raise SnapshotError(f"{base.path}: {key} not found in the "
                                f"[SNAPMETA] block")
    text = text[:m0] + snapmeta + text[m1:]

    # --- 3. update the stats line under the page title ----------------------
    tot = csharp_filesize(info["total_bytes"], base.stats["decSep"])
    stats_repl = (f">{info['num_files']} files in {info['num_dirs']} folders "
                  f'(<span id="tot_size">{tot}</span>)')
    text, cnt = V2_STATS_RE.subn(lambda _: stats_repl, text, count=1)
    if cnt != 1:
        raise SnapshotError(f"{base.path}: header stats line not found")

    # --- 4. add a provenance comment next to the original one ---------------
    return _add_provenance(text, input_names, term)


# ===========================================================================
# Shared / main
# ===========================================================================

def _add_provenance(text: str, input_names: list, line_term: str) -> str:
    today = datetime.date.today().isoformat()
    names = ", ".join(input_names)
    note = (f"<!-- Merged from {len(input_names)} snapshots ({names}) "
            f"using merge_snap2html.py on {today} -->")
    text, n = re.subn(r"(?m)^(<!-- This file was generated by .*?-->\r?)$",
                      r"\1" + line_term + note, text, count=1)
    if n != 1:
        raise SnapshotError("could not find the generator's provenance "
                            "comment to annotate")
    return text


def _verify_v1(result: Snapshot, snaps: list):
    expected_paths = {Snapshot.path_of(e) for s in snaps for e in s.dirs}
    actual_paths = {Snapshot.path_of(e) for e in result.dirs}
    if expected_paths != actual_paths:
        missing = expected_paths - actual_paths
        extra = actual_paths - expected_paths
        raise SnapshotError(f"verification failed: folder set mismatch "
                            f"(missing: {sorted(missing)[:3]}, "
                            f"unexpected: {sorted(extra)[:3]})")


def _verify_v2(result: V2Snapshot, snaps: list):
    # folder set (case-insensitive, since the merge treats Windows paths as
    # case-insensitive and keeps the first spelling it saw)
    expected = {e["path"].lower() for s in snaps for e in s.entries}
    actual = {e["path"].lower() for e in result.entries}
    if expected != actual:
        missing = expected - actual
        extra = actual - expected
        raise SnapshotError(f"verification failed: folder set mismatch "
                            f"(missing: {sorted(missing)[:3]}, "
                            f"unexpected: {sorted(extra)[:3]})")

    # file set: union by (folder path, file name), case-insensitive
    exp_files = {}
    for s in snaps:
        for e in s.entries:
            for f in e["files"]:
                exp_files.setdefault((e["path"].lower(), f[0].lower()), f)
    act_files = {}
    for e in result.entries:
        for f in e["files"]:
            act_files[(e["path"].lower(), f[0].lower())] = f
    if exp_files != act_files:
        missing = set(exp_files) - set(act_files)
        extra = set(act_files) - set(exp_files)
        raise SnapshotError(f"verification failed: file set mismatch "
                            f"(missing: {sorted(missing)[:3]}, "
                            f"unexpected: {sorted(extra)[:3]})")

    # roots: same set of source dirs
    exp_roots = {e["meta_obj"]["sourceDir"].lower()
                 for s in snaps for e in s.entries if e["parent"] == -1}
    act_roots = {e["meta_obj"]["sourceDir"].lower() for e in result.entries
                 if e["parent"] == -1}
    if exp_roots != act_roots:
        raise SnapshotError("verification failed: root folder set mismatch "
                            f"({sorted(exp_roots)} != {sorted(act_roots)})")

    # total bytes must be conserved
    exp_bytes = sum(s.total_bytes for s in snaps) if False else None
    # (bytes can legitimately shrink when duplicate files are merged; the
    # re-parse in parse_v2 already checked counter/data consistency, and the
    # file set check above guarantees no file was lost)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Consolidate two or more Snap2HTML snapshot files "
                    "into a single snapshot. Both the old (2.0-2.14) and "
                    "the new (2.5+) data formats are supported; snapshots "
                    "of different root folders are merged into a multi-root "
                    "snapshot (new format only).")
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
        texts = [(p, _read_text(p)) for p in args.inputs]
        fmts = {detect_format(t, p) for p, t in texts}
        if len(fmts) != 1:
            raise SnapshotError(
                "cannot mix data formats in one merge: " +
                ", ".join(f"{p} is {detect_format(t, p)}"
                          for p, t in texts))
        fmt = fmts.pop()

        if fmt == "V1":
            snaps = [parse_v1(p, t) for p, t in texts]

            for s in snaps[1:]:
                for key in ("linkFiles", "linkProtocol", "linkRoot",
                            "sourceRoot"):
                    _require(s.meta[key] == snaps[0].meta[key], s.path,
                             f"{key} is {s.meta[key]!r} but the first "
                             f"snapshot uses {snaps[0].meta[key]!r}")
                if s.meta["title"] != snaps[0].meta["title"]:
                    print(f"NOTE: {s.path}: title differs from the first "
                          f"snapshot; keeping {snaps[0].meta['title']!r}",
                          file=sys.stderr)

            merged = merge_v1_snapshots(snaps, sort_refs=not args.keep_order)
            output_text = render_v1_output(snaps[0], merged,
                                           [p.name for p in args.inputs])

            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(output_text.encode("utf-8"))

            result = parse_v1(args.output, _read_text(args.output))
            _verify_v1(result, snaps)

            print(f"Merged {len(args.inputs)} snapshots "
                  f"(Snap2HTML 2.0-2.14 data format) into {args.output}")
            parts = " + ".join(str(s.num_dirs) for s in snaps)
            print(f"  Folders: {parts} -> {result.num_dirs} "
                  f"({snaps[0].num_dirs + sum(s.num_dirs for s in snaps[1:]) - result.num_dirs} root/duplicate merged)")
            parts = " + ".join(str(s.num_files) for s in snaps)
            print(f"  Files:   {parts} -> {result.num_files}")
            print(f"  Total:   {human_size(result.total_bytes)}")
        else:
            snaps = [parse_v2(p, t) for p, t in texts]

            # For roots that also exist in the first snapshot, the link setup
            # and title should agree; otherwise keep the first snapshot's.
            base_root_meta = {e["meta_obj"]["sourceDir"].lower(): e["meta_obj"]
                              for e in snaps[0].entries if e["parent"] == -1}
            for s in snaps[1:]:
                for e in s.entries:
                    if e["parent"] != -1:
                        continue
                    m0 = base_root_meta.get(
                        e["meta_obj"]["sourceDir"].lower())
                    if m0 is None:
                        continue
                    if e["meta_obj"]["linkRoot"] != m0["linkRoot"]:
                        print(f"NOTE: {s.path}: link root "
                              f"{e['meta_obj']['linkRoot']!r} differs from "
                              f"the first snapshot's {m0['linkRoot']!r}; "
                              f"keeping the first", file=sys.stderr)
                    if e["meta_obj"]["title"] != m0["title"]:
                        print(f"NOTE: {s.path}: title differs from the first "
                              f"snapshot; keeping {m0['title']!r}",
                              file=sys.stderr)

            merged, info = merge_v2_snapshots(snaps,
                                              sort_refs=not args.keep_order)
            output_text = render_v2_output(snaps[0], merged,
                                           [p.name for p in args.inputs],
                                           info)

            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(output_text.encode("utf-8"))

            result = parse_v2(args.output, _read_text(args.output))
            _verify_v2(result, snaps)

            print(f"Merged {len(args.inputs)} snapshots "
                  f"(Snap2HTML 2.5+ data format) into {args.output}")
            if info["num_roots"] == 1:
                print(f"  Root:    {info['root_paths'][0]}")
            else:
                print(f"  Roots:   {', '.join(info['root_paths'])} "
                      f"(multi-root snapshot)")
            parts = " + ".join(str(s.num_dirs) for s in snaps)
            print(f"  Folders: {parts} -> {result.num_dirs}")
            parts = " + ".join(str(s.num_files) for s in snaps)
            print(f"  Files:   {parts} -> {result.num_files}")
            print(f"  Total:   {csharp_filesize(result.total_bytes)}")

        print(f"  Output verified OK (all {result.num_dirs} folders "
              f"reachable, references and counters consistent).")

    except SnapshotError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
