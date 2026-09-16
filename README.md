# snap2html

Tools for working with [Snap2HTML](http://www.rlvision.com) folder-snapshot files.

- `template.html` — the Snap2HTML 2.5 output template (reference for the
  current file format).
- `merge_snap2html.ps1` / `merge_snap2html.py` — general-purpose mergers for
  two or more snapshots (keeps each input's own root folder).
- `landing_template.html` — template for the card-based movie browser.
- `movies/allmovies.ps1` — flatten every `movies/Movies_*.html` snapshot
  under a single `Movies` root, filling `template.html` into
  `movies/search_movies.html` **and** `landing_template.html` into
  `index.html`.
- `index.html` — the generated landing page (dark, responsive card grid).

## allmovies.ps1

`movies/allmovies.ps1` builds a **single-root** V2 snapshot from the
per-drive movie snapshots (`Movies_I.html` … `Movies_N.html`, one per drive
`I:\` … `N:\`) by filling `template.html`, and then fills
`landing_template.html` from the *same* folder data to produce `index.html`:

```powershell
.\allmovies.ps1

# equivalent, with explicit paths
.\allmovies.ps1 movies\Movies_*.html `
    -OutputFile movies\search_movies.html -TemplateFile template.html -Title Movies
```

### Default folder, and asking when it is empty

With no arguments the script looks in

```
D:\entertainment\collecting\snap2html_directory_listing
```

for `Movies_*.html`, and writes `search_movies.html` **and** `index.html` back
into that same folder. Change `$DefaultDir` near the top of the script to point
it somewhere else permanently.

If no snapshots are found there it **asks** rather than failing:

```
No Movies_*.html snapshots were found in:
  D:\entertainment\collecting\snap2html_directory_listing
  (that folder does not exist)

Enter the snapshots to merge, one per line. Each line may be a file,
a folder (its Movies_*.html files are used), or a wildcard path.
Type "list" to review what you have entered, "clear" to start over.
Press Enter on an empty line, or type "done", when you are finished.

  first input> E:\backups\Movies_I.html
    + E:\backups\Movies_I.html
  next input (1 so far)> E:\backups\old drives
    + 5 files
  next input (6 so far)> done

Using 6 input file(s):
   1. E:\backups\Movies_I.html
   ...

Output file name and location [D:\...\search_movies.html]>
```

Each answer is checked as it is typed: a path that matches nothing is reported
and asked again instead of being silently skipped, and duplicates are ignored.
The output question is the second, optional one — press Enter to accept the
bracketed default, type a bare file name to keep that folder, or type a full
path to put the results somewhere else. `index.html` always lands beside
whatever you choose.

- Explicit `-InputFiles` / `-OutputFile` always win, so nothing is prompted
  for and the script stays usable from a scheduler or another script.
- `-NoPrompt` turns the questions into an error, for unattended runs.
- `-Prompt` asks even when snapshots *were* found, showing them as the
  starting list so you can add to them.
- If the default folder's drive is missing entirely, results are written next
  to the first input file instead, with a warning.
- `template.html` and `landing_template.html` are looked for in the script's
  folder, then the repository root, then the default folder, then the current
  directory — so the script also works when copied next to the data.

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
- `-SkipLanding` writes only the snapshot; `-LandingTemplate` and
  `-LandingFile` override where the landing page is read from and written to.
  If `landing_template.html` is absent the landing page is skipped with a
  warning rather than failing the whole run.

If script execution is blocked by policy:

```powershell
powershell -ExecutionPolicy Bypass -File .\allmovies.ps1
```

Rebuilding the two artifacts committed in *this* repository (which live in
`movies/` and at the repo root rather than in `$DefaultDir`) means passing the
paths explicitly:

```powershell
.\movies\allmovies.ps1 movies\Movies_*.html -OutputFile movies\search_movies.html `
    -LandingFile index.html -TemplateFile template.html -LandingTemplate landing_template.html
```

## index.html — the landing page

`index.html` is a dark, responsive card grid over the whole collection,
generated by `allmovies.ps1` alongside the snapshot. It is **self-contained**:
the folder data is embedded verbatim (byte-identical to the `[SNAPDATA]` block
of `search_movies.html`, so the two can never drift) and there are no network
requests, no external fonts and no external images — it opens straight from
disk with a double-click, like any other Snap2HTML file.

- **~19,500 movie cards** from ~22,300 files. The raw names follow
  `INDEX__OriginalTitle__EnglishTitle__YEAR__Qualifier.ext`, and the page
  decodes that convention at load time (~200 ms, behind a splash): `--` is a
  colon, `..` is `". "`, `.` and `_` are spaces, and the release year is the
  *last* bare-year segment so films actually titled with a year (`2012`,
  `2046`, `1922`) still get the right one.
- Subtitles, cover art and `xtra_*` bonus features are folded into their
  movie rather than becoming cards of their own; multi-part films
  (`…__Part.01` … `Part.10`) collapse to one card. An index is **not** a
  unique movie id — a few indices hold two different films — so grouping is
  by index *and* title, with fuzzy matching to reattach stray subtitle files.
- **Filters**: full-text search across titles, original titles and file
  names; format; decade; folder; with/without subtitles; eight sort orders.
  Filtering and sorting ~19,500 titles takes ~12 ms.
- Cards paginate 60 at a time via `IntersectionObserver` (with a scroll
  fallback), so the DOM stays small. Click a card for every file in that
  movie with sizes, dates and a copyable snapshot path.
- Per-folder catalogue files (`.amc`, `.bak`) are ignored, and one loose file
  at a drive root is dropped by the merge itself — see above.

Regenerate both artifacts after changing any input:

```powershell
.\movies\allmovies.ps1
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
