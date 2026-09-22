#!/usr/bin/env python3
"""Write every composite action's `run:` bodies out as standalone shell scripts.

`shellcheck` cannot read a `run:` block out of YAML, so CI extracts them first
and lints the result. AGENTS.md requires inputs to reach a script only through
step-level `env:`, so an extracted body is valid shell on its own.
"""
import pathlib
import re
import sys

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def slug(text):
    return re.sub(r'[^a-z0-9]+', '-', text.lower()).strip('-') or 'step'


def main():
    if len(sys.argv) != 2:
        sys.exit('usage: extract-steps.py <output directory>')
    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    written = 0
    for action_yml in sorted(REPO_ROOT.glob('actions/*/action.yml')):
        action = yaml.safe_load(action_yml.read_text(encoding='utf-8'))
        for index, step in enumerate(action.get('runs', {}).get('steps', [])):
            script = step.get('run')
            if script is None:
                continue
            if step.get('shell') not in ('bash', 'sh'):
                continue
            name = f'{action_yml.parent.name}-{index:02d}-{slug(step.get("name", ""))}.sh'
            (out / name).write_text('#!/usr/bin/env bash\n' + script, encoding='utf-8')
            written += 1
    if written == 0:
        sys.exit('::error::No run: bodies were extracted; an empty lint is never a pass.')
    print(f'Extracted {written} step script(s) into {out}')


if __name__ == '__main__':
    main()
