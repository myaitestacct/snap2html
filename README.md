# snap2html

Tools for working with [Snap2HTML](http://www.rlvision.com) folder-snapshot files.

- `template.html` — the Snap2HTML 2.5 output template (reference for the
  current file format).
- `merge_snap2html.ps1` / `merge_snap2html.py` — general-purpose mergers for
  two or more snapshots (keeps each input's own root folder).
- `movies/allmovies.ps1` — flatten every `movies/Movies_*.html`
  snapshot under a single `Movies` root into `movies/search_movies.html`,
  filling `template.html`.

## allmovies.ps1

`movies/allmovies.ps1` builds a **single-root** V2 snapshot from the
per-drive movie snapshots (`Movies_I.html` … `Movies_N.html`, one per drive
`I:\` … `N:\`) by filling `template.html`:

```powershell
.\movies\allmovies.ps1

# equivalent, with explicit paths
.\movies\allmovies.ps1 movies\Movies_*.html `
    -OutputFile movies\search_movies.html -TemplateFile template.html -Title Movies
```

- The drive roots are **dropped** and every `movies_NN_*` folder from every
  input is listed directly under a synthetic root named `Movies`. The page
  title (`<title>`, `snap.title` and `<h1>`) is also `Movies`.
- Folder ids in later inputs are remapped; top-level listings are
  natural-sorted (`movies_2` before `movies_10`); header counters are
  recomputed. For the six supplied snapshots that is **79 movie folders,
  22,290 files, 31.9 TB** under one `Movies` root.
- File links are disabled (`linkRoot: ""`) because the merged tree spans
  several drives, so no single link root can be correct.
- Files sitting directly in a drive root rather than in a `movies_NN_*`
  folder (`Movies_L.html` has `L:\msdia80.dll`) have no folder left to live
  in once the drive roots are dropped. They are **discarded by default** and
  the recomputed file count and total size are reduced to match; pass
  `-KeepRootFiles` to attach them to the `Movies` root instead.
- `-KeepOrder` keeps each input's original child order instead of re-sorting
  the combined listing.

If script execution is blocked by policy:

```powershell
powershell -ExecutionPolicy Bypass -File .\movies\allmovies.ps1
```

## merge_snap2html.ps1

`merge_snap2html.ps1` builds a **single-root** V2 snapshot from
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
