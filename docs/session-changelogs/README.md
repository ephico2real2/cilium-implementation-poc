# Session change logs

One file per working session, in the format the `changelog` skill defines (it lives with the
group-sync-dashboard project; the format is the operator's, approved 2026-09-14): what the session
did, in order, with the commit, run or measurement behind each line. This is the **session** record;
the README's finding list and `../GOTCHAS.md` are what an operator reads per subject, and the two
never merge.

| File | Convention |
|---|---|
| `YYYY-MM-DD_<slug>.md` | the date the session STARTED (a session spanning midnight keeps it) and a two- or three-word subject |
| entries | appended after each commit that has passed its tests and review — never before validation |
| numbers | measured by the session (`git log`, `gh run view`, the test summary lines), never recalled |

Every backticked path written here must exist in the repository; memory notes and files outside the
tree are named in plain words.
