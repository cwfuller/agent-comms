# Run through tests/run.sh; each group gets fresh fixtures.
section "the coordinator's event log: a durable record that is not the mailbox"
# Contraction step 3, criteria 1 and 4. The log's value is that it SURVIVES things — a
# driver that dies mid-panel, a broker that refuses, N runners appending at once — so it is
# exercised here, never asserted about. Columns are resolved BY NAME from the header, so
# adding one cannot silently repoint an assertion at the wrong field.
EV="$WORK/events-repo"; mkdir -p "$EV"; EV="$(cd "$EV" && pwd -P)"
git -C "$EV" init -q -b main
printf '.comms/\n' > "$EV/.gitignore"
echo "subject" > "$EV/s.txt"
git -C "$EV" add -A >/dev/null 2>&1
git -C "$EV" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$EV/.comms/to-codex" "$EV/.comms/to-grok" "$EV/.comms/to-claude" "$EV/.comms/archive"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$EV/.comms/config"
run_ev() { (cd "$EV" && env COMMS_DELIVERY=mailbox PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }
EV_LOG="$EV/.comms/events.tsv"
EV_ROWS() { tail -n +2 "$EV_LOG" 2>/dev/null | grep -c . || true; }
EV_COL() { awk -F'\t' -v n="$1" 'NR==1{for(i=1;i<=NF;i++) if ($i==n) {print i; exit}}' "$EV_LOG"; }

EV_EMPTY="$(run_ev events 2>&1)" && EV_ERC=0 || EV_ERC=$?
[ "${EV_ERC:-0}" = "0" ] && printf '%s\n' "$EV_EMPTY" | grep -q 'no coordinator log yet' \
  && ok "an absent log reports itself instead of failing" || fail "absent-log read (rc=$EV_ERC: $EV_EMPTY)"
[ ! -f "$EV_LOG" ] && ok "reading does not create the log" || fail "the reader created the log"

run_ev events append --kind turn-started --set ev-set-1 --dispatch d-1 --thread ev-thread \
  --round 2 --agent codex --status running --note "first note" >/dev/null
[ -s "$EV_LOG" ] && ok "append creates the log" || fail "append created no log"
C_TS=$(EV_COL ts); C_EV=$(EV_COL event); C_SET=$(EV_COL review_set); C_DSP=$(EV_COL dispatch)
C_TH=$(EV_COL thread); C_AG=$(EV_COL agent); C_ROLE=$(EV_COL role); C_ART=$(EV_COL artifact_id)
C_REQ=$(EV_COL request_id); C_MID=$(EV_COL message_id); C_ST=$(EV_COL status); C_NOTE=$(EV_COL note)
C_NF=$(head -1 "$EV_LOG" | awk -F'\t' '{print NF}')
[ -n "$C_TS$C_EV$C_SET$C_DSP$C_TH$C_AG$C_ROLE$C_ART$C_REQ$C_MID$C_ST$C_NOTE" ] && [ "$C_TS" = "1" ] \
  && ok "the header names every column its readers index by" || fail "log header (got: $(head -1 "$EV_LOG"))"
EV_ROW="$(tail -1 "$EV_LOG")"
evf() { printf '%s' "$EV_ROW" | cut -f"$1"; }
[ "$(evf "$C_EV")" = "turn-started" ] && ok "the kind lands in the event column" || fail "event column (got: $EV_ROW)"
[ "$(evf "$C_SET")" = "ev-set-1" ] && ok "the review set is recorded" || fail "set column (got: $EV_ROW)"
[ "$(evf "$C_DSP")" = "d-1" ] && ok "the dispatch attempt is recorded" || fail "dispatch column (got: $EV_ROW)"
[ "$(evf "$C_TH")" = "ev-thread" ] && ok "the thread is recorded" || fail "thread column (got: $EV_ROW)"
[ "$(evf "$C_AG")" = "codex" ] && ok "the agent is recorded" || fail "agent column (got: $EV_ROW)"
[ "$(evf "$C_ROLE")" = "gating" ] && ok "a turn gates unless it says otherwise" || fail "role column (got: $EV_ROW)"
[ "$(evf "$C_ST")" = "running" ] && ok "the status is recorded" || fail "status column (got: $EV_ROW)"
run_ev events append --kind provider-result --set ev-set-1 --thread ev-thread --agent codex --status completed >/dev/null
[ "$(EV_ROWS)" = "2" ] && ok "the log appends rather than rewrites" || fail "append count (got: $(EV_ROWS))"

check_not "an unknown event kind is refused" run_ev events append --kind turnstarted
check_not "an event with no kind is refused" run_ev events append --thread ev-thread
check_not "an unknown role is refused" run_ev events append --kind turn-started --role auditor
[ "$(EV_ROWS)" = "2" ] && ok "a refused append writes nothing" || fail "a refused append still wrote (got: $(EV_ROWS))"

run_ev events append --kind reply-refused --thread ev-thread --status refused \
  --note "$(printf 'tab\there\nand a newline')" >/dev/null
[ "$(EV_ROWS)" = "3" ] && ok "a note with a tab and a newline stays ONE row" || fail "sanitisation split the row (got: $(EV_ROWS))"
[ "$(tail -1 "$EV_LOG" | awk -F'\t' '{print NF}')" = "$C_NF" ] && ok "the sanitised row keeps every column" || fail "column count after sanitisation"
EV_BIG="$(awk 'BEGIN{while(i++<4000)printf "x"}')"
run_ev events append --kind reply-validated --thread ev-thread --status APPROVE --note "$EV_BIG" >/dev/null
[ "$(tail -1 "$EV_LOG" | LC_ALL=C wc -c | tr -d ' ')" -le 1024 ] && ok "an oversized note is clipped to the row cap" || fail "row cap on a long note"
# The cap is a property of the COLUMNS. Clipping the assembled row instead would cut
# trailing delimiters off and break the fixed-column contract. (codex, plan r1.)
run_ev events append --kind turn-started --set "$EV_BIG" --dispatch "$EV_BIG" --thread "$EV_BIG" \
  --round "$EV_BIG" --agent "$EV_BIG" --artifact "$EV_BIG" --request-id "$EV_BIG" \
  --message-id "$EV_BIG" --run-dir "$EV_BIG" --status "$EV_BIG" --note "$EV_BIG" >/dev/null
[ "$(tail -1 "$EV_LOG" | LC_ALL=C wc -c | tr -d ' ')" -le 1024 ] && ok "every column at its maximum still fits the row cap" || fail "row cap with all columns maxed"
# The cap is about what reaches write(2), so the newline counts. Accepting 1025 was the
# test masking the violation. (codex, implement r1, blocking.)
[ "$(awk 'END{print (max+0)}{ if (length($0)+1 > max) max = length($0)+1 }' "$EV_LOG")" -le 1024 ] \
  && ok "no row in the whole log exceeds the cap, newline included" || fail "a row exceeds the cap with its newline"
[ "$(tail -1 "$EV_LOG" | awk -F'\t' '{print NF}')" = "$C_NF" ] && ok "a maxed row keeps every column" || fail "maxed row lost columns"

# A torn row is NAMED, not parsed: there is no lock (a dead holder is a deadlock), so
# detection is the guarantee. Whole-field checks, or two concatenated rows pass. (codex r2.)
#
# In its OWN repo, because a torn row now makes attempt binding refuse — planting one in the
# fixture the panel tests share would poison every later status and compose here, which is
# precisely the loud behaviour being asserted further down. (codex, implement r3.)
EVT="$WORK/events-torn"; mkdir -p "$EVT"; EVT="$(cd "$EVT" && pwd -P)"
git -C "$EVT" init -q -b main
git -C "$EVT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
run_evt() { (cd "$EVT" && env "$COMMS" "$@"); }
EVT_LOG="$EVT/.comms/events.tsv"
run_evt events append --kind turn-started --set ev-set-1 --thread ev-thread --agent codex --status running >/dev/null
EV_LOG_MAIN="$EV_LOG"; EV_LOG="$EVT_LOG"
run_ev_main() { run_ev "$@"; }
run_ev() { run_evt "$@"; }
printf 'this row has no columns and no timestamp\n' >> "$EV_LOG"
EV_TORN="$(run_ev events 2>&1 >/dev/null)"
printf '%s\n' "$EV_TORN" | grep -q 'malformed' && ok "a malformed row is reported on stderr" || fail "torn row not reported (got: $EV_TORN)"
run_ev events 2>/dev/null | grep -q 'this row has no columns' && fail "a malformed row was printed as an event" || ok "a malformed row is never printed as an event"
EV_GOOD="$(awk -F'\t' 'NR==2' "$EV_LOG")"
printf '%s%s\n' "$EV_GOOD" "$EV_GOOD" >> "$EV_LOG"
[ "$(run_ev events --kind turn-started 2>/dev/null | grep -c 'ev-set-1')" = "1" ] \
  && ok "two rows concatenated into one line are refused, not read as an event" || fail "concatenated row passed the check"
EV_BADKIND="$(printf '%s' "$EV_GOOD" | awk -F'\t' -v c="$C_EV" 'BEGIN{OFS="\t"}{$c="turn-invented"; print}')"
printf '%s\n' "$EV_BADKIND" >> "$EV_LOG"
run_ev events 2>/dev/null | grep -q 'turn-invented' && fail "a row with an unknown kind was read as an event" || ok "a row naming a kind outside the vocabulary is refused"
# EVERY closed vocabulary, not just the kind: a role nobody can write was being printed as
# a real event. (codex, implement r1, blocking.)
EV_BADROLE="$(printf '%s' "$EV_GOOD" | awk -F'\t' -v c="$C_ROLE" -v t="$C_TH" 'BEGIN{OFS="\t"}{$c="auditor"; $t="ev-badrole"; print}')"
printf '%s\n' "$EV_BADROLE" >> "$EV_LOG"
run_ev events 2>/dev/null | grep -q 'ev-badrole' && fail "a row naming an impossible role was read as an event" || ok "a row naming a role outside the vocabulary is refused"
# A row that merely BEGINS with the header's first token is a row, not a header: skipping
# it would drop a real event, and swallowing a foreign header would hide it. (codex.)
ev_malformed_count() { run_ev events 2>&1 >/dev/null | sed -n 's/.*skipped \([0-9][0-9]*\) malformed.*/\1/p' | tail -1; }
EV_MB="$(ev_malformed_count)"
printf 'ts\tnot\ta\theader\tjust\ta\trow\tthat\tstarts\twith\tts\tand\tis\tmalformed\there\n' >> "$EV_LOG"
# Counted, not grepped: torn rows planted earlier make a bare `grep malformed` pass whether
# or not THIS row was caught. (grok, implement r2.)
[ "$(ev_malformed_count)" = "$(( ${EV_MB:-0} + 1 ))" ] \
  && ok "a header-shaped row that is not the header is reported, not silently skipped" || fail "header-shaped row swallowed (was ${EV_MB:-0}, now $(ev_malformed_count))"

# Back to the shared fixture, whose log is still clean.
EV_LOG="$EV_LOG_MAIN"
run_ev() { (cd "$EV" && env COMMS_DELIVERY=mailbox PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }

EV_N=20
i=1; while [ "$i" -le "$EV_N" ]; do
  run_ev events append --kind turn-started --set ev-race --thread "race-$i" --status running --note "racer-$i" >/dev/null &
  i=$((i+1))
done
wait
[ "$(awk -F'\t' -v c="$C_SET" '$c=="ev-race"' "$EV_LOG" | grep -c .)" = "$EV_N" ] && ok "every concurrent append lands" || fail "concurrent appends lost rows"
[ "$(awk -F'\t' -v c="$C_SET" -v n="$C_NF" '$c=="ev-race" && NF!=n' "$EV_LOG" | grep -c . || true)" = "0" ] \
  && ok "no concurrent append tore another's row" || fail "a concurrent row was torn"
[ "$(awk -F'\t' -v c="$C_SET" -v n="$C_NOTE" '$c=="ev-race"{print $n}' "$EV_LOG" | sort -u | grep -c .)" = "$EV_N" ] \
  && ok "every racer's own note survived intact" || fail "a racing note was lost or merged"

# The atomicity argument is about the row that reaches write(2), so the boundary case —
# maximum-size rows — is the one worth racing. (codex, implement r2, advisory.)
i=1; while [ "$i" -le 10 ]; do
  run_ev events append --kind turn-started --set ev-bigrace --thread "big-$i" --status running --note "$EV_BIG" >/dev/null &
  i=$((i+1))
done
wait
[ "$(awk -F'\t' -v c="$C_SET" '$c=="ev-bigrace"' "$EV_LOG" | grep -c .)" = "10" ] \
  && ok "concurrent MAXIMUM-size rows all land" || fail "a maximum-size concurrent append was lost"
[ "$(awk -F'\t' -v c="$C_SET" -v n="$C_NF" '$c=="ev-bigrace" && NF!=n' "$EV_LOG" | grep -c . || true)" = "0" ] \
  && ok "no maximum-size row tore another" || fail "a maximum-size row was torn"

EV2="$WORK/events-repo-2"; mkdir -p "$EV2"; EV2="$(cd "$EV2" && pwd -P)"
git -C "$EV2" init -q -b main
git -C "$EV2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
i=1; while [ "$i" -le 8 ]; do
  (cd "$EV2" && env "$COMMS" events append --kind turn-started --thread "h-$i" >/dev/null 2>&1) &
  i=$((i+1))
done
wait
[ "$(grep -c '^ts	workspace	event' "$EV2/.comms/events.tsv" 2>/dev/null || true)" = "1" ] \
  && ok "racing first writers create exactly one header" || fail "header raced"
[ "$(tail -n +2 "$EV2/.comms/events.tsv" | grep -c .)" = "8" ] && ok "no racing first write was lost to the header" || fail "a first write was lost"
# A log whose header could not be written is refused rather than created headerless — every
# reader would otherwise report its rows as malformed forever. (codex, implement r2.)
EV7="$WORK/events-repo-7"; mkdir -p "$EV7"
git -C "$EV7" init -q -b main; git -C "$EV7" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$EV7/.comms"; chmod a-w "$EV7/.comms"
EV_NOHDR="$( (cd "$EV7" && env "$COMMS" events append --kind turn-started --thread h) 2>&1 || true )"
chmod u+w "$EV7/.comms"
printf '%s\n' "$EV_NOHDR" | grep -q 'headerless' && ok "a log whose header cannot be created is refused" || fail "headerless log not refused (got: $EV_NOHDR)"
# A directory that cannot be created reports and RETURNS, the same as every other refusal —
# `die` there would exit a `send` mid-delivery. (codex, implement r3, blocking.)
EV8="$WORK/events-repo-8"; mkdir -p "$EV8"
git -C "$EV8" init -q -b main; git -C "$EV8" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
: > "$EV8/.comms"
EV_NODIR="$( (cd "$EV8" && env "$COMMS" events append --kind turn-started --thread d) 2>&1 || true )"
rm -f "$EV8/.comms"
printf '%s\n' "$EV_NODIR" | grep -q 'cannot create' && ok "an uncreatable events directory is reported, not a bash error" || fail "uncreatable dir (got: $EV_NODIR)"
# If the channel that reports skipped rows cannot be created, the evidence of a torn log
# would vanish and every consumer would trust a file nothing validated. (codex, r4.)
EV_NOTMP="$( (cd "$EV" && env TMPDIR=/nonexistent-tmpdir-for-tests "$COMMS" events --limit 1) 2>&1 >/dev/null || true )"
printf '%s\n' "$EV_NOTMP" | grep -q 'could not be counted' \
  && ok "a reader that cannot record what it skipped refuses to read at all" || fail "reader degraded silently (got: $EV_NOTMP)"
[ ! -f "$EV7/.comms/events.tsv" ] && ok "the refusal leaves no headerless log behind" || fail "a headerless log was created"

# The filesystem constraint is ENFORCED, not diagnosed: an NFS append can be LOST whole,
# leaving a well-formed file with an event missing — which no reader can detect. So the log
# refuses to exist there rather than warning and continuing. (codex, plan r2, blocking.)
EV_DFB="$WORK/df-stub"; mkdir -p "$EV_DFB"
cat > "$EV_DFB/df" <<'DFS'
#!/bin/bash
printf 'Filesystem 512-blocks Used Available Capacity Mounted on\n'
# No device configured models a df that cannot answer — the unclassifiable case.
[ -n "${DF_STUB_FS:-}" ] || exit 1
printf '%s 1 1 1 1%% /mnt\n' "$DF_STUB_FS"
DFS
# The type probes are stubbed too, so BOTH branches — GNU `stat` and the BSD mount table —
# are driven on either kind of host instead of one of them being untested wherever the
# suite happens to run.
cat > "$EV_DFB/stat" <<'STS'
#!/bin/bash
[ -n "${STAT_STUB_TYPE:-}" ] || exit 1
printf '%s\n' "$STAT_STUB_TYPE"
STS
cat > "$EV_DFB/mount" <<'MTS'
#!/bin/bash
[ -n "${MOUNT_STUB_TYPE:-}" ] || exit 1
printf 'dev on /mnt (%s, local, journaled)\n' "$MOUNT_STUB_TYPE"
MTS
chmod +x "$EV_DFB/df" "$EV_DFB/stat" "$EV_DFB/mount"
ev_fs_try() { # <df-device> <repo-dir> [env assignments...]
  local dev="$1" dir="$2"; shift 2
  mkdir -p "$dir"; git -C "$dir" init -q -b main
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  (cd "$dir" && env DF_STUB_FS="$dev" "$@" PATH="$EV_DFB:$PATH" \
     "$COMMS" events append --kind turn-started --thread fs-1) 2>&1
}
ev_fs_case() { # <label> <expect accepted|refused> <df-device> <dir> [env...]
  local lbl="$1" want="$2"; shift 2
  local out; out="$(ev_fs_try "$@" || true)"
  local got=accepted
  printf '%s\n' "$out" | grep -q 'refusing to write' && got=refused
  [ "$got" = "$want" ] && ok "$lbl" || fail "$lbl (wanted $want, got $got: $(printf '%s' "$out" | head -1))"
}
# An ALLOWLIST of known-local types, failing closed on anything unrecognised. The shape
# blacklist this replaced was blind to network FUSE mounts, which look nothing like
# host:/export and are exactly as unsafe. (codex, implement r2, blocking.)
ev_fs_case "a local disk type is accepted" accepted '/dev/disk1s5' "$WORK/evfs-ext" STAT_STUB_TYPE=ext2/ext3
ev_fs_case "an NFS type is refused" refused '/dev/disk1s5' "$WORK/evfs-nfs" STAT_STUB_TYPE=nfs
ev_fs_case "an UNRECOGNISED type fails closed" refused '/dev/disk1s5' "$WORK/evfs-fuse" STAT_STUB_TYPE=fuseblk
ev_fs_case "the mount table answers where GNU stat cannot" accepted '/dev/disk1s5' "$WORK/evfs-apfs" MOUNT_STUB_TYPE=apfs
ev_fs_case "a network FUSE mount is refused by type, not by name shape" refused '/dev/disk1s5' "$WORK/evfs-osxfuse" MOUNT_STUB_TYPE=osxfuse
ev_fs_case "a filesystem nothing can classify fails closed" refused '/dev/disk1s5' "$WORK/evfs-silent"
ev_fs_case "an rclone-style remote:bucket source is refused" refused 'remote:bucket' "$WORK/evfs-rclone" STAT_STUB_TYPE=ext4
EV_NFS="$(ev_fs_try 'fileserver:/export/home' "$WORK/events-repo-3" STAT_STUB_TYPE=ext4 || true)"
printf '%s\n' "$EV_NFS" | grep -q 'refusing to write' && ok "an NFS mount refuses the log outright" || fail "network fs not refused (got: $EV_NFS)"
[ ! -f "$WORK/events-repo-3/.comms/events.tsv" ] && ok "a refused filesystem leaves no half-made log" || fail "a log was created on a refused filesystem"
EV_SMB="$(ev_fs_try '//server/share' "$WORK/events-repo-5" STAT_STUB_TYPE=ext4 || true)"
printf '%s\n' "$EV_SMB" | grep -q 'refusing to write' && ok "an SMB mount refuses the log outright" || fail "smb fs not refused (got: $EV_SMB)"
EV_LOCAL="$(ev_fs_try '/dev/disk1s5' "$WORK/events-repo-4" STAT_STUB_TYPE=ext4 || true)"
printf '%s\n' "$EV_LOCAL" | grep -q 'refusing' && fail "a local filesystem was refused" || ok "a local filesystem is accepted"
# ...and it actually wrote, rather than failing for some other reason the grep cannot see.
[ -s "$WORK/events-repo-4/.comms/events.tsv" ] && ok "the accepted filesystem really got a log" || fail "no log on the accepted filesystem"
# CHECKED ON EVERY APPEND. Judging only at creation left the refusal bypassable for the
# rest of the log's life by a `.comms` that migrates onto network storage — the silent-loss
# mode the refusal exists to prevent. (codex + grok, implement r1.)
EV_MIGRATED="$( (cd "$WORK/events-repo-4" && env DF_STUB_FS='fileserver:/export/home' STAT_STUB_TYPE=ext4 PATH="$EV_DFB:$PATH" "$COMMS" events append --kind turn-started --thread migrated-1) 2>&1 >/dev/null || true )"
printf '%s\n' "$EV_MIGRATED" | grep -q 'refusing to write' && ok "an EXISTING log that moved onto network storage refuses further appends" || fail "migrated log appended unchecked (got: $EV_MIGRATED)"
grep -q 'migrated-1' "$WORK/events-repo-4/.comms/events.tsv" && fail "the refused append was written anyway" || ok "a refused append leaves no row"
# ...and refusing must RETURN, not exit: `die` inside the accessor would take the whole
# process with it, including a `send` that is delivering a reply — the advisory half of the
# policy would silently become fail-closed. (grok, implement r2.)
EV_FSREPLY="$EV/.comms/to-claude/$(basename "$EV")_2026-08-29T09-40-00_ev-fsreply.md"
printf -- '---\ntype: review-feedback\nfrom: codex\ntimestamp: 2026-08-29T09:40:00Z\nworkspace: %s\nmessage_id: ev-fsreply-1\nthread: ev-loop\nin-reply-to: ev-req-1\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: APPROVE\n---\n\n## Findings\n\n### Blocking\n- None.\n' "$(basename "$EV")" > "$EV_FSREPLY"
if (cd "$EV" && env COMMS_DELIVERY=mailbox DF_STUB_FS='fileserver:/export/home' STAT_STUB_TYPE=ext4 PATH="$EV_DFB:$STUB_BIN:$PATH" "$COMMS" send --to claude "$EV_FSREPLY") >/dev/null 2>&1; then
  ok "an unsound filesystem refuses the log without killing a reply's delivery"
else
  fail "a refused log took the reply's send down with it"
fi
# The same refusal on a REQUEST must still gate: that producer is the fail-closed one.
EV_FSREQ="$EV/.comms/to-codex/$(basename "$EV")_2026-08-29T09-41-00_ev-fsreq.md"
printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-08-29T09:41:00Z\nworkspace: %s\nmessage_id: ev-fsreq-1\nthread: ev-fsreq\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\n---\n\n## What was done\nA change worth reviewing.\n' "$(basename "$EV")" > "$EV_FSREQ"
if (cd "$EV" && env COMMS_DELIVERY=mailbox DF_STUB_FS='fileserver:/export/home' STAT_STUB_TYPE=ext4 PATH="$EV_DFB:$STUB_BIN:$PATH" "$COMMS" send --to codex "$EV_FSREQ") >/dev/null 2>&1; then
  fail "a request dispatched with no recordable log"
else
  ok "a request whose persistence cannot be recorded is still refused outright"
fi

[ "$(run_ev events --set ev-race 2>/dev/null | tail -n +2 | grep -c .)" = "$EV_N" ] && ok "--set selects one review set" || fail "--set filter"
[ "$(run_ev events --thread race-3 2>/dev/null | tail -n +2 | grep -c .)" = "1" ] && ok "--thread selects one leg" || fail "--thread filter"
[ "$(run_ev events --kind provider-result 2>/dev/null | tail -n +2 | grep -c .)" = "1" ] && ok "--kind selects one lifecycle point" || fail "--kind filter"
[ "$(run_ev events --agent codex 2>/dev/null | tail -n +2 | grep -c .)" = "2" ] && ok "--agent selects one reviewer" || fail "--agent filter"
[ "$(run_ev events --dispatch d-1 2>/dev/null | tail -n +2 | grep -c .)" = "1" ] && ok "--dispatch selects one attempt" || fail "--dispatch filter"
[ "$(run_ev events --limit 3 2>/dev/null | tail -n +2 | grep -c .)" = "3" ] && ok "--limit caps what is printed" || fail "--limit cap"
printf '%s\n' "$(run_ev events --set ev-race --limit 1 2>/dev/null)" | tail -1 | grep -q 'racer-' \
  && ok "--limit applies AFTER the filter, never as a global tail" || fail "--limit filter ordering"
[ "$(run_ev events --set ev-race 2>/dev/null | sed -n 1p | cut -f1)" = "ts" ] \
  && ok "a filtered read still prints the header" || fail "filtered header"
check_not "--limit rejects a non-numeric budget" run_ev events --limit nine
# A roster read must not be capped: dispatch enforces no maximum, so a silent cap would drop
# members from the union it is enumerating and let a short panel report itself complete.
# (codex, implement r6, blocking.)
i=1; while [ "$i" -le 60 ]; do
  run_ev events append --kind panel-planned --set ev-bigroster --dispatch d-big --agent "codex" \
    --thread "big-$i" --status planned >/dev/null
  i=$((i+1))
done
[ "$(run_ev events --set ev-bigroster --limit 50 2>/dev/null | tail -n +2 | grep -c .)" = "50" ] \
  && ok "--limit still caps an ordinary read" || fail "--limit stopped capping"
[ "$(run_ev events --set ev-bigroster --all 2>/dev/null | tail -n +2 | grep -c .)" = "60" ] \
  && ok "--all reads every row, so a roster is never silently shortened" || fail "--all is still capped"
# The set id is bounded at its SOURCE, so sets.tsv and the log hold the same bytes and the
# bare listing can join them. Unbounded, a long id was stored raw in one and encoded in the
# other, and the listing reported zero legs for a valid set. (codex + grok, implement r5.)
# Identity columns are exact-match join keys. A plain clip breaks the join SILENTLY: the row
# is written, and then nothing can ever find it again. Writer and reader share one transform
# — a readable head plus a digest of the whole. (codex, implement r4, blocking.)
EV_LONGID="m-$(awk 'BEGIN{while(i++<200)printf "x"}')"
run_ev events append --kind reply-accepted --thread ev-longid --message-id "$EV_LONGID" --status APPROVE >/dev/null
[ "$(run_ev events --kind reply-accepted --message-id "$EV_LONGID" 2>/dev/null | tail -n +2 | grep -c .)" = "1" ] \
  && ok "an identity longer than its column is still found by its full value" || fail "a long identity could not find itself"
[ "$(run_ev events --kind reply-accepted --message-id "${EV_LONGID}zzz" 2>/dev/null | tail -n +2 | grep -c .)" = "0" ] \
  && ok "a DIFFERENT long identity sharing the same prefix does not match" || fail "the identity transform collides on a shared prefix"
[ "$(awk -F'\t' -v c="$C_MID" -v t="$C_TH" '$t=="ev-longid"{print length($c)}' "$EV_LOG")" -le 72 ] \
  && ok "the stored identity still respects its column budget" || fail "identity exceeded its column"
# A shadow turn shares its gating leg's thread and dispatch, so a recovery read has to be
# able to drop it or a measurement looks like the leg that gates. (grok, implement r1.)
run_ev events append --kind turn-started --set ev-roles --thread ev-roles --role shadow --status running >/dev/null
run_ev events append --kind turn-started --set ev-roles --thread ev-roles --role gating --status running >/dev/null
[ "$(run_ev events --set ev-roles --role gating 2>/dev/null | tail -n +2 | grep -c .)" = "1" ] \
  && ok "--role separates the gating leg from a measurement on the same thread" || fail "--role filter"

EV_REQ="$EV/.comms/to-codex/$(basename "$EV")_2026-08-29T09-00-00_ev-req.md"
cat > "$EV_REQ" <<EVEOF
---
type: review-request
from: claude
timestamp: 2026-08-29T09:00:00Z
workspace: $(basename "$EV")
message_id: ev-req-1
thread: ev-loop
workflow: auto
phase: implement
round: 1
max-rounds: 4
---

## What was done
A change worth reviewing.
EVEOF
run_ev send --to codex "$EV_REQ" >/dev/null 2>&1 || true
EV_SEQ="$(awk -F'\t' -v c="$C_MID" -v e="$C_EV" '$c=="ev-req-1"{printf "%s ", $e}' "$EV_LOG")"
[ "$EV_SEQ" = "request-persisted request-dispatched " ] \
  && ok "a dispatch records persistence BEFORE delivery, then its outcome" || fail "send event pair (got: $EV_SEQ)"
awk -F'\t' -v c="$C_MID" -v e="$C_EV" -v a="$C_ART" '$c=="ev-req-1" && $e=="request-persisted" && $a ~ /^[0-9a-f]{40}$/' "$EV_LOG" | grep -q . \
  && ok "the request event carries the artifact send pinned" || fail "request event artifact_id"
awk -F'\t' -v c="$C_MID" -v e="$C_EV" -v st="$C_ST" '$c=="ev-req-1" && $e=="request-dispatched" && $st!=""' "$EV_LOG" | grep -q . \
  && ok "the dispatch event carries the delivery outcome" || fail "dispatch outcome status"

EV_REPLY="$EV/.comms/to-claude/$(basename "$EV")_2026-08-29T09-05-00_ev-reply.md"
cat > "$EV_REPLY" <<EVEOF
---
type: review-feedback
from: codex
timestamp: 2026-08-29T09:05:00Z
workspace: $(basename "$EV")
message_id: ev-reply-1
thread: ev-loop
in-reply-to: ev-req-1
workflow: auto
phase: implement
round: 1
max-rounds: 4
verdict: APPROVE
---

## Findings

### Blocking
- None.
EVEOF
run_ev send --to claude "$EV_REPLY" >/dev/null 2>&1 || true
ev_reply_field() { awk -F'\t' -v c="$C_MID" -v f="$1" '$c=="ev-reply-1"{v=$f} END{print v}' "$EV_LOG"; }
[ "$(ev_reply_field "$C_EV")" = "reply-accepted" ] \
  && ok "a reply is recorded as accepted, not as another request" || fail "reply event kind"
[ "$(ev_reply_field "$C_ST")" = "APPROVE" ] \
  && ok "the accepted reply carries its VERDICT as the status" || fail "reply verdict status"
[ "$(ev_reply_field "$C_AG")" = "codex" ] \
  && ok "a reply is attributed to its author, never to the send target" || fail "reply agent attribution"
[ "$(ev_reply_field "$C_REQ")" = "ev-req-1" ] \
  && ok "a reply carries the request id it answers" || fail "reply request_id binding"

EV_Q="$EV/.comms/to-codex/$(basename "$EV")_2026-08-29T09-06-00_ev-q.md"
printf -- '---\ntype: question\nfrom: claude\ntimestamp: 2026-08-29T09:06:00Z\nworkspace: %s\nmessage_id: ev-q-1\n---\n\n## Question\n\nWhat?\n' "$(basename "$EV")" > "$EV_Q"
run_ev send --to codex "$EV_Q" >/dev/null 2>&1 || true
[ "$(awk -F'\t' -v c="$C_MID" -v e="$C_EV" '$c=="ev-q-1"{v=$e} END{print v}' "$EV_LOG")" = "message-dispatched" ] \
  && ok "a consult is logged as itself, never as a review request" || fail "consult event kind"
[ "$(awk -F'\t' -v c="$C_MID" -v e="$C_EV" '$c=="ev-q-1" && $e=="request-persisted"' "$EV_LOG" | grep -c .)" = "0" ] \
  && ok "a consult never enters the request lifecycle it can never complete" || fail "consult wrote request events"

# The roster is persisted BEFORE any leg: legs go out sequentially, so a crash after leg 1
# of 2 is otherwise indistinguishable from a legitimate one-leg panel, and compose would
# gate on it. (codex, plan r1/r2, blocking.)
EV_PREQ="$EV/.comms/to-codex/$(basename "$EV")_2026-08-29T09-20-00_ev-panel.md"
sed 's/message_id: ev-req-1/message_id: ev-panel-1/; s/thread: ev-loop/thread: ev-panel/' "$EV_REQ" > "$EV_PREQ"
EV_POUT="$(run_ev panel dispatch --to codex,grok "$EV_PREQ" 2>&1 || true)"
EV_SET="$(printf '%s\n' "$EV_POUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ -n "$EV_SET" ] && ok "the panel dispatch named a review set" || fail "no set id (got: $EV_POUT)"
[ "$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v s="$EV_SET" '$c==s{print $e}' "$EV_LOG" | head -1)" = "panel-planned" ] \
  && ok "the expected roster is persisted before the first leg goes out" || fail "panel-planned ordering"
awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v n="$C_NOTE" -v s="$EV_SET" '$e=="panel-planned" && $c==s && $n ~ /codex/ && $n ~ /grok/' "$EV_LOG" | grep -q . \
  && ok "the roster event names every reviewer the panel expects" || fail "panel-planned roster contents"
[ "$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v s="$EV_SET" '$c==s && $e=="request-persisted"' "$EV_LOG" | grep -c .)" = "2" ] \
  && ok "each leg of the panel records its own request" || fail "per-leg request events"
# One ATTEMPT id ties the roster to the legs it planned: a set id is deterministic and a
# retry rebinds it, so two concurrent attempts interleave in one file. (codex, plan r2.)
EV_DID="$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v d="$C_DSP" -v s="$EV_SET" '$c==s && $e=="panel-planned"{print $d}' "$EV_LOG" | tail -1)"
[ -n "$EV_DID" ] && ok "the roster event names its dispatch attempt" || fail "panel-planned dispatch id"
[ "$(awk -F'\t' -v d="$C_DSP" -v e="$C_EV" -v id="$EV_DID" '$d==id && $e=="request-persisted"' "$EV_LOG" | grep -c .)" = "2" ] \
  && ok "every leg of an attempt carries that attempt's id" || fail "legs not bound to the dispatch id"

run_ev compose --set "$EV_SET" >/dev/null 2>&1 || true
awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v st="$C_ST" -v s="$EV_SET" '$c==s && $e=="composition-refused" && $st=="partial"' "$EV_LOG" | grep -q . \
  && ok "a refused partial panel is recorded, not just printed" || fail "composition-refused missing"
awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v d="$C_DSP" -v s="$EV_SET" '$c==s && $e=="composition-refused" && $d!=""' "$EV_LOG" | grep -q . \
  && ok "a composition event names the attempt it composed" || fail "composition event has no dispatch"

# TWO ATTEMPTS, INTERLEAVED. The set id is deterministic and a retry rebinds it, so
# concurrent dispatches can leave legs of both attempts in one index in any order —
# plan-A, A/codex, plan-B, B/codex, B/grok, A/grok. A reader that binds to the set alone
# reports a four-leg panel that never existed. The index is written directly here because
# the race cannot be provoked reliably from two live dispatches. (codex, implement r1.)
EV_IDX="$EV/.comms/grades/sets.tsv"
ev_idx_row() { # <mid> <thread> <agent> <dispatch>
  printf 'ev-mixed\t%s\t%s\t1\timplement\taid\tpv\tbase\tcodex\t%s\tdispatched\t\t2026-08-29T10:00:00Z\t%s\n' \
    "$1" "$2" "$3" "$4" >> "$EV_IDX"
}
# Both attempts PLANNED, A first, then their legs interleaved — the shape a pair of
# concurrent dispatches leaves behind. The index's last row belongs to attempt A; the last
# PLAN is B's, and B is what a reader must bind to. (codex, implement r2/r3.)
for ev_mix_ag in codex grok; do
  run_ev events append --kind panel-planned --set ev-mixed --dispatch d-attempt-a --agent "$ev_mix_ag" \
    --artifact aid --status planned --note "roster=codex,grok legs=2" >/dev/null
done
for ev_mix_ag in codex grok; do
  # A plan names the artifact it reviews: a plan without one is incoherent, and the snapshot
  # refuses it rather than treating an empty artifact as "any tree". (codex, implement r7.)
  run_ev events append --kind panel-planned --set ev-mixed --dispatch d-attempt-b --agent "$ev_mix_ag" \
    --artifact aid --status planned --note "roster=codex,grok legs=2" >/dev/null
done
ev_idx_row mixed-a-codex ev-mixed-a-codex codex d-attempt-a
ev_idx_row mixed-b-codex ev-mixed-b-codex codex d-attempt-b
ev_idx_row mixed-b-grok  ev-mixed-b-grok  grok  d-attempt-b
ev_idx_row mixed-a-grok  ev-mixed-a-grok  grok  d-attempt-a
EV_MIXED="$(run_ev panel status --set ev-mixed 2>/dev/null | tail -n +2)"
[ "$(printf '%s\n' "$EV_MIXED" | grep -c .)" = "2" ] \
  && ok "status reports the legs of ONE attempt, not the mixture of two" || fail "status mixed two attempts (got: $(printf '%s' "$EV_MIXED" | tr '\n' '|'))"
printf '%s\n' "$EV_MIXED" | grep -q 'ev-mixed-b-' && ! printf '%s\n' "$EV_MIXED" | grep -q 'ev-mixed-a-' \
  && ok "each reviewer contributes its row from the attempt the last PLAN named" || fail "status bound to the wrong attempt (got: $(printf '%s' "$EV_MIXED" | tr '\n' '|'))"
EV_MIXCOMP="$(run_ev compose --set ev-mixed 2>&1 || true)"
printf '%s\n' "$EV_MIXCOMP" | grep -q 'of 2 legs' \
  && ok "compose gates on one attempt's roster, never on both" || fail "compose counted both attempts (got: $(printf '%s' "$EV_MIXCOMP" | head -1))"

EV_MIDC="$(grep -m1 '^message_id:' "$(ls -t "$EV/.comms/to-codex/"*panel-codex*.md | head -1)" | sed 's/^message_id: //')"
EV_MIDG="$(grep -m1 '^message_id:' "$(ls -t "$EV/.comms/to-grok/"*panel-grok*.md | head -1)" | sed 's/^message_id: //')"
EV_WS="$(run_ev workspace)"
ev_mk_reply() { # <agent> <thread> <in-reply-to> <minute>
  local f="$EV/.comms/archive/${EV_WS}_2026-08-29T09-2${4}-00_${1}-reply.md"
  printf -- '---\ntype: review-feedback\nfrom: %s\ntimestamp: 2026-08-29T09:2%s:00Z\nworkspace: %s\nmessage_id: %s-ev-reply\nthread: %s\nin-reply-to: %s\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\nverdict: REQUEST_CHANGES\n---\n\n## Findings\n\n### Blocking\n- `s.txt:1` — %s says this is real.\n\n### Advisory\n- `s.txt:9` — %s advisory.\n' \
    "$1" "$4" "$EV_WS" "$1" "$2" "$3" "$1" "$1" > "$f"
}
ev_mk_reply codex ev-panel-codex "$EV_MIDC" 1
ev_mk_reply grok  ev-panel-grok  "$EV_MIDG" 2
run_ev compose --set "$EV_SET" >/dev/null 2>&1 || true
awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v s="$EV_SET" '$c==s && $e=="composition-completed"' "$EV_LOG" | grep -q . \
  && ok "a completed composition closes the set's trace" || fail "composition-completed missing"
awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v n="$C_NOTE" -v s="$EV_SET" '$c==s && $e=="composition-completed" && $n ~ /corroborated=1/' "$EV_LOG" | grep -q . \
  && ok "the composition event carries what the gate actually found" || fail "composition counts"

# ...and now through the PRODUCER. The hand-written rows above test the selector; they
# cannot see the write path, and the write path was the defect: dispatch deleted every
# same-set/same-agent row, so a second attempt ATE the first attempt's legs and the index
# ended up holding one leg of each. A retry is DETERMINISTIC — same request over the same
# tree recreates the set id — so this is a second attempt, not a second set. (`--set` is
# only a seed: safe_set_id appends a hash, so feeding the resolved id back in would make a
# different set and test nothing.) (codex + grok, implement r2, corroborated.)
EV_D1="$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v d="$C_DSP" -v s="$EV_SET" '$c==s && $e=="panel-planned"{print $d}' "$EV_LOG" | tail -1)"
EV_RD="$(run_ev panel dispatch --to codex,grok "$EV_PREQ" 2>&1 || true)"
EV_RDSET="$(printf '%s\n' "$EV_RD" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ "$EV_RDSET" = "$EV_SET" ] && ok "a retry over the same tree recreates the same set" || fail "retry set id drifted ($EV_SET vs $EV_RDSET)"
EV_D2="$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v d="$C_DSP" -v s="$EV_SET" '$c==s && $e=="panel-planned"{print $d}' "$EV_LOG" | tail -1)"
[ -n "$EV_D2" ] && [ "$EV_D1" != "$EV_D2" ] && ok "a re-dispatch mints a new attempt id" || fail "re-dispatch reused the attempt id"
[ "$(awk -F'\t' -v s="$EV_SET" -v d="$EV_D1" 'NR>1 && $1==s && $14==d' "$EV/.comms/grades/sets.tsv" | grep -c .)" = "2" ] \
  && ok "the FIRST attempt's legs survive a re-dispatch instead of being eaten" || fail "a re-dispatch deleted the earlier attempt's rows"
[ "$(awk -F'\t' -v s="$EV_SET" -v d="$EV_D2" 'NR>1 && $1==s && $14==d' "$EV/.comms/grades/sets.tsv" | grep -c .)" = "2" ] \
  && ok "the new attempt records its own two legs" || fail "the new attempt is not fully recorded"
[ "$(run_ev panel status --set "$EV_SET" 2>/dev/null | tail -n +2 | grep -c .)" = "2" ] \
  && ok "status still reports exactly one attempt's legs after a real re-dispatch" || fail "status mixed two real attempts"
# REFUSING beats guessing. A torn log could have torn the very plan row the binding reads,
# and a missing log with attempts recorded is the last-row-wins binding this round removed —
# both refuse loudly now instead of silently degrading. Only a set with no attempt anywhere,
# which is what a pre-column set looks like, may still bind. (codex, implement r3, blocking.)
EV_RF="$WORK/events-refuse"; mkdir -p "$EV_RF"; EV_RF="$(cd "$EV_RF" && pwd -P)"
git -C "$EV_RF" init -q -b main
printf '.comms/\n' > "$EV_RF/.gitignore"; echo s > "$EV_RF/s.txt"
git -C "$EV_RF" add -A >/dev/null 2>&1
git -C "$EV_RF" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$EV_RF/.comms/to-codex" "$EV_RF/.comms/to-grok" "$EV_RF/.comms/to-claude" "$EV_RF/.comms/archive" "$EV_RF/.comms/grades"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$EV_RF/.comms/config"
run_evrf() { (cd "$EV_RF" && env COMMS_DELIVERY=mailbox PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }
EV_RFREQ="$EV_RF/.comms/to-codex/$(basename "$EV_RF")_2026-08-29T09-00-00_rf.md"
printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-08-29T09:00:00Z\nworkspace: %s\nmessage_id: rf-1\nthread: rf-th\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\n---\n\n## What was done\nA change worth reviewing.\n' "$(basename "$EV_RF")" > "$EV_RFREQ"
EV_RFOUT="$(run_evrf panel dispatch --to codex,grok "$EV_RFREQ" 2>&1 || true)"
EV_RFSET="$(printf '%s\n' "$EV_RFOUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
run_evrf panel status --set "$EV_RFSET" >/dev/null 2>&1 \
  && ok "a clean log binds the attempt without complaint" || fail "a clean log failed to bind"
cp "$EV_RF/.comms/events.tsv" "$WORK/rf-events-clean.tsv"
printf 'a torn row\n' >> "$EV_RF/.comms/events.tsv"
run_evrf panel status --set "$EV_RFSET" >/dev/null 2>&1 \
  && fail "a torn log still bound an attempt" || ok "a torn log refuses to bind an attempt rather than guessing"
run_evrf compose --set "$EV_RFSET" >/dev/null 2>&1 \
  && fail "compose gated with a torn log" || ok "compose refuses to gate on a guessed roster"
rm -f "$EV_RF/.comms/events.tsv"
run_evrf panel status --set "$EV_RFSET" >/dev/null 2>&1 \
  && fail "a missing log fell back to last-row-wins" || ok "a missing log with attempts recorded refuses, never falls back"
# A VANISHED PLAN IS UNKNOWN, NOT LEGACY. Legacy-ness is settled from the index: a set whose
# legs name an attempt can never fall back to "no plan means no roster", or a lost log would
# clear the roster and let compose gate from partial index rows. (codex, implement r8.)
cp "$EV_RF/.comms/events.tsv" "$WORK/rf-events-keep.tsv" 2>/dev/null || :
rm -f "$EV_RF/.comms/events.tsv"
run_evrf compose --set "$EV_RFSET" >/dev/null 2>&1 \
  && fail "a vanished plan composed from index rows alone" || ok "a vanished plan is UNKNOWN, never legacy"
cp "$WORK/rf-events-keep.tsv" "$EV_RF/.comms/events.tsv" 2>/dev/null || :

# ...AND THE INDEX ROWS ARE NOT WHAT SETTLES IT. A modern attempt that crashes between its
# plan and its first leg row leaves an index holding nothing but legacy-shaped rows, which
# reads exactly like a set dispatched before attempts existed — so both readers would call
# it legacy and compose the PREVIOUS round's bound replies, silently discarding the newer
# attempt. `panel dispatch` therefore stakes a durable marker before anything else it
# writes, and that marker, not the absence of an attempt-bearing row, is the proof.
# (codex, implement r9, blocking.)
[ -f "$EV_RF/.comms/grades/attempts/$EV_RFSET" ] \
  && ok "a dispatch stakes a durable attempts marker" || fail "no attempts marker was staked for $EV_RFSET"
cp "$EV_RF/.comms/grades/sets.tsv" "$WORK/rf-sets-keep.tsv"
# The crash: the plan is staked, then nothing else lands. Only legacy-shaped rows remain.
awk -F'\t' -v s="$EV_RFSET" 'NR==1 || $1!=s' "$WORK/rf-sets-keep.tsv" > "$EV_RF/.comms/grades/sets.tsv"
printf '%s\tcrash-1\trf-th-codex\t1\timplement\taid\tpv\tbase\tcodex\tcodex\tdispatched\t\t2026-08-29T11:00:00Z\n' \
  "$EV_RFSET" >> "$EV_RF/.comms/grades/sets.tsv"
rm -f "$EV_RF/.comms/events.tsv"
EV_CRASHED="$(run_evrf compose --set "$EV_RFSET" 2>&1 || true)"
printf '%s\n' "$EV_CRASHED" | grep -q 'dispatched under a recorded attempt' \
  && ok "compose calls a crashed modern attempt UNKNOWN, not legacy" || fail "compose read a crashed attempt as legacy ($EV_CRASHED)"
EV_CRASHST="$(run_evrf panel status --set "$EV_RFSET" 2>&1 || true)"
printf '%s\n' "$EV_CRASHST" | grep -q 'dispatched under a recorded attempt' \
  && ok "panel status calls a crashed modern attempt UNKNOWN, not legacy" || fail "panel status read a crashed attempt as legacy ($EV_CRASHST)"
# THE CONTROL, and the defect itself. Remove ONLY the marker and the very same index
# reads as legacy: compose invents a one-leg roster out of the leftover legacy row and
# gates on it, when the attempt that actually ran planned two. Nothing else about the
# fixture changes, so the assertions above cannot be passing on some unrelated guard.
# The mv is CHECKED. Unchecked, it no-ops on a tree where no marker was ever staked, the
# fixture goes unchanged, compose repeats the refusal it gave two lines earlier, and this
# assertion prints green while asserting a mechanism that does not exist. (Found by
# reverting helpers/comms.sh under the new tests: A1-A3 went red and this one stayed green.)
if ! command mv -f "$EV_RF/.comms/grades/attempts/$EV_RFSET" "$WORK/rf-marker-keep" 2>/dev/null; then
  fail "the no-marker control had no marker to remove — it was never staked"
else
  EV_NOMARK="$(run_evrf compose --set "$EV_RFSET" 2>&1 || true)"
  if printf '%s\n' "$EV_NOMARK" | grep -q 'dispatched under a recorded attempt'; then
    fail "the index rows, not the marker, were settling legacy-ness"
  elif printf '%s\n' "$EV_NOMARK" | grep -q '0 of 1 legs'; then
    ok "the marker, not the index rows, is what settles legacy-ness"
  else
    fail "the no-marker control did not reproduce the legacy misread ($EV_NOMARK)"
  fi
fi
command mv -f "$WORK/rf-marker-keep" "$EV_RF/.comms/grades/attempts/$EV_RFSET"
command cp -f "$WORK/rf-sets-keep.tsv" "$EV_RF/.comms/grades/sets.tsv"
cp "$WORK/rf-events-keep.tsv" "$EV_RF/.comms/events.tsv" 2>/dev/null || :

# THE ORDER IS THE MECHANISM, so the order is what has to be pinned. Every assertion above
# builds its crash by HAND, after a dispatch that ran to completion — so all of them stay
# green on a tree where the marker is staked LAST, which is the one arrangement that puts
# codex's defect straight back. Kill a dispatch for real instead: make the gating agent's
# inbox unwritable and it dies at its first leg, after the plan events and before its first
# index row. That is the exact window, and the marker must already be on disk when it lands.
EV_ORDREQ="$EV_RF/.comms/to-codex/$(basename "$EV_RF")_2026-08-29T09-30-00_ord.md"
printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-08-29T09:30:00Z\nworkspace: %s\nmessage_id: ord-1\nthread: ord-th\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\n---\n\n## What was done\nA change worth reviewing.\n' "$(basename "$EV_RF")" > "$EV_ORDREQ"
cp "$EV_RF/.comms/events.tsv" "$WORK/rf-events-preord.tsv" 2>/dev/null || :
chmod 500 "$EV_RF/.comms/to-codex"
EV_ORDOUT="$(run_evrf panel dispatch --to codex,grok "$EV_ORDREQ" 2>&1 || true)"
chmod 755 "$EV_RF/.comms/to-codex"
EV_ORDSET="$(awk -F'\t' '$3=="panel-planned" {print $4}' "$EV_RF/.comms/events.tsv" 2>/dev/null | tail -1)"
if [ -z "$EV_ORDSET" ] || [ "$EV_ORDSET" = "$EV_RFSET" ]; then
  fail "the mid-dispatch death fixture did not plan a new set (got '$EV_ORDSET')"
elif awk -F'\t' -v s="$EV_ORDSET" 'NR>1 && $1==s' "$EV_RF/.comms/grades/sets.tsv" | grep -q .; then
  fail "the dispatch got as far as an index row — that is not the window this pins ($EV_ORDOUT)"
else
  [ -f "$EV_RF/.comms/grades/attempts/$EV_ORDSET" ] \
    && ok "a dispatch that dies before its first leg row has already staked its marker" \
    || fail "the marker is staked too late: a dispatch died mid-flight and left none ($EV_ORDOUT)"
fi
# ...and that marker is what makes the wreckage refuse. Complete codex's sequence on it:
# the log goes, and only a legacy-shaped row for the set is left behind.
rm -f "$EV_RF/.comms/events.tsv"
printf '%s\tord-crash\tord-th-codex\t1\timplement\taid\tpv\tbase\tcodex\tcodex\tdispatched\t\t2026-08-29T11:30:00Z\n' \
  "$EV_ORDSET" >> "$EV_RF/.comms/grades/sets.tsv"
EV_ORDC="$(run_evrf compose --set "$EV_ORDSET" 2>&1 || true)"
printf '%s\n' "$EV_ORDC" | grep -q 'dispatched under a recorded attempt' \
  && ok "a really-crashed dispatch refuses instead of composing the legacy row" \
  || fail "a really-crashed dispatch composed from index rows alone ($EV_ORDC)"
command cp -f "$WORK/rf-sets-keep.tsv" "$EV_RF/.comms/grades/sets.tsv"
cp "$WORK/rf-events-preord.tsv" "$EV_RF/.comms/events.tsv" 2>/dev/null || :
rm -f "$EV_ORDREQ"

printf 'legacy-set\tlm-1\tlegacy-codex\t1\timplement\taid\tpv\tbase\tcodex\tcodex\tdispatched\t\t2026-08-29T10:00:00Z\n' >> "$EV_RF/.comms/grades/sets.tsv"
[ "$(run_evrf panel status --set legacy-set 2>/dev/null | tail -n +2 | grep -c .)" = "1" ] \
  && ok "a set recorded before attempts existed still binds" || fail "a legacy set stopped binding"
cp "$WORK/rf-events-clean.tsv" "$EV_RF/.comms/events.tsv"
# A torn row BEFORE the plan must not block anything. Refusing on a malformed row anywhere
# bricked this repo the moment the schema grew: rows and a header from the older shape sit
# at the top of the live log, so every compose and status refused. What can hide the current
# plan is a torn row AFTER it. (grok, implement r4, blocking — and hit live.)
EV_RFCLEAN="$(cat "$EV_RF/.comms/events.tsv")"
{ printf 'an ancient torn row\n'; printf '%s\n' "$EV_RFCLEAN"; } > "$EV_RF/.comms/events.tsv"
run_evrf panel status --set "$EV_RFSET" >/dev/null 2>&1 \
  && ok "a torn row that PRECEDES the plan does not block binding" || fail "an old torn row still bricks binding"
cp "$WORK/rf-events-clean.tsv" "$EV_RF/.comms/events.tsv"
# The bare listing keeps its pinned header and counts the CURRENT attempt.
run_evrf panel dispatch --to codex,grok "$EV_RFREQ" >/dev/null 2>&1 || true
EV_RFHDR="$(run_evrf panel status 2>/dev/null)"
[ "$(printf '%s\n' "$EV_RFHDR" | sed -n 1p)" = "$(printf 'set\tphase\tround\tlegs\tcreated')" ] \
  && ok "the bare listing keeps its pinned header, first" || fail "bare listing header changed (got: $(printf '%s' "$EV_RFHDR" | sed -n 1p))"
[ "$(run_evrf panel status 2>/dev/null | awk -F'\t' -v s="$EV_RFSET" '$1==s{print $4}')" = "2" ] \
  && ok "the bare listing counts the current attempt, not every attempt ever recorded" || fail "bare listing counted historical rows"

# THE ROSTER IS ENFORCED, not merely recorded. A dispatch that dies between two leg rows
# leaves the index one leg short, and counting index rows alone made that compose as a
# complete one-leg panel — the very hole the plan event was added to close. Deleting a leg
# row is exactly what that crash leaves behind. (codex, implement r5, blocking.)
EV_CRASH="$WORK/events-crash"; mkdir -p "$EV_CRASH"; EV_CRASH="$(cd "$EV_CRASH" && pwd -P)"
git -C "$EV_CRASH" init -q -b main
printf '.comms/\n' > "$EV_CRASH/.gitignore"; echo s > "$EV_CRASH/s.txt"
git -C "$EV_CRASH" add -A >/dev/null 2>&1
git -C "$EV_CRASH" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$EV_CRASH/.comms/to-codex" "$EV_CRASH/.comms/to-grok" "$EV_CRASH/.comms/to-claude" "$EV_CRASH/.comms/archive" "$EV_CRASH/.comms/grades"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$EV_CRASH/.comms/config"
run_evcr() { (cd "$EV_CRASH" && env COMMS_DELIVERY=mailbox PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }
EV_CRREQ="$EV_CRASH/.comms/to-codex/$(basename "$EV_CRASH")_2026-08-29T09-00-00_cr.md"
printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-08-29T09:00:00Z\nworkspace: %s\nmessage_id: cr-1\nthread: cr-th\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\n---\n\n## What was done\nA change worth reviewing.\n' "$(basename "$EV_CRASH")" > "$EV_CRREQ"
EV_CROUT="$(run_evcr panel dispatch --to codex,grok "$EV_CRREQ" 2>&1 || true)"
EV_CRSET="$(printf '%s\n' "$EV_CROUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ "$(run_evcr events --set "$EV_CRSET" --kind panel-planned 2>/dev/null | tail -n +2 | grep -c .)" = "2" ] \
  && ok "the roster is recorded as one plan row per planned reviewer" || fail "the roster is not machine-readable"
# Simulate the crash: drop grok's leg row from the index, as a death between appends would.
EV_CRIDX="$EV_CRASH/.comms/grades/sets.tsv"
awk -F'\t' 'NR==1 || !($10=="grok")' "$EV_CRIDX" > "$EV_CRIDX.tmp" && mv "$EV_CRIDX.tmp" "$EV_CRIDX"
EV_CRCOMP="$(run_evcr compose --set "$EV_CRSET" 2>&1 || true)"
printf '%s\n' "$EV_CRCOMP" | grep -q 'never finished recording' \
  && ok "compose refuses a roster the dispatch never finished recording" || fail "a truncated roster composed (got: $(printf '%s' "$EV_CRCOMP" | head -1))"
# Not `grep '1 of 1'` — compose cannot emit that string, so the assertion passed with the
# roster gate deleted. What must be true is that the truncated panel never reports a quorum
# and never records a completion. (self-review, round 6: vacuous fixture.)
printf '%s\n' "$EV_CRCOMP" | grep -q 'all answered' && fail "a truncated roster reported a quorum" || ok "a truncated roster never reports itself answered"
printf '%s\n' "$EV_CRCOMP" | grep -q 'grok' \
  && ok "the refusal names the reviewer whose leg row is missing" || fail "the refusal does not name the missing reviewer"
run_evcr events --set "$EV_CRSET" --kind composition-completed 2>/dev/null | tail -n +2 | grep -q . \
  && fail "a truncated roster recorded a completed composition" || ok "no composition is recorded for a roster that never completed"
run_evcr events --set "$EV_CRSET" --kind composition-refused 2>/dev/null | tail -n +2 | grep -q 'roster-incomplete' \
  && ok "the roster refusal is recorded, not just printed" || fail "roster refusal not recorded"
[ "$(run_evcr panel status --set "$EV_CRSET" 2>/dev/null | tail -n +2 | grep -c .)" = "2" ] \
  && ok "status still lists a planned leg whose index row vanished" || fail "status hid the missing leg"
# NOTHING IS PUBLISHED BEFORE IT IS VERIFIED. The supersession check runs after the
# composition is built, so publishing as it was built put an authoritative-looking
# "all answered" document on stdout and permanently into --out before anything had
# confirmed the attempt was still current. (codex, implement r8, blocking.)
rm -f "$WORK/cr-out.md"
EV_CROUT2="$(run_evcr compose --set "$EV_CRSET" --out "$WORK/cr-out.md" 2>&1 || true)"
[ ! -s "$WORK/cr-out.md" ] \
  && ok "a refused composition writes nothing to --out" || fail "a refused composition left a document behind"
printf '%s\n' "$EV_CROUT2" | grep -q 'all answered' \
  && fail "a refused composition still printed a panel" || ok "a refused composition prints only its refusal"

EV_CRSTAT="$(run_evcr panel status --set "$EV_CRSET" 2>/dev/null)"
printf '%s\n' "$EV_CRSTAT" | grep -q 'no leg row recorded' \
  && ok "the missing leg is named as missing, not silently unanswered" || fail "the missing leg was not named"
# Captured, not piped into `head`: the suite runs with pipefail, so a producer killed by
# SIGPIPE fails the assertion even when the grep matched. The property under test is "the
# header is line 1", which a capture states directly. (self-review follow-up, round 6.)
EV_CRHDR="$(run_evcr panel status --set "$EV_CRSET" 2>/dev/null)"
[ "$(printf '%s\n' "$EV_CRHDR" | sed -n 1p | cut -f1)" = "reviewer" ] \
  && ok "panel status --set prints its header first" || fail "status header ordering (line 1 was: $(printf '%s' "$EV_CRHDR" | sed -n 1p))"

# A SUBSET RE-DISPATCH MUST NOT SHRINK THE PANEL. Retrying one leg that failed to deliver is
# the remedy PROTOCOL recommends, and it plans a one-agent roster — so binding strictly to
# the last attempt silently dropped the other reviewer, hid it from `panel status`, and let
# `compose` gate without its findings. `main` never did this; the arc introduced it.
# (self-review, round 6, reproduced side by side against main.)
EV_SUB="$WORK/events-subset"; mkdir -p "$EV_SUB"; EV_SUB="$(cd "$EV_SUB" && pwd -P)"
git -C "$EV_SUB" init -q -b main
printf '.comms/\n' > "$EV_SUB/.gitignore"; echo s > "$EV_SUB/s.txt"
git -C "$EV_SUB" add -A >/dev/null 2>&1
git -C "$EV_SUB" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$EV_SUB/.comms/to-codex" "$EV_SUB/.comms/to-grok" "$EV_SUB/.comms/to-claude" "$EV_SUB/.comms/archive" "$EV_SUB/.comms/grades"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$EV_SUB/.comms/config"
run_evsub() { (cd "$EV_SUB" && env COMMS_DELIVERY=mailbox PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }
EV_SUBREQ="$EV_SUB/.comms/to-codex/$(basename "$EV_SUB")_2026-08-29T09-00-00_sub.md"
printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-08-29T09:00:00Z\nworkspace: %s\nmessage_id: sub-1\nthread: sub-th\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\n---\n\n## What was done\nA change worth reviewing.\n' "$(basename "$EV_SUB")" > "$EV_SUBREQ"
EV_SUBOUT="$(run_evsub panel dispatch --to codex,grok "$EV_SUBREQ" 2>&1 || true)"
EV_SUBSET="$(printf '%s\n' "$EV_SUBOUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ "$(run_evsub panel status --set "$EV_SUBSET" 2>/dev/null | tail -n +2 | grep -c .)" = "2" ] \
  && ok "the full panel lists both legs" || fail "the full panel did not list two legs"
run_evsub panel dispatch --to grok "$EV_SUBREQ" >/dev/null 2>&1 || true
EV_SUBST="$(run_evsub panel status --set "$EV_SUBSET" 2>/dev/null | tail -n +2)"
[ "$(printf '%s\n' "$EV_SUBST" | grep -c .)" = "2" ] \
  && ok "re-dispatching ONE leg does not shed the other reviewer" || fail "a subset re-dispatch shrank the panel to $(printf '%s\n' "$EV_SUBST" | grep -c .) leg(s)"
printf '%s\n' "$EV_SUBST" | grep -q '^codex' \
  && ok "the reviewer that was not re-dispatched keeps its leg" || fail "the untouched reviewer vanished from the panel"
EV_SUBCOMP="$(run_evsub compose --set "$EV_SUBSET" 2>&1 || true)"
printf '%s\n' "$EV_SUBCOMP" | grep -q 'no reply yet from' \
  && ok "compose still waits for the leg a subset retry did not touch" || fail "compose gated a narrowed panel (got: $(printf '%s' "$EV_SUBCOMP" | head -1))"
printf '%s\n' "$EV_SUBCOMP" | grep -q 'of 2 legs' \
  && ok "the narrowed attempt still gates on the FULL roster" || fail "compose forgot a planned reviewer"

# CARRY-FORWARD IS FOR THE UNRE-DISPATCHED ONLY. An agent the CURRENT attempt planned must
# have a CURRENT row: substituting its previous one would let a dispatch that crashed after
# its plan and before that leg's row compose the earlier attempt's reply as this attempt's
# answer. (codex, implement r6, blocking.)
run_evsub panel dispatch --to codex,grok "$EV_SUBREQ" >/dev/null 2>&1 || true
EV_SUBD3="$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v d="$C_DSP" -v s="$EV_SUBSET" '$c==s && $e=="panel-planned"{print $d}' "$EV_SUB/.comms/events.tsv" | tail -1)"
EV_SUBIDX="$EV_SUB/.comms/grades/sets.tsv"
awk -F'\t' -v d="$EV_SUBD3" 'NR==1 || !($10=="grok" && $14==d)' "$EV_SUBIDX" > "$EV_SUBIDX.tmp" && mv "$EV_SUBIDX.tmp" "$EV_SUBIDX"
EV_SUBC3="$(run_evsub compose --set "$EV_SUBSET" 2>&1 || true)"
printf '%s\n' "$EV_SUBC3" | grep -q 'never finished recording' \
  && ok "an agent planned by THIS attempt cannot be answered by its previous leg" || fail "a crashed re-dispatch substituted the earlier attempt's leg (got: $(printf '%s' "$EV_SUBC3" | head -1))"
EV_SUBSTAT="$(run_evsub panel status --set "$EV_SUBSET" 2>/dev/null)"
printf '%s\n' "$EV_SUBSTAT" | grep -q 'no leg row recorded' \
  && ok "status names the leg the current attempt planned and never recorded" || fail "status substituted a stale leg"

# CARRY-FORWARD IS ARTIFACT-BOUND. An explicit --set reused across two different trees, then
# subset-dispatched, would otherwise resurrect the other reviewer's row — and its reply — from
# the EARLIER artifact, and compose would report a mixed-artifact panel as all answered.
# (codex, implement r6, blocking.)
EV_ART="$WORK/events-artifact"; mkdir -p "$EV_ART"; EV_ART="$(cd "$EV_ART" && pwd -P)"
git -C "$EV_ART" init -q -b main
printf '.comms/\n' > "$EV_ART/.gitignore"; echo one > "$EV_ART/s.txt"
git -C "$EV_ART" add -A >/dev/null 2>&1
git -C "$EV_ART" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$EV_ART/.comms/to-codex" "$EV_ART/.comms/to-grok" "$EV_ART/.comms/to-claude" "$EV_ART/.comms/archive" "$EV_ART/.comms/grades"
printf 'agents = claude codex grok\ndefault-target = codex\n' > "$EV_ART/.comms/config"
run_evart() { (cd "$EV_ART" && env COMMS_DELIVERY=mailbox PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 "$COMMS" "$@"); }
EV_ARTREQ="$EV_ART/.comms/to-codex/$(basename "$EV_ART")_2026-08-29T09-00-00_art.md"
printf -- '---\ntype: review-request\nfrom: claude\ntimestamp: 2026-08-29T09:00:00Z\nworkspace: %s\nmessage_id: art-1\nthread: art-th\nworkflow: auto\nphase: implement\nround: 1\nmax-rounds: 4\n---\n\n## What was done\nA change worth reviewing.\n' "$(basename "$EV_ART")" > "$EV_ARTREQ"
EV_ARTOUT="$(run_evart panel dispatch --to codex,grok --set pinned-set "$EV_ARTREQ" 2>&1 || true)"
EV_ARTSET="$(printf '%s\n' "$EV_ARTOUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
echo two > "$EV_ART/s.txt"   # a DIFFERENT tree, so a different artifact
git -C "$EV_ART" -c user.email=t@t -c user.name=t commit -q -am second
EV_ARTOUT2="$(run_evart panel dispatch --to grok --set pinned-set "$EV_ARTREQ" 2>&1 || true)"
EV_ARTSET2="$(printf '%s\n' "$EV_ARTOUT2" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ "$EV_ARTSET2" = "$EV_ARTSET" ] \
  && ok "an explicit --set really does collide across artifacts" || fail "the artifact fixture never collided ($EV_ARTSET vs $EV_ARTSET2)"
EV_ARTSTAT="$(run_evart panel status --set "$EV_ARTSET" 2>/dev/null)"
printf '%s\n' "$EV_ARTSTAT" | grep -q 'no leg row recorded' \
  && ok "a leg from a DIFFERENT artifact is never carried into this panel" || fail "a stale-artifact leg was resurrected"

# CARRY-FORWARD REACHES BACKWARD ONLY. With three attempts — A plans both, B re-dispatches
# codex, C re-dispatches grok — the bound attempt is C, and codex must be answered by B's
# leg. "Any row that is not the bound one" would have let a NEWER concurrent attempt's leg be
# adopted as a previous one. (codex, implement r7, blocking.)
run_evsub panel dispatch --to codex "$EV_SUBREQ" >/dev/null 2>&1 || true
EV_SUBDB="$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v d="$C_DSP" -v s="$EV_SUBSET" '$c==s && $e=="panel-planned"{print $d}' "$EV_SUB/.comms/events.tsv" | tail -1)"
run_evsub panel dispatch --to grok "$EV_SUBREQ" >/dev/null 2>&1 || true
EV_SUBDC="$(awk -F'\t' -v c="$C_SET" -v e="$C_EV" -v d="$C_DSP" -v s="$EV_SUBSET" '$c==s && $e=="panel-planned"{print $d}' "$EV_SUB/.comms/events.tsv" | tail -1)"
[ -n "$EV_SUBDB" ] && [ -n "$EV_SUBDC" ] && [ "$EV_SUBDB" != "$EV_SUBDC" ] \
  && ok "three attempts leave three distinct ids in the chain" || fail "the chain fixture did not produce distinct attempts"
EV_SUBST3="$(run_evsub panel status --set "$EV_SUBSET" 2>/dev/null | tail -n +2)"
[ "$(printf '%s\n' "$EV_SUBST3" | grep -c .)" = "2" ] \
  && ok "a chain of subset retries still lists the whole roster" || fail "a chain of retries shrank the panel"
EV_SUBCODEXMID="$(awk -F'\t' -v s="$EV_SUBSET" -v d="$EV_SUBDB" 'NR>1 && $1==s && $10=="codex" && $14==d {print $2}' "$EV_SUB/.comms/grades/sets.tsv" | tail -1)"
printf '%s\n' "$EV_SUBST3" | grep -q "^codex" && [ -n "$EV_SUBCODEXMID" ] \
  && ok "the carried leg comes from an attempt EARLIER in the chain, not a newer one" || fail "carry-forward picked the wrong attempt"

# A plan row with no artifact is INCOHERENT, not permissive: an empty artifact used to mean
# "carry a row from any tree". (codex, implement r7, blocking.)
run_evsub events append --kind panel-planned --set ev-noart --dispatch d-noart --agent codex --status planned >/dev/null
run_evsub panel status --set ev-noart >/dev/null 2>&1 \
  && fail "a plan with no artifact still bound an attempt" || ok "a plan that names no artifact refuses rather than matching any tree"

# A set id long enough to exceed the events column must be stored IDENTICALLY in sets.tsv
# and in the log, or the two can never be joined. Querying an id nobody ever wrote proved
# nothing — it returns zero rows whether or not safe_set_id bounds anything.
# (self-review, round 6: vacuous fixture.)
EV_LONGTH="thr-$(awk 'BEGIN{while(i++<160)printf "q"}')"
EV_LONGREQ="$EV/.comms/to-codex/$(basename "$EV")_2026-08-29T09-50-00_longid.md"
sed "s/message_id: ev-req-1/message_id: ev-longid-1/; s/thread: ev-loop/thread: $EV_LONGTH/" "$EV_REQ" > "$EV_LONGREQ"
EV_LONGOUT="$(run_ev panel dispatch --to codex,grok "$EV_LONGREQ" 2>&1 || true)"
EV_LONGSET="$(printf '%s\n' "$EV_LONGOUT" | sed -n 's/.*as review set \([^ ]*\) .*/\1/p' | head -1)"
[ -n "$EV_LONGSET" ] && [ "${#EV_LONGSET}" -le 80 ] \
  && ok "a set id derived from a long thread is bounded at its source" || fail "set id unbounded (${#EV_LONGSET} bytes)"
[ "$(awk -F'\t' -v s="$EV_LONGSET" 'NR>1 && $1==s' "$EV/.comms/grades/sets.tsv" | grep -c .)" = "2" ] \
  && ok "the bounded id is what the index stores" || fail "the index stores a different id"
[ "$(awk -F'\t' -v c="$C_SET" -v s="$EV_LONGSET" -v e="$C_EV" '$c==s && $e=="panel-planned"' "$EV_LOG" | grep -c .)" = "2" ] \
  && ok "the log stores the SAME bytes, so the two can be joined" || fail "index and log disagree on a long set id"
[ "$(run_ev panel status --set "$EV_LONGSET" 2>/dev/null | tail -n +2 | grep -c .)" = "2" ] \
  && ok "a long set id still binds its attempt" || fail "a long set id could not find its own plan"

# The PLAN event is the authority, not the last row: append a stale leg row for the OLD
# attempt after the new one and the binding must not follow it.
printf '%s\ty\tz\t1\timplement\taid\tpv\tbase\tcodex\tcodex\tdispatched\t\t2026-08-29T10:00:00Z\t%s\n' "$EV_SET" "$EV_D1" >> "$EV/.comms/grades/sets.tsv"
[ "$(run_ev panel status --set "$EV_SET" 2>/dev/null | tail -n +2 | grep -c .)" = "2" ] \
  && ok "a stale row appended after the plan cannot move the binding" || fail "the binding followed the last row instead of the plan event"


# CRITERION 4: the events that matter are written by the DETACHED runner. `send` returns at
# spawn, so every row below was appended by a process the dispatching shell no longer owns.
EV_HL="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-10-00_ev-hl.md"
sed 's/message_id: ev-req-1/message_id: ev-hl-1/; s/thread: ev-loop/thread: ev-headless/' "$EV_REQ" > "$EV_HL"
run_ev_hl() { (cd "$EV" && env COMMS_DELIVERY=headless PATH="$STUB_BIN:$PATH" "$COMMS" "$@"); }
mkdir -p "$EV/.comms/to-grok"
EV_HLOUT="$(run_ev_hl send --to grok "$EV_HL" 2>/dev/null)"
EV_HLDIR="$(rundir_of "$EV_HLOUT")"
[ -n "$EV_HLDIR" ] && ok "the headless dispatch spawned a detached runner" || fail "no run dir (got: $EV_HLOUT)"
awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-headless" && $e=="turn-started"' "$EV_LOG" | grep -q . \
  && fail "turn-started was written before any runner ran" \
  || ok "no turn is claimed to have started before its runner runs"
(cd "$EV" && env PATH="$STUB_BIN:$PATH" "$RUNPHASE" await "$EV_HLDIR" --timeout-secs 60 >/dev/null 2>&1) || true
awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-headless" && $e=="turn-started"' "$EV_LOG" | grep -q . \
  && ok "the detached runner records that the turn started" || fail "runner turn-started missing"
awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v st="$C_ST" '$t=="ev-headless" && $e=="provider-result" && $st!=""' "$EV_LOG" | grep -q . \
  && ok "the detached runner records the provider's own result" || fail "runner provider-result missing"
awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v st="$C_ST" '$t=="ev-headless" && $e=="turn-finished" && $st!=""' "$EV_LOG" | grep -q . \
  && ok "the turn's terminal status is a separate, later event" || fail "turn-finished missing"
[ "$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-headless" && $e=="turn-finished"' "$EV_LOG" | grep -c .)" = "1" ] \
  && ok "the terminal event is written once, not again by the exit trap" || fail "turn-finished double-counted"
EV_ORDER="$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-headless" && ($e=="turn-started" || $e=="provider-result" || $e=="turn-finished"){printf "%s ", $e}' "$EV_LOG")"
[ "$EV_ORDER" = "turn-started provider-result turn-finished " ] \
  && ok "the provider's result precedes the turn's terminal status" || fail "runner event order (got: $EV_ORDER)"
[ -f "$EV_HLDIR/turn.tsv" ] && grep -q '^thread	ev-headless$' "$EV_HLDIR/turn.tsv" \
  && ok "the runner leaves its identity where a synthetic result can find it" || fail "turn.tsv identity"

# A runner killed before it can write result.json: await synthesizes one, and the terminal
# event must still name the right leg or a kill is a permanent unknown. (grok, plan r2.)
EV_KL="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-11-00_ev-kill.md"
sed 's/message_id: ev-req-1/message_id: ev-kill-1/; s/thread: ev-loop/thread: ev-killed/' "$EV_REQ" > "$EV_KL"
EV_KOUT="$(GROK_STUB_HANG=30 run_ev_hl send --to grok "$EV_KL" 2>/dev/null)"
EV_KDIR="$(rundir_of "$EV_KOUT")"
sleep 2
kill -9 "$(cat "$EV_KDIR/pid" 2>/dev/null)" 2>/dev/null || true
(cd "$EV" && env PATH="$STUB_BIN:$PATH" "$RUNPHASE" await "$EV_KDIR" --timeout-secs 30 >/dev/null 2>&1) || true
awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-killed" && $e=="turn-finished"' "$EV_LOG" | grep -q . \
  && ok "a killed runner still gets a terminal event, from the awaiting process" || fail "synthetic turn-finished missing"

EV_GMSG="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-30-00_ev-grok.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-1/; s/thread: ev-loop/thread: ev-grok/' "$EV_REQ" > "$EV_GMSG"
EV_GDIR="$WORK/ev-grok-leg"; mkdir -p "$EV_GDIR"
(cd "$EV" && env PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   GROK_STUB_NO_VERDICT=1 "$RUNPHASE" run --message "$EV_GMSG" --dir "$EV_GDIR" --provider grok) >/dev/null 2>&1 || true
awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v n="$C_NOTE" '$t=="ev-grok" && $e=="reply-refused" && $n!=""' "$EV_LOG" | grep -q . \
  && ok "a refused reply records WHY, outside the run dir" || fail "reply-refused missing"
awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-grok" && $e=="reply-accepted"' "$EV_LOG" | grep -q . \
  && fail "a refused reply was also recorded as accepted" || ok "a refusal never counts as an acceptance"

# An EXTRACTION failure returned before the stamping half ever ran, so the loudest broker
# failure was the one with no event. The boundary is the whole pipeline now. (codex, r1.)
EV_GMSGX="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-34-00_ev-grokx.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-x/; s/thread: ev-loop/thread: ev-noresult/' "$EV_REQ" > "$EV_GMSGX"
EV_GDIRX="$WORK/ev-grok-legx"; mkdir -p "$EV_GDIRX"
(cd "$EV" && env PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   GROK_STUB_NO_RESULT=1 "$RUNPHASE" run --message "$EV_GMSGX" --dir "$EV_GDIRX" --provider grok) >/dev/null 2>&1 || true
awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v n="$C_NOTE" '$t=="ev-noresult" && $e=="reply-refused" && $n ~ /no reply text/' "$EV_LOG" | grep -q . \
  && ok "a reply the extractor could not read is recorded as a refusal, with the reason" || fail "extraction failure left no reply-refused"
[ "$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-noresult" && $e=="reply-refused"' "$EV_LOG" | grep -c .)" = "1" ] \
  && ok "the refusal is recorded once, though the path crosses two boundaries" || fail "refusal double-logged"

EV_GMSG2="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-31-00_ev-grok2.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-2/; s/thread: ev-loop/thread: ev-grok-ok/' "$EV_REQ" > "$EV_GMSG2"
EV_GDIR2="$WORK/ev-grok-leg2"; mkdir -p "$EV_GDIR2"
(cd "$EV" && env PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   "$RUNPHASE" run --message "$EV_GMSG2" --dir "$EV_GDIR2" --provider grok) >/dev/null 2>&1 || true
EV_GSEQ="$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-grok-ok" && ($e=="reply-validated" || $e=="reply-accepted"){printf "%s ", $e}' "$EV_LOG")"
[ "$EV_GSEQ" = "reply-validated reply-accepted " ] \
  && ok "a brokered reply is recorded as validated, then accepted" || fail "broker success sequence (got: $EV_GSEQ)"
[ "$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v st="$C_ST" '$t=="ev-grok-ok" && $e=="turn-finished"{print $st}' "$EV_LOG")" = "completed" ] \
  && ok "a turn whose acceptance IS in the log signs off completed" || fail "turn-finished status on a clean brokered turn"

# A turn whose own acceptance never reached the log must not sign off as `completed`:
# absence means unknown, but a terminal row claiming a clean turn over a missing milestone
# is a positive contradiction. (codex, plan r2, blocking.)
EV_GMSG4="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-33-00_ev-grok4.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-4/; s/thread: ev-loop/thread: ev-logloss/' "$EV_REQ" > "$EV_GMSG4"
EV_GDIR4="$WORK/ev-grok-leg4"; mkdir -p "$EV_GDIR4"
chmod a-w "$EV_LOG"
(cd "$EV" && env PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   "$RUNPHASE" run --message "$EV_GMSG4" --dir "$EV_GDIR4" --provider grok) >/dev/null 2>&1 || true
chmod u+w "$EV_LOG"
grep -q 'coordinator log not updated' "$EV_GDIR4/runner.log" \
  && ok "a lost advisory append is reported in the run dir" || fail "advisory append failure not reported"
# THE POINT of the fixture: an unwritable log must not cost a delivered reply. Asserting
# that SOME file exists in the inbox proved nothing — an earlier test had already put one
# there. Bind it to THIS turn. (grok, implement r1.)
EV_LOSTREPLY="$(grep -l '^in-reply-to: ev-grok-4$' "$EV/.comms/to-claude/"*.md 2>/dev/null | head -1)"
[ -n "$EV_LOSTREPLY" ] && ok "the reply for THIS turn reached the inbox with the log unwritable" || fail "an unwritable log cost a delivered reply"

# `turn-finished log-incomplete`: an event this turn produced never reached the log, so the
# terminal row must not claim a clean run. Deterministic because the runner reaches its log
# through $COMMS in ITS OWN helper directory — a fixture copy of runphase.sh beside a
# forwarding comms.sh that drops exactly one kind. Not a shipped knob; nothing in the
# product can silently drop an event. (grok, implement r1 — the seam it asked for.)
EV_SHIM="$WORK/ev-shim"; mkdir -p "$EV_SHIM"
cp "$RUNPHASE" "$EV_SHIM/runphase.sh"; chmod +x "$EV_SHIM/runphase.sh"
cat > "$EV_SHIM/comms.sh" <<SHIM
#!/bin/bash
if [ "\$1" = events ] && [ "\$2" = append ]; then
  case " \$* " in *" --kind reply-validated "*) exit 1 ;; esac
fi
exec "$COMMS" "\$@"
SHIM
chmod +x "$EV_SHIM/comms.sh"
EV_GMSG5="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-35-00_ev-grok5.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-5/; s/thread: ev-loop/thread: ev-logloss2/' "$EV_REQ" > "$EV_GMSG5"
EV_GDIR5="$WORK/ev-grok-leg5"; mkdir -p "$EV_GDIR5"
(cd "$EV" && env PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   "$EV_SHIM/runphase.sh" run --message "$EV_GMSG5" --dir "$EV_GDIR5" --provider grok) >/dev/null 2>&1 || true
[ "$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v st="$C_ST" '$t=="ev-logloss2" && $e=="turn-finished"{print $st}' "$EV_LOG")" = "log-incomplete" ] \
  && ok "a turn that lost one of its own events signs off log-incomplete, not completed" || fail "turn-finished did not report the hole"
awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-logloss2" && $e=="reply-accepted"' "$EV_LOG" | grep -q . \
  && ok "the reply still landed while its trace was incomplete" || fail "a lost event cost the reply"

# THE LOOKUP ITSELF. The earlier shim drops `reply-validated`, which sets LOG_INCOMPLETE
# in-process — so it never exercised the acceptance lookup at all. This one lets `send`
# record the acceptance and then removes that row, which is what a lost advisory append
# looks like to the check that runs next; it also plants a DIFFERENT turn's acceptance on
# the same thread, so a thread-only join would call this turn clean. (codex + grok, r2.)
EV_SHIM3="$WORK/ev-shim3"; mkdir -p "$EV_SHIM3"
cp "$RUNPHASE" "$EV_SHIM3/runphase.sh"; chmod +x "$EV_SHIM3/runphase.sh"
cat > "$EV_SHIM3/comms.sh" <<SHIM
#!/bin/bash
if [ "\$1" = send ]; then
  "$COMMS" "\$@"; rc=\$?
  T="\$(mktemp)"
  grep -v 'reply-accepted' "$EV_LOG" > "\$T" 2>/dev/null && cat "\$T" > "$EV_LOG"
  rm -f "\$T"
  "$COMMS" events append --kind reply-accepted --thread ev-lostaccept \
    --request-id ev-grok-6 --message-id an-earlier-execution --status APPROVE >/dev/null 2>&1
  exit \$rc
fi
exec "$COMMS" "\$@"
SHIM
chmod +x "$EV_SHIM3/comms.sh"
EV_GMSG6="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-36-00_ev-grok6.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-6/; s/thread: ev-loop/thread: ev-lostaccept/' "$EV_REQ" > "$EV_GMSG6"
EV_GDIR6="$WORK/ev-grok-leg6"; mkdir -p "$EV_GDIR6"
(cd "$EV" && env PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   "$EV_SHIM3/runphase.sh" run --message "$EV_GMSG6" --dir "$EV_GDIR6" --provider grok) >/dev/null 2>&1 || true
# The planted row shares the thread, the REQUEST id and the attempt — it differs only in
# which execution wrote it. Request-plus-attempt was not unique: a re-send runs the same
# request twice. Only the reply id names one execution. (codex, implement r3, blocking.)
awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v rq="$C_REQ" -v m="$C_MID" '$t=="ev-lostaccept" && $e=="reply-accepted" && $rq=="ev-grok-6" && $m=="an-earlier-execution"' "$EV_LOG" | grep -q . \
  && ok "the fixture planted an earlier EXECUTION of the same request and attempt" || fail "the collision fixture planted nothing"
[ "$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v st="$C_ST" '$t=="ev-lostaccept" && $e=="turn-finished"{print $st}' "$EV_LOG")" = "log-incomplete" ] \
  && ok "a lost acceptance is detected even when an earlier execution of the SAME request accepted" || fail "the acceptance lookup adopted another execution's row"

# A row truncated mid-write still carries fields 3 and 12, which a raw TSV match accepted
# while the reader rejected the very same row — two rules for one question. The lookup goes
# through the reader now. (codex, implement r4, blocking.)
EV_SHIM4="$WORK/ev-shim4"; mkdir -p "$EV_SHIM4"
cp "$RUNPHASE" "$EV_SHIM4/runphase.sh"; chmod +x "$EV_SHIM4/runphase.sh"
cat > "$EV_SHIM4/comms.sh" <<SHIM
#!/bin/bash
if [ "\$1" = send ]; then
  "$COMMS" "\$@"; rc=\$?
  T="\$(mktemp)"
  awk -F'\t' 'BEGIN{OFS="\t"} \$3=="reply-accepted" { NF=12; print; next } { print }' "$EV_LOG" > "\$T" 2>/dev/null \
    && cat "\$T" > "$EV_LOG"
  rm -f "\$T"
  exit \$rc
fi
exec "$COMMS" "\$@"
SHIM
chmod +x "$EV_SHIM4/comms.sh"
EV_GMSG7="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-37-00_ev-grok7.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-7/; s/thread: ev-loop/thread: ev-partialrow/' "$EV_REQ" > "$EV_GMSG7"
EV_GDIR7="$WORK/ev-grok-leg7"; mkdir -p "$EV_GDIR7"
(cd "$EV" && env PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   "$EV_SHIM4/runphase.sh" run --message "$EV_GMSG7" --dir "$EV_GDIR7" --provider grok) >/dev/null 2>&1 || true
[ "$(awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v st="$C_ST" '$t=="ev-partialrow" && $e=="turn-finished"{print $st}' "$EV_LOG")" = "log-incomplete" ] \
  && ok "a truncated acceptance row does not satisfy the lookup" || fail "a partial row passed as an acceptance"

# A failed compose leaves the leading bytes behind, which is nonempty and truncated — and
# publishing that hands `await` a completion signal over a corrupt result, so it never
# synthesizes the sound one. Publication is gated on the compose, not on the file having
# bytes. (codex, implement r6, blocking.)
EV_GMSG8="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-38-00_ev-grok8.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-8/; s/thread: ev-loop/thread: ev-partialresult/' "$EV_REQ" > "$EV_GMSG8"
EV_GDIR8="$WORK/ev-grok-leg8"; mkdir -p "$EV_GDIR8"
printf '{\n  "provider": "grok",\n  "status": "completed",\n  "TRUNC' > "$EV_GDIR8/result.json.tmp"
chmod a-w "$EV_GDIR8/result.json.tmp"
(cd "$EV" && env PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   "$RUNPHASE" run --message "$EV_GMSG8" --dir "$EV_GDIR8" --provider grok) >/dev/null 2>&1 || true
chmod u+w "$EV_GDIR8/result.json.tmp" 2>/dev/null || true
[ ! -f "$EV_GDIR8/result.json" ] \
  && ok "a result that could not be composed is never published" || fail "a truncated result.json was published"
grep -q 'TRUNC' "$EV_GDIR8/result.json" 2>/dev/null \
  && fail "await would read a truncated completion signal" || ok "no truncated completion signal is left for await"

EV_GMSG3="$EV/.comms/to-grok/$(basename "$EV")_2026-08-29T09-32-00_ev-grok3.md"
sed 's/message_id: ev-req-1/message_id: ev-grok-3/; s/thread: ev-loop/thread: ev-shadow/' "$EV_REQ" > "$EV_GMSG3"
EV_GDIR3="$WORK/ev-grok-leg3"; mkdir -p "$EV_GDIR3"
(cd "$EV" && env PATH="$STUB_BIN:$PATH" COMMS_RUNPHASE_SPAWN_DELAY_SECS=0 \
   "$RUNPHASE" run --message "$EV_GMSG3" --dir "$EV_GDIR3" --provider grok --no-deliver) >/dev/null 2>&1 || true
awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v r="$C_ROLE" '$t=="ev-shadow" && $e=="reply-validated" && $r=="shadow"' "$EV_LOG" | grep -q . \
  && ok "a measurement turn is recorded as shadow, never as the gating leg" || fail "shadow role not recorded"
awk -F'\t' -v t="$C_TH" -v e="$C_EV" -v r="$C_ROLE" '$t=="ev-shadow" && $e=="turn-started" && $r=="shadow"' "$EV_LOG" | grep -q . \
  && ok "every event of a shadow turn carries the shadow role, not just the reply" || fail "shadow role on turn-started"
awk -F'\t' -v t="$C_TH" -v e="$C_EV" '$t=="ev-shadow" && $e=="reply-accepted"' "$EV_LOG" | grep -q . \
  && fail "a shadow turn recorded an acceptance it never delivered" || ok "a shadow turn accepts nothing"

EV_AID="$(run_ev snapshot create 2>/dev/null | head -1)"
git -C "$EV" ls-tree -r --name-only "$EV_AID" 2>/dev/null | grep -q '^\.comms/' \
  && fail "the coordinator log rides into the reviewed artifact" \
  || ok "the reviewed artifact never carries the coordinator log"

section "review identities: await synthesizes a result for a runner that died before turn.tsv"
# The pid file is written at spawn; turn.tsv only once cmd_run has read the inbound. A runner
# killed in between leaves a run dir with NO identity, and `await` is then the one process left
# to record the failure. Every identity global the result writer and the terminal event read
# must already be defined, or `set -u` kills that process too and the leg is a permanent
# unknown. When turn.tsv DOES exist for a review identity, the synthesized event must carry its
# NAME (claude-review), never the provider it ran on (claude): the leg fingerprint and
# `--degrade` find a killed leg by identity. (plan §4, load_turn_identity.)
# Its own repo: the no-identity row is attributed to the codex default with an empty thread,
# which would skew the shared fixture's per-agent counts.
EVRI="$WORK/events-review-ident"; mkdir -p "$EVRI"; EVRI="$(cd "$EVRI" && pwd -P)"
git -C "$EVRI" init -q -b main
git -C "$EVRI" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$EVRI/.comms"
printf 'agents = claude codex grok\nreview-agents = claude-review:claude\ndefault-target = codex\n' > "$EVRI/.comms/config"
C_RD=$(EV_COL run_dir)
# A run dir exactly as an early-killed runner leaves it: a pid naming a process that is gone.
# `wait` reaps the child first, so the pid is dead before await ever probes it.
evri_rundir() { # <name> -> path
  local d="$WORK/$1" p
  mkdir -p "$d"
  sh -c 'exit 0' & p=$!
  wait "$p" 2>/dev/null || true
  printf '%s\n' "$p" > "$d/pid"
  printf '%s' "$d"
}
# stdout/stderr kept BESIDE the run dir, so nothing the test writes can look like runner output.
evri_await() { # <run-dir>
  (cd "$EVRI" && env PATH="$STUB_BIN:$PATH" "$RUNPHASE" await "$1" --timeout-secs 30 >"$1.out" 2>"$1.err") || true
}
evri_field() { sed -n 's/.*"'"$2"'": "\([^"]*\)".*/\1/p' "$1/result.json" 2>/dev/null | head -1; }
run_evri() { (cd "$EVRI" && env "$COMMS" "$@"); }

# 1. No turn.tsv at all.
EVRI_D1="$(evri_rundir evri-noturn)"
evri_await "$EVRI_D1"
# 2. A LEGACY turn.tsv, from before identities: provider only. The provider then WAS the
#    identity, so the agent falls back to it — not to the codex default.
EVRI_D2="$(evri_rundir evri-legacy)"
printf 'thread\tevri-legacy\nprovider\tgrok\n' > "$EVRI_D2/turn.tsv"
evri_await "$EVRI_D2"
# 3. A review identity's turn.tsv, exactly as cmd_run writes it.
EVRI_LEG="evri-loop-claude-review"
EVRI_D3="$(evri_rundir evri-review)"
printf 'thread\t%s\nset\tevri-set\ndispatch\tevri-d1\nround\t1\nrequest\tevri-req-1\nartifact\t\nprovider\tclaude\nagent\tclaude-review\n' \
  "$EVRI_LEG" > "$EVRI_D3/turn.tsv"
evri_await "$EVRI_D3"

[ "$(evri_field "$EVRI_D1" status)" = failed ] && grep -q 'synthesized by await' "$EVRI_D1/result.json" \
  && ok "a runner that died before writing turn.tsv still gets a synthesized failed result" \
  || fail "no synthesized result without turn.tsv (got: $(tr '\n' ' ' < "$EVRI_D1/result.json" 2>/dev/null; cat "$EVRI_D1.err" 2>/dev/null))"
# The positive half proves each stderr is the awaiting process's, captured past write_result —
# an empty file would pass the negative half vacuously.
EVRI_N=0; for d in "$EVRI_D1" "$EVRI_D2" "$EVRI_D3"; do
  grep -q 'recorded a synthetic failed result' "$d.err" 2>/dev/null && EVRI_N=$((EVRI_N+1)); done
[ "$EVRI_N" = 3 ] \
  && ! cat "$EVRI_D1.err" "$EVRI_D2.err" "$EVRI_D3.err" "$EVRI_D1/runner.log" "$EVRI_D2/runner.log" "$EVRI_D3/runner.log" 2>/dev/null | grep -q 'unbound variable' \
  && ok "no synthesis trips an unbound variable, with or without an identity on disk" \
  || fail "synthesis stderr ($EVRI_N/3 reached the end): $(cat "$EVRI_D1.err" "$EVRI_D2.err" "$EVRI_D3.err" 2>/dev/null | grep -m2 -i 'unbound\|error')"
EVRI_P1="$(evri_field "$EVRI_D1" provider)"; EVRI_A1="$(evri_field "$EVRI_D1" agent)"
[ -n "$EVRI_P1" ] && [ -n "$EVRI_A1" ] && [ "$EVRI_A1" = "$EVRI_P1" ] \
  && ok "with no identity recorded, the result still names a provider and an agent, and they agree" \
  || fail "no-identity result fields (provider='$EVRI_P1' agent='$EVRI_A1')"
# Through the READER, which refuses malformed rows: a row the log holds but no consumer can
# read is not a terminal event.
run_evri events --kind turn-finished --all 2>/dev/null \
  | awk -F'\t' -v rd="$C_RD" -v st="$C_ST" -v d="$EVRI_D1" 'NR>1 && $rd==d && $st=="failed"' | grep -q . \
  && ok "the terminal event reaches the log even with no identity to stamp it" \
  || fail "no readable turn-finished row for the identity-less run dir"
[ "$(evri_field "$EVRI_D2" provider)" = grok ] && [ "$(evri_field "$EVRI_D2" agent)" = grok ] \
  && ok "a provider-only turn.tsv is attributed to that provider, not to a default" \
  || fail "legacy turn.tsv (provider='$(evri_field "$EVRI_D2" provider)' agent='$(evri_field "$EVRI_D2" agent)')"
[ "$(evri_field "$EVRI_D3" provider)" = claude ] && [ "$(evri_field "$EVRI_D3" agent)" = claude-review ] \
  && ok "a killed review-identity turn's result names the identity and the provider it ran on" \
  || fail "review-identity result (provider='$(evri_field "$EVRI_D3" provider)' agent='$(evri_field "$EVRI_D3" agent)')"
EVRI_BYID="$(run_evri events --thread "$EVRI_LEG" --kind turn-finished --agent claude-review 2>/dev/null | tail -n +2)"
[ "$(printf '%s\n' "$EVRI_BYID" | grep -c .)" = 1 ] && [ "$(printf '%s' "$EVRI_BYID" | cut -f"$C_ST")" = failed ] \
  && ok "the synthesized terminal event carries the review identity" \
  || fail "no failed turn-finished for agent claude-review (got: $EVRI_BYID)"
# The exact-match control: the leg has exactly one terminal row, and the provider's name finds
# none of it — so the row above was matched by identity, not by a filter that also admits
# `claude` (a prefix of `claude-review`).
[ "$(run_evri events --thread "$EVRI_LEG" --kind turn-finished 2>/dev/null | tail -n +2 | grep -c .)" = 1 ] \
  && [ "$(run_evri events --thread "$EVRI_LEG" --kind turn-finished --agent claude 2>/dev/null | tail -n +2 | grep -c .)" = 0 ] \
  && ok "the leg's terminal event is never recorded under the provider's name" \
  || fail "the synthesized event was attributed to the provider claude (or the leg has no single terminal row)"
