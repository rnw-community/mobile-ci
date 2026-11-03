#!/usr/bin/env python3
"""Fail on any pipe into a grep that can exit before its producer is done.

A `shell: bash` step runs under `bash -eo pipefail`. `producer | grep -q` makes
grep exit at its first match; a producer still writing past the pipe buffer
then dies of SIGPIPE (141), pipefail fails the pipeline, and the hit reads as a
miss, so `! producer | grep -q` passes open. -l, -L and -m stop reading early
the same way. Feed grep a heredoc instead (`grep -q pat <<EOF` / `$var` or
`$(cmd)` / `EOF`), match with `case`, or test for output with
`[ -n "$(cmd)" ]`.

Usage: pipe-early-exit.py [file ...]. Without arguments it scans every
`run:` body in actions/*/action.yml, .github/workflows/*.yml and
docs/examples/*/*.yml, and every *.sh under scripts/ and tests/.
"""
import pathlib
import re
import sys

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PIPED_GREP = re.compile(r'(?<![|>])\|(?![|&])\s*(?:command\s+)?[ef]?grep\s+([^|;&)<>]*)')
EARLY_EXIT = re.compile(r'-[A-Za-z0-9]*[qlLm][A-Za-z0-9]*|--(?:quiet|silent|max-count|files-with(?:out)?-match(?:es)?)(?:=.*)?')


def run_bodies(path):
    document = yaml.safe_load(path.read_text(encoding='utf-8')) or {}
    if 'runs' in document:
        jobs = {'': {'steps': document['runs'].get('steps') or []}}
    else:
        jobs = document.get('jobs') or {}
    for job_id, job in jobs.items():
        for index, step in enumerate(job.get('steps') or []):
            if 'run' in step:
                label = step.get('name') or f'step {index}'
                yield (f'{job_id}: {label}' if job_id else label), step['run']


def violations(script):
    joined = re.sub(r'\\\n|\|[ \t]*\n', lambda m: '| ' if m.group(0)[0] == '|' else ' ', script)
    for line in joined.split('\n'):
        if line.lstrip().startswith('#'):
            continue
        for match in PIPED_GREP.finditer(line):
            if any(EARLY_EXIT.fullmatch(option) for option in grep_options(match.group(1).split())):
                yield line.strip()


def grep_options(words):
    takes_argument = False
    for word in words:
        if takes_argument:
            takes_argument = False
        elif word == '--':
            return
        elif word.startswith('-') and not word.startswith('--'):
            takes_argument = word[-1] in 'ef'
            yield word
        elif word.startswith('--'):
            yield word


def targets(argv):
    if argv:
        return [pathlib.Path(arg) for arg in argv]
    globs = ('actions/*/action.yml', '.github/workflows/*.yml', 'docs/examples/*/*.yml',
             'scripts/**/*.sh', 'tests/**/*.sh')
    return sorted(path for pattern in globs for path in REPO_ROOT.glob(pattern))


def main():
    found = 0
    for path in targets(sys.argv[1:]):
        if path.suffix in ('.yml', '.yaml'):
            scripts = list(run_bodies(path))
        else:
            scripts = [('', path.read_text(encoding='utf-8'))]
        for where, script in scripts:
            for line in violations(script):
                found += 1
                place = f'{path} ({where})' if where else str(path)
                print(f'{place}: {line}')
    if found:
        print(f'::error::{found} pipe(s) into an early-exiting grep (-q/-l/-L/-m). Under pipefail a '
              'producer still writing when grep exits dies of SIGPIPE and the match reads as a miss. '
              'Use grep -q pattern <<EOF with the text or $(command) as the body, a case pattern, '
              'or [ -n "$(command)" ].')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
