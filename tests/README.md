# Running the regression suite

`bash tests/run.sh` runs the complete corpus. It runs the presence and signal group
alone, then runs up to four independent groups at a time. Each group owns its
temporary repositories, provider stubs, mount store and global installation paths.
Fixture builders in `lib/fixtures.sh` construct prerequisites without running
other groups' assertions.

Use `bash tests/run.sh --jobs 1` for a serial comparison on the same commit and
machine. Both modes execute the same committed manifest and coverage contracts.
The runner prints per-group elapsed time and total wall, user and system time.
Avoid concurrent full-suite runs when comparing measurements.

For development, `bash tests/run.sh --list` lists groups and
`bash tests/run.sh --group history` runs a focused group. Repeat `--group` to select
several. A focused run explicitly reports that it is incomplete; it never emits
the full suite completion line or records a reusable passing result.

Only the complete runner can attest. It requires every scheduled worker to finish
successfully, every report to be complete, and the merged assertion total and
section vector to match the contracts committed at the captured commit. A missing
worker, duplicate section, reused skip allowance, or cancelled run cannot pass.
Workers use the existing process supervisor to finish descendant cleanup before
their results are accepted.

For a landing, commit the candidate, run the complete suite on that commit, and
review that same committed candidate. The `ATTESTATION` line says whether
`integrate` can reuse the result within `suite-attest-secs`. A passing run made
before a commit, on tracked changes, or before HEAD moved cannot validate the new
commit. Coverage changes require updating and committing both count contracts.

Add tests to the group that owns their fixtures. New groups must be listed in
`groups.tsv`. Keep group setup explicit: importing another group's test body
reintroduces the duplicated work this split removes. Preserve existing section
banners unless intentionally changing the coverage contract.
