# snap2html

Tools for working with [Snap2HTML](http://www.rlvision.com) folder-snapshot files.

- `template.html` — the Snap2HTML 2.00 output template. Generated files carry
  their data in a JavaScript `dirs` array (one `D.p([...])` line per folder:
  `"path*0*date"`, then `"filename*size*date"` per file, then the folder's
  direct size, then a `"*"`-separated list of subfolder ids). Header stats
  (file count, folder count, total size) are derived from that array.
- `shows/` — generated snapshots of `E:\shows`, split into `shows-A_R.html`
  and `shows-S_Z.html`.

## merge_snap2html.py

Consolidates two or more snapshots **of the same root folder** into a single
snapshot file:

```bash
python3 merge_snap2html.py -o shows/shows-A_Z.html \
    shows/shows-A_R.html shows/shows-S_Z.html
```

What it does:

- appends the folder tree of each additional snapshot, remapping every
  subfolder reference id to the new indices
- merges the root entry (and any folder found in more than one snapshot):
  file lists are unioned by name, sizes summed, subfolder references unioned
- recomputes the header stats (file count, folder count, total size)
- sorts folder listings by name (case-insensitive), matching Snap2HTML's own
  output order — use `--keep-order` to keep raw snapshot order instead
- uses the first input as the template: everything outside the data block and
  the counters is preserved byte-for-byte (plus a `<!-- Merged from ... -->`
  provenance comment)
- validates every input and re-parses the output before writing, verifying
  folder reachability, reference consistency and all counters

## merge_snap2html.ps1 (PowerShell port)

`merge_snap2html.ps1` is a function-for-function port of the Python script
(Windows PowerShell 5.1 and PowerShell 7+ compatible) and produces the same
output:

```powershell
.\merge_snap2html.ps1 shows\shows-A_R.html shows\shows-S_Z.html -OutputFile shows\shows-A_Z.html
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

