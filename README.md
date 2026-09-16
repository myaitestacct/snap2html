# snap2html

Tools for working with [Snap2HTML](http://www.rlvision.com) folder-snapshot files.

- `template.html` — the Snap2HTML 2.5 output template (reference for the
  current file format).
- `shows/merge_snap2html.ps1` — flatten `shows-A_2_R.html` and
  `shows-S_2_Z.html` under a single `Shows` root into `shows.html`,
  filling `template.html`.
- `shows/` — sample snapshots of `E:\shows`: `shows-A_R.html` and
  `shows-S_Z.html` (Snap2HTML 2.0 format) plus the merged `shows-A_Z.html`;
  `shows-A_2_R.html` and `shows-S_2_Z.html` (Snap2HTML 2.52 format, of

## Snapshot formats

## merge_snap2html.ps1

`shows/merge_snap2html.ps1` builds a **single-root** V2 snapshot from
`shows-A_2_R.html` and `shows-S_2_Z.html` (or any other V2 snapshots you
pass it) by filling `template.html`:

```powershell
.\shows\merge_snap2html.ps1

# equivalent, with explicit paths
.\shows\merge_snap2html.ps1 shows\shows-A_2_R.html shows\shows-S_2_Z.html `
    -OutputFile shows\shows.html -TemplateFile template.html -Title Shows
```

- The general merger keeps each input's root folder, so two snapshots of
  `E:\shows` and `H:\shows` become a **multi-root** file with two `shows`
  trees.
- `merge_snap2html.ps1` **drops** those original roots and lists every
  show folder from both files directly under a synthetic root named
  `Shows`. The page title (`<title>`, `snap.title`, and `<h1>`) is also
  `Shows`. Folder ids in later inputs are remapped; top-level listings
  are natural-sorted; header counters are recomputed.

If script execution is blocked by policy:

```powershell
powershell -ExecutionPolicy Bypass -File .\shows\merge_snap2html.ps1
```
