#!/usr/bin/env python3
"""Bounded scheduling; only a complete, validated set of workers reaches run.sh's gate."""
import argparse
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import sys
import time


def manifest(text):
    rows = []
    for line in text.splitlines():
        fields = line.split('\t')
        if (len(fields) != 2 or not re.fullmatch(r'[a-z][a-z0-9-]*', fields[0])
                or fields[1] not in ('serial', 'parallel')):
            raise ValueError('invalid group manifest row: ' + line)
        rows.append(tuple(fields))
    if not rows or len({name for name, _ in rows}) != len(rows):
        raise ValueError('empty manifest or duplicate group')
    # The signal tests must never overlap another worker, even after a manifest edit.
    if ('presence', 'serial') not in rows:
        raise ValueError('presence must be an exclusive serial group')
    return rows


def merge_reports(directory, names):
    """Reject missing/truncated workers and cross-worker skip/section duplicates."""
    totals = [0, 0, 0]
    sections = {}
    skips = set()
    for name in names:
        fields = (directory / (name + '.done')).read_text().splitlines()
        if len(fields) != 3:
            raise ValueError(name + ': incomplete worker result')
        counts = fields[0].split('\t')
        if len(counts) != 3 or any(not re.fullmatch(r'[0-9]{1,6}', n) for n in counts):
            raise ValueError(name + ': invalid worker counters')
        p, f, s = map(int, counts)
        if fields[1] != name or fields[2] != 'complete':
            raise ValueError(name + ': worker identity or completion marker mismatch')
        observed = 0
        for line in (directory / (name + '.sections')).read_text().splitlines():
            banner, number = line.split('\t')
            if not banner or banner in sections or not re.fullmatch(r'[0-9]{1,6}', number):
                raise ValueError(name + ': duplicate section or invalid section count')
            sections[banner] = int(number)
            observed += int(number)
        if observed == 0 or observed != p + f + s:
            raise ValueError(name + ': section totals disagree with worker counters')
        used = (directory / (name + '.skips')).read_text().split()
        if len(used) != s or len(set(used)) != s or skips.intersection(used):
            raise ValueError(name + ': duplicate skip or skip count mismatch')
        skips.update(used)
        totals = [a + b for a, b in zip(totals, (p, f, s))]
    return totals, sections


def reset_signals():
    # Bash cannot restore INT if it was ignored when Bash started. Background launchers
    # can pass SIG_IGN through Python; normalize before starting the supervisor.
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGQUIT):
        signal.signal(sig, signal.SIG_DFL)


def stop_workers(active, sig):
    # The existing supervisor owns descendant teardown and preserves signal identity.
    for proc, *_ in active.values():
        if proc.poll() is None:
            proc.send_signal(sig)
    deadline = time.monotonic() + 15
    for proc, *_ in active.values():
        try:
            proc.wait(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()


def run_workers(repo, oid, directory, rows, jobs):
    active = {}
    failed = False
    timings = []
    # Exclusive groups go first. No parallel worker starts before they finish.
    phases = [([name for name, mode in rows if mode == 'serial'], 1),
              ([name for name, mode in rows if mode == 'parallel'], jobs)]
    try:
        for pending, limit in phases:
            while pending or active:
                while pending and len(active) < limit:
                    name = pending.pop(0)
                    log = (directory / (name + '.log')).open('wb')
                    env = os.environ.copy()
                    for key in ('BASH_ENV', 'ENV', 'SHELLOPTS', 'BASHOPTS', 'BASH_XTRACEFD'):
                        env.pop(key, None)
                    command = [str(repo / 'helpers/comms.sh'), 'presence', 'with-beat',
                               '--no-heartbeat', '--name', 'suite-' + name,
                               '--instance', '00000000000000000000000000000001', '--',
                               'bash', str(repo / 'tests/worker.sh'), name, oid, str(directory)]
                    proc = subprocess.Popen(command, cwd=repo, env=env, stdin=subprocess.DEVNULL,
                                            stdout=log, stderr=subprocess.STDOUT,
                                            start_new_session=True, preexec_fn=reset_signals)
                    active[name] = (proc, log, time.monotonic())
                    print('START ' + name, flush=True)
                for name, (proc, log, started) in list(active.items()):
                    elapsed = time.monotonic() - started
                    if elapsed > 1800 and proc.poll() is None:
                        raise RuntimeError(name + ': exceeded 30 minute worker budget')
                    if proc.poll() is None:
                        continue
                    log.close()
                    del active[name]
                    failed |= proc.returncode != 0
                    timings.append((name, elapsed, proc.returncode))
                    print(f'END {name}: {elapsed:.1f}s, exit {proc.returncode}', flush=True)
                    # Group output is contiguous and deterministic within each group.
                    print((directory / (name + '.log')).read_text(errors='replace'), end='', flush=True)
                if active:
                    time.sleep(0.1)
    except BaseException:
        stop_workers(active, signal.SIGTERM)
        raise
    finally:
        for _, log, _ in active.values():
            log.close()
    (directory / 'timings.tsv').write_text(''.join(f'{n}\t{s:.3f}\t{rc}\n' for n, s, rc in timings))
    return not failed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repo', type=Path)
    parser.add_argument('oid')
    parser.add_argument('results', type=Path)
    parser.add_argument('--jobs', type=int, default=min(4, os.cpu_count() or 1))
    parser.add_argument('--group', action='append', help='focused run; never a complete suite verdict')
    parser.add_argument('--list', action='store_true')
    args = parser.parse_args()
    if not 1 <= args.jobs <= 16:
        parser.error('--jobs must be between 1 and 16')
    # Enumeration and contracts are bound to the SAME commit captured by run.sh.
    raw = subprocess.check_output(['git', '-C', str(args.repo), 'show',
                                   args.oid + ':tests/groups.tsv'], text=True)
    rows = manifest(raw)
    if args.list:
        print(raw, end='')
        (args.results / 'focused').touch()
        return 0
    if args.group:
        if len(set(args.group)) != len(args.group) or set(args.group) - {n for n, _ in rows}:
            parser.error('unknown or duplicate --group')
        rows = [(n, m) for n, m in rows if n in args.group]
    started = time.monotonic()
    good = run_workers(args.repo, args.oid, args.results, rows, args.jobs)
    totals, sections = merge_reports(args.results, [n for n, _ in rows])
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    print(f'TIMING wall={time.monotonic()-started:.2f}s user={usage.ru_utime:.2f}s system={usage.ru_stime:.2f}s', flush=True)
    if args.group:
        print(f'FOCUSED: passed={totals[0]} failed={totals[1]} skipped={totals[2]}; no full-suite verdict', flush=True)
        (args.results / 'focused').touch()
    elif good:
        (args.results / 'counts').write_text('\t'.join(map(str, totals)) + '\n')
        (args.results / 'sections').write_text(''.join(f'{k}\t{v}\n' for k,v in sections.items()))
    return 0 if good else 1


if __name__ == '__main__':
    def interrupted(signum, _frame):
        raise KeyboardInterrupt(signum)
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main())
    except KeyboardInterrupt as exc:
        print('SUITE: interrupted; no verdict', file=sys.stderr)
        sys.exit(128 + (exc.args[0] if exc.args else signal.SIGINT))
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print('SUITE: ' + str(exc), file=sys.stderr)
        sys.exit(1)
