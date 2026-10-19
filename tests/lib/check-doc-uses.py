#!/usr/bin/env python3
"""Check every documented call of this repo's workflows and actions against the code.

Reads the complete example workflows under docs/examples/ and every fenced
```yaml block in the Markdown docs, finds each `uses:` of
rnw-community/mobile-ci/<workflow or action>@<any ref>, resolves it to the file
at this commit, and fails on any `with:` key the workflow or action does not
declare, and any `secrets:` key a workflow does not declare. The complete
examples, and the "### Minimal" / "### Full" blocks every docs/workflows/<name>.md
must carry for its workflow, are held to more: every required input and secret
is passed, every self-reference is pinned `@vX.Y.Z # vX.Y.Z`, and every calling
job grants each scope any job of the called workflow requests. GitHub refuses
to start a run whose called job asks for more than its caller granted, even
when that job is skipped, and a reusable workflow can only narrow its caller's
token, so a missing grant is a run that never starts or a publish that fails.

usage: check-doc-uses.py <repo root> [<file>...]
With no files, checks the repository's docs/examples/**/*.yml and Markdown docs.
"""
import pathlib
import re
import sys

import yaml

SELF_REF = re.compile(r'^rnw-community/mobile-ci/(?P<path>[A-Za-z0-9_./-]+)@(?P<ref>\S+)$')
PINNED_LINE = re.compile(r'uses:\s*rnw-community/mobile-ci/\S+@(v\d+\.\d+\.\d+) # (v\d+\.\d+\.\d+)\s*$')
FENCE_OPEN = re.compile(r'^(?P<indent>\s*)```(?:yaml|yml)\s*$')
FENCE_CLOSE = re.compile(r'^\s*```\s*$')

LEVEL = {'none': 0, 'read': 1, 'write': 2}

ROOT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path('.').resolve()
problems = []
interfaces = {}


def interface(path):
    """Declared inputs, required inputs, secrets and required secrets of a self-reference target."""
    if path in interfaces:
        return interfaces[path]
    result = None
    if path.startswith('.github/workflows/') and path.endswith('.yml'):
        file = ROOT / path
        if file.is_file():
            doc = yaml.safe_load(file.read_text(encoding='utf-8'))
            on = doc.get('on', doc.get(True)) or {}
            call = on.get('workflow_call') if isinstance(on, dict) else None
            if call is not None:
                call = call or {}
                inputs = call.get('inputs') or {}
                secrets = call.get('secrets') or {}
                requested = {}
                for grants in [doc.get('permissions')] + [(job or {}).get('permissions') for job in (doc.get('jobs') or {}).values()]:
                    for scope, level in (grants if isinstance(grants, dict) else {}).items():
                        if LEVEL.get(level, 0) > LEVEL.get(requested.get(scope, 'none'), 0):
                            requested[scope] = level
                result = {
                    'kind': 'workflow',
                    'permissions': requested,
                    'inputs': set(inputs),
                    'required': {k for k, v in inputs.items() if (v or {}).get('required') and 'default' not in (v or {})},
                    'secrets': set(secrets),
                    'required-secrets': {k for k, v in secrets.items() if (v or {}).get('required')},
                }
    elif path.startswith('actions/'):
        file = ROOT / path / 'action.yml'
        if file.is_file():
            doc = yaml.safe_load(file.read_text(encoding='utf-8'))
            inputs = doc.get('inputs') or {}
            result = {
                'kind': 'action',
                'inputs': set(inputs),
                'required': {k for k, v in inputs.items() if (v or {}).get('required') and 'default' not in (v or {})},
            }
    interfaces[path] = result
    return result


def check_call(where, node, strict):
    match = SELF_REF.match(str(node.get('uses', '')).strip())
    if not match:
        return
    path = match.group('path')
    spec = interface(path)
    if spec is None:
        problems.append(f'{where}: uses {path}, which is not a workflow_call workflow or action at this commit')
        return
    given = node.get('with') or {}
    if not isinstance(given, dict):
        problems.append(f'{where}: {path} has a with: that is not a mapping')
        return
    for key in sorted(set(given) - spec['inputs']):
        problems.append(f"{where}: {path} has no input '{key}'")
    if strict:
        for key in sorted(spec['required'] - set(given)):
            problems.append(f"{where}: {path} requires input '{key}'")
    if spec['kind'] == 'workflow':
        secrets = node.get('secrets')
        if isinstance(secrets, dict):
            for key in sorted(set(secrets) - spec['secrets']):
                problems.append(f"{where}: {path} declares no secret '{key}'")
            if strict:
                for key in sorted(spec['required-secrets'] - set(secrets)):
                    problems.append(f"{where}: {path} requires secret '{key}'")
        elif secrets is None:
            if strict:
                for key in sorted(spec['required-secrets']):
                    problems.append(f"{where}: {path} requires secret '{key}'")
        elif secrets != 'inherit':
            problems.append(f'{where}: {path} has a secrets: that is neither a mapping nor inherit')


def walk(where, node, strict):
    if isinstance(node, dict):
        if 'uses' in node:
            check_call(where, node, strict)
        for value in node.values():
            walk(where, value, strict)
    elif isinstance(node, list):
        for value in node:
            walk(where, value, strict)


def effective_permissions(workflow, job):
    granted = job.get('permissions', workflow.get('permissions'))
    if granted is None:
        return None
    if granted in ('read-all', 'write-all'):
        level = granted.split('-')[0]
        return {scope: level for scope in ('contents', 'packages', 'actions', 'pull-requests')}
    return granted if isinstance(granted, dict) else {}


def display(file):
    try:
        return file.relative_to(ROOT)
    except ValueError:
        return file


def check_complete(where, text, workflow):
    """A whole caller: every required input and secret, pinned, with its grants."""
    walk(where, workflow, strict=True)
    for number, line in enumerate(text.splitlines(), 1):
        if 'rnw-community/mobile-ci/' not in line or 'uses:' not in line:
            continue
        pinned = PINNED_LINE.search(line)
        if not pinned or pinned.group(1) != pinned.group(2):
            problems.append(f'{where}+{number}: self-reference not pinned as @vX.Y.Z # vX.Y.Z')
    jobs = workflow.get('jobs') if isinstance(workflow, dict) else None
    for job_id, job in (jobs or {}).items():
        match = SELF_REF.match(str((job or {}).get('uses', '')).strip())
        if not match:
            continue
        name = match.group('path').rsplit('/', 1)[-1]
        spec = interface(match.group('path'))
        needed = (spec or {}).get('permissions')
        if not needed:
            continue
        granted = effective_permissions(workflow, job)
        if granted is None:
            problems.append(f'{where}: job {job_id} calls {name} without a permissions: block')
            continue
        for scope, level in needed.items():
            if LEVEL.get(str(granted.get(scope, 'none')), 0) < LEVEL[level]:
                problems.append(f'{where}: job {job_id} calls {name} without {scope}: {level}')


def check_example(file):
    rel = display(file)
    text = file.read_text(encoding='utf-8')
    try:
        workflow = yaml.safe_load(text)
    except yaml.YAMLError as error:
        problems.append(f'{rel}: not valid YAML: {error}')
        return
    if not isinstance(workflow, dict) or not isinstance(workflow.get('jobs'), dict):
        problems.append(f'{rel}: not a workflow with jobs')
        return
    check_complete(str(rel), text, workflow)


def yaml_blocks(text):
    """Yield (line, heading in effect, block body) for every fenced yaml block."""
    lines = text.splitlines()
    index = 0
    heading = ''
    while index < len(lines):
        if lines[index].startswith('#'):
            heading = lines[index].strip()
        opened = FENCE_OPEN.match(lines[index])
        if not opened:
            index += 1
            continue
        start = index + 1
        indent = len(opened.group('indent'))
        body = []
        index += 1
        while index < len(lines) and not FENCE_CLOSE.match(lines[index]):
            body.append(lines[index][indent:] if lines[index][:indent].strip() == '' else lines[index])
            index += 1
        yield start, heading, '\n'.join(body)
        index += 1


EXAMPLE_HEADINGS = ('### Minimal', '### Full')


def check_markdown(file):
    rel = display(file)
    is_workflow_doc = file.parent.name == 'workflows' and file.parent.parent.name == 'docs'
    workflow_ref = f'rnw-community/mobile-ci/.github/workflows/{file.stem}.yml@'
    found = set()
    for line, heading, block in yaml_blocks(file.read_text(encoding='utf-8')):
        if 'rnw-community/mobile-ci/' not in block:
            continue
        try:
            parsed = yaml.safe_load(block)
        except yaml.YAMLError as error:
            first = str(error).splitlines()[0]
            problems.append(f'{rel}:{line}: a yaml block calling this repo does not parse ({first}); it cannot be checked')
            continue
        if is_workflow_doc and heading in EXAMPLE_HEADINGS and workflow_ref in block:
            found.add(heading)
            check_complete(f'{rel}:{line}', block, parsed)
        else:
            walk(f'{rel}:{line}', parsed, strict=False)
    if is_workflow_doc and (ROOT / '.github' / 'workflows' / f'{file.stem}.yml').is_file():
        for heading in EXAMPLE_HEADINGS:
            if heading not in found:
                problems.append(f"{rel}: no '{heading}' yaml block calling {file.stem}.yml")


def default_files():
    files = sorted((ROOT / 'docs' / 'examples').rglob('*.yml'))
    files += [ROOT / 'README.md', ROOT / 'AGENTS.md']
    files += sorted((ROOT / 'docs').glob('*.md'))
    files += sorted((ROOT / 'docs' / 'workflows').glob('*.md'))
    files += sorted((ROOT / 'docs' / 'examples').rglob('*.md'))
    files += sorted((ROOT / 'actions').glob('*/README.md'))
    return [f for f in files if f.is_file()]


def main():
    files = [pathlib.Path(f).resolve() for f in sys.argv[2:]] or default_files()
    examples = 0
    for file in files:
        if file.suffix == '.yml':
            examples += 1
            check_example(file)
        else:
            check_markdown(file)
    if not sys.argv[2:] and examples == 0:
        problems.append('docs/examples/ holds no example workflow; an empty check is never a pass')
    if problems:
        sys.exit('\n'.join(problems))
    print(f'checked {len(files)} file(s), {examples} example workflow(s), {len(interfaces)} distinct self-reference(s)')


main()
