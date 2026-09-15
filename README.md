# snap2html

Tools for working with [Snap2HTML](http://www.rlvision.com) folder-snapshot files.

- `template.html` — the Snap2HTML 2.5 output template (reference for the
  current file format).
- `shows/` — sample snapshots of `E:\shows`: `shows-A_R.html` and
  `shows-S_Z.html` (Snap2HTML 2.0 format) plus the merged `shows-A_Z.html`;
  `shows-A_2_R.html` and `shows-S_2_Z.html` (Snap2HTML 2.52 format, of
  `E:\shows` and `H:\shows`) plus the merged multi-root `shows-A_2_Z.html`.

## Snapshot formats

Snap2HTML has produced two generations of file format; both scripts detect the
format of each input automatically and refuse to mix the two in one merge:

- **V1** (Snap2HTML 2.0 – 2.14) — the data lives in a JavaScript `dirs` array,
  one `D.p([...])` line per folder: `"path*0*date"`, then
  `"filename*size*date"` per file, then the folder's direct size, then a
  `"*"`-separated list of subfolder ids. Header stats are derived from the
  array. A file describes a single root folder.
- **V2** (Snap2HTML 2.5+) — the data lives between `// [SNAPDATA]` markers,
  one `p([...])` line per folder: `"name*size*date"` (size/date base-36), the
  parent folder id, a `"*"`-separated subfolder id list, then
  `"name*size*date"` file items. Ids are decimal, relative to the most recent
  root folder. Each root folder carries a metadata object (sourceDir, title,
  linkRoot, numDirs, numFiles, totBytes, …) and a file can contain several
  roots. Files are UTF-8, usually with a BOM.

## merge_snap2html.py

Consolidates two or more snapshots into one:

```bash
# same root folder -> deep merge (either format)
python3 merge_snap2html.py -o shows/shows-A_Z.html \
    shows/shows-A_R.html shows/shows-S_Z.html

# different root folders -> multi-root snapshot (V2 only)
python3 merge_snap2html.py -o combined.html e_drive.html f_drive.html

# keep raw snapshot order in folder listings instead of re-sorting
python3 merge_snap2html.py --keep-order -o out.html a.html b.html
```

What it does:

- **Same root folder** — appends the folder tree of each additional snapshot,
  remapping every subfolder reference id to the new indices. Folders found in
  more than one snapshot are merged: file lists are unioned by name (the first
  spelling wins), subfolder references are unioned, and a folder that was
  unreadable (size −1) in one snapshot but readable in another is treated as
  readable. V1 inputs must additionally share the same link setup
  (`linkFiles`, `linkProtocol`, `linkRoot`).
- **Different root folders** (V2 only) — combines the trees into one
  multi-root snapshot, the way Snap2HTML 2.5+ itself represents several roots:
  each root keeps its own metadata object and per-root counters. If the
  natural output order would need negative root-relative ids, the entries are
  re-grouped per root subtree and all ids are remapped.
- The output always uses the **first input's format**; the first input also
  serves as the template — everything outside the data block and the counters
  is preserved byte-for-byte (plus a `<!-- Merged from ... -->` provenance
  comment). A UTF-8 BOM is written iff the first input had one.
- Folder listings that changed are sorted by name the way Snap2HTML does
  (natural sort, case-insensitive: `folder 2` before `folder 10`); use
  `--keep-order` to keep raw snapshot order instead.
- Every input is fully validated while parsing (structure, base-36 fields, id
  ranges, single-parent rule, reachability, header and per-root counters,
  stored folder sizes vs. recomputed deep sizes), and the finished output is
  re-parsed and verified (folder set, file set, root set) before the script
  reports success.

## merge_snap2html.ps1 (PowerShell port)

`merge_snap2html.ps1` is a function-for-function port of the Python script
(Windows PowerShell 5.1 and PowerShell 7+ compatible) with the same options
(`-OutputFile`/`-o`, `-KeepOrder`) and the same behavior:

```powershell
.\merge_snap2html.ps1 shows\shows-A_R.html shows\shows-S_Z.html -OutputFile shows\shows-A_Z.html

# multi-root (V2)
.\merge_snap2html.ps1 e_drive.html f_drive.html -o combined.html
```

If script execution is blocked by policy:

```powershell
powershell -ExecutionPolicy Bypass -File .\merge_snap2html.ps1 shows\shows-A_R.html shows\shows-S_Z.html -o shows\shows-A_Z.html
```

Run both implementations on the same inputs to cross-validate — the outputs
are byte-identical except for the `<!-- Merged from ... -->` provenance
comment, which names the script that produced it:

```powershell
python merge_snap2html.py  -o shows-A_Z_py.html  shows\shows-A_R.html shows\shows-S_Z.html
.\merge_snap2html.ps1      -o shows-A_Z_ps.html shows\shows-A_R.html shows\shows-S_Z.html
Compare-Object (Get-Content shows-A_Z_py.html) (Get-Content shows-A_Z_ps.html)
```
