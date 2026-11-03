#!/usr/bin/env python3
"""Fail on any pipe into a grep that can exit before its producer is done.

A `shell: bash` step runs under `bash -eo pipefail`. `producer | grep -q` makes
grep exit at its first match; a producer still writing past the pipe buffer
then dies of SIGPIPE (141), pipefail fails the pipeline, and the hit reads as a
miss, so `! producer | grep -q` passes open. -l, -L and -m stop reading early
the same way. Feed grep a heredoc instead (`grep -q pat <<EOF` / `$var` or
`$(cmd)` / `EOF`), match with `case`, or test for output with
`[ -n "$(cmd)" ]`.

It also fails on a heredoc inside `$(...)` with more shell after it on the line
(`if grep -q pat <<EOF; then`). bash 5.2, which Ubuntu 24.04 runners ship,
re-parses the substitution when it runs it and stops at a syntax error, though
`bash -n` and bash 5.3 accept the script (mobile-ci#315). Use a here-string
there: `grep -q pat <<<"$text"`.

Usage: pipe-early-exit.py [file ...]. Without arguments it scans every
`run:` body in actions/*/action.yml, .github/workflows/*.yml and
docs/examples/*/*.yml, and every *.sh under scripts/ and tests/.
"""
import pathlib
import re
import shlex
import sys

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PIPED_GREP = re.compile(r'(?<![|>])\|(?![|&])\s*(?:command\s+)?[ef]?grep\s+([^|;&)<>]*)')
HEREDOC = re.compile(r"""<<-?\s*(['"]?)([A-Za-z_]\w*)\1(.*)""")
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
        for match in PIPED_GREP.finditer(mask_quoted_operators(line)):
            arguments = line[match.start(1):match.end(1)]
            try:
                words = shlex.split(arguments)
            except ValueError:
                words = arguments.split()
            if any(EARLY_EXIT.fullmatch(option) for option in grep_options(words)):
                yield line.strip()


def heredocs_followed_in_substitution(script):
    """Yield each `<<WORD; ...`, `<<WORD && ...` or `<<WORD | ...` line inside a $(...)."""
    stack, lines = [], iter(script.split('\n'))
    for line in lines:
        delimiters, index = [], 0
        while index < len(line):
            char, context = line[index], stack[-1] if stack else None
            if context == "'":
                if char == "'":
                    stack.pop()
            elif char == '\\':
                index += 1
            elif line.startswith('$(', index):
                stack.append('$(')
                index += 1
            elif context == '"':
                if char == '"':
                    stack.pop()
            elif char in '\'"(':
                stack.append(char)
            elif char == ')' and context in ('(', '$('):
                stack.pop()
            elif char == '#' and (index == 0 or line[index - 1] in ' \t;'):
                break
            elif line.startswith('<<<', index):
                index += 2
            elif (heredoc := HEREDOC.match(line, index)) and line.startswith('<<', index):
                delimiters.append(heredoc.group(2))
                if '$(' in stack and re.match(r'\s*(?:;|&&|\|)', heredoc.group(3)):
                    yield line.strip()
                index = heredoc.end(2) + len(heredoc.group(1))
                continue
            index += 1
        for delimiter in delimiters:
            for body in lines:
                if body.strip() == delimiter:
                    break


def mask_quoted_operators(line):
    """Blank out |;&()<> inside quotes, but not inside a quoted $(...)."""
    masked, stack, escaped = [], [], False
    for index, char in enumerate(line):
        context = stack[-1] if stack else None
        if escaped:
            escaped = False
        elif char == '\\' and context != "'":
            escaped = True
        elif context in ("'", '"') and char == context:
            stack.pop()
        elif context == '"' and char == '$' and line[index + 1:index + 2] == '(':
            stack.append('(')
        elif context in ("'", '"'):
            char = '_' if char in '|;&()<>' else char
        elif char in '\'"(':
            stack.append(char)
        elif char == ')' and context == '(':
            stack.pop()
        masked.append(char)
    return ''.join(masked)


def grep_options(words):
    words = iter(words)
    for word in words:
        if word == '--':
            return
        if word.startswith('--'):
            yield word
        elif word.startswith('-'):
            flags = re.match(r'-[^ef]*', word).group(0)
            yield flags
            if flags == word[:-1]:
                next(words, None)


def targets(argv):
    if argv:
        return [pathlib.Path(arg) for arg in argv]
    globs = ('actions/*/action.yml', '.github/workflows/*.yml', 'docs/examples/*/*.yml',
             'scripts/**/*.sh', 'tests/**/*.sh')
    return sorted(path for pattern in globs for path in REPO_ROOT.glob(pattern))


def main():
    found = misparsed = 0
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
            for line in heredocs_followed_in_substitution(script):
                misparsed += 1
                place = f'{path} ({where})' if where else str(path)
                print(f'{place}: {line}')
    if misparsed:
        print(f'::error::{misparsed} heredoc(s) inside $(...) with more shell on the line. bash 5.2 stops at '
              'a syntax error when it runs them, though bash -n and bash 5.3 accept the script. '
              'Use a here-string: grep -q pattern <<<"$text".')
    if found:
        print(f'::error::{found} pipe(s) into an early-exiting grep (-q/-l/-L/-m). Under pipefail a '
              'producer still writing when grep exits dies of SIGPIPE and the match reads as a miss. '
              'Use grep -q pattern <<EOF with the text or $(command) as the body, a case pattern, '
              'or [ -n "$(command)" ].')
    return 1 if found or misparsed else 0


if __name__ == '__main__':
    sys.exit(main())
