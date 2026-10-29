#!/usr/bin/env python3
"""Per-flow Maestro timings: balance a shard from them, or merge new ones in.

balance: reads the discovered flow paths on stdin, one per line, and prints
the ones shard <index> of <count> runs, in discovery order. With a timings
file, flows are packed longest-first onto the least-loaded shard (LPT); a flow
without history weighs the median of the known ones, and ties break by path,
so every shard computes the same assignment from the same inputs. Without a
timings file, or with one that cannot be read, it is the index-modulo split.

merge: folds shard timing records (flow<TAB>seconds<TAB>status lines, as the
run-maestro-* actions write to flow-timings.tsv) into a timings file as an
exponentially weighted average. Only passed flows count: a failed attempt's
duration measures the failure, not the flow.

Timings file: {"version": 1, "flows": {"<flows-dir-relative path>": seconds}}.

The reusable workflows keep one aggregate per platform, {"version": 1,
"targets": {"<target>": {<flows>}}}, in a flow-timings.json artifact: fetch
prints the default branch's newest one, select writes one target's timings
file from it (FLOW_TIMINGS), and record folds a run's shard artifacts into it.
Reading timings never fails a run: no history or an unreadable one only means
the index-modulo split.
"""
import argparse
import io
import json
import math
import os
import re
import statistics
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ALPHA = 0.3
TIMINGS_FILE = 'flow-timings.json'


def warn(message):
    print(f'::warning::{message}', file=sys.stderr)


def load(path):
    with open(path, encoding='utf-8') as handle:
        data = json.load(handle)
    flows = data.get('flows') if isinstance(data, dict) and data.get('version') == 1 else None
    if not isinstance(flows, dict):
        raise ValueError('not a version 1 timings file')
    for name, seconds in flows.items():
        if isinstance(seconds, bool) or not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or seconds < 0:
            raise ValueError(f'flow {name!r} has an invalid duration {seconds!r}')
    return flows


def relative(path, flows_dir):
    prefix = flows_dir.rstrip('/') + '/'
    path = path[len(prefix):] if path.startswith(prefix) else path
    return path[2:] if path.startswith('./') else path


def balance(args):
    if args.count < 1 or not 0 <= args.index < args.count:
        sys.exit(f'::error::shard-index {args.index} is out of range for shard-count {args.count}.')
    paths = [line.rstrip('\r\n') for line in sys.stdin if line.strip()]
    timings = None
    if args.timings:
        try:
            timings = load(args.timings)
        except (OSError, ValueError) as error:
            warn(f"shard-timings-file '{args.timings}' is unreadable ({error}); splitting the flows by index instead.")
    if timings is None:
        chosen = {i for i in range(len(paths)) if i % args.count == args.index}
    else:
        names = [relative(path, args.flows_dir) for path in paths]
        known = [timings[name] for name in names if name in timings]
        default = statistics.median(known) if known else 1.0
        weight = [timings.get(name, default) for name in names]
        loads = [0.0] * args.count
        chosen = set()
        for i in sorted(range(len(paths)), key=lambda i: (-weight[i], names[i])):
            shard = min(range(args.count), key=lambda s: (loads[s], s))
            loads[shard] += weight[i]
            if shard == args.index:
                chosen.add(i)
        print(f'Balanced {len(paths)} flow(s) over {args.count} shard(s) from {len(known)} recorded timing(s); '
              f'estimated shard seconds: {", ".join(str(round(load)) for load in loads)}.', file=sys.stderr)
    for i, path in enumerate(paths):
        if i in chosen:
            print(path)


def fold(flows, record):
    with open(record, encoding='utf-8') as handle:
        for number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            fields = line.rstrip('\r\n').split('\t')
            try:
                name, seconds, status = fields
                seconds = float(seconds)
                if not math.isfinite(seconds) or seconds < 0:
                    raise ValueError
            except ValueError:
                sys.exit(f"::error::{record}:{number} is not a 'flow<TAB>seconds<TAB>status' record: {line.strip()!r}")
            if status != 'passed':
                continue
            previous = flows.get(name)
            flows[name] = round(seconds if previous is None else ALPHA * seconds + (1 - ALPHA) * previous, 1)


def merge(args):
    flows = {}
    if args.previous:
        try:
            flows = load(args.previous)
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as error:
            warn(f"previous timings '{args.previous}' are unreadable ({error}); starting from the new records only.")
    for record in args.records:
        fold(flows, record)
    with open(args.output, 'w', encoding='utf-8') as handle:
        json.dump({'version': 1, 'flows': dict(sorted(flows.items()))}, handle, indent=2)
        handle.write('\n')
    print(f'Wrote {len(flows)} flow timing(s) to {args.output}.')


def targets_of(text):
    """The per-target timings of an aggregate {"version": 1, "targets": {...}} document."""
    data = json.loads(text) if text.strip() else {'version': 1, 'targets': {}}
    targets = data.get('targets') if isinstance(data, dict) and data.get('version') == 1 else None
    if not isinstance(targets, dict):
        raise ValueError('not a version 1 aggregate timings document')
    for name, flows in targets.items():
        if not isinstance(flows, dict):
            raise ValueError(f'target {name!r} has no flow map')
    return targets


def select(args):
    try:
        flows = targets_of(os.environ.get('FLOW_TIMINGS', '')).get(args.target, {})
    except ValueError as error:
        warn(f'the recorded flow timings are unreadable ({error}); target {args.target!r} is split by index.')
        flows = {}
    with open(args.output, 'w', encoding='utf-8') as handle:
        json.dump({'version': 1, 'flows': flows}, handle)
    print(f'Target {args.target!r}: {len(flows)} recorded flow timing(s).')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def fetch(args):
    """Prints the newest unexpired aggregate timings the default branch recorded, or an empty one."""
    api = os.environ.get('GITHUB_API_URL', 'https://api.github.com').rstrip('/')
    headers = {'Authorization': f"Bearer {os.environ.get('GH_TOKEN', '')}", 'Accept': 'application/vnd.github+json'}
    empty = json.dumps({'version': 1, 'targets': {}})
    try:
        query = urllib.parse.urlencode({'name': args.name, 'per_page': 50})
        with urllib.request.urlopen(urllib.request.Request(f'{api}/repos/{args.repository}/actions/artifacts?{query}', headers=headers), timeout=30) as response:
            artifacts = json.load(response).get('artifacts', [])
        artifact = next((a for a in artifacts if not a.get('expired') and (a.get('workflow_run') or {}).get('head_branch') == args.branch), None)
        if artifact is None:
            print(f"No unexpired '{args.name}' artifact from {args.branch} yet; every target is split by index.", file=sys.stderr)
            print(empty)
            return
        opener = urllib.request.build_opener(NoRedirect)
        try:
            response = opener.open(urllib.request.Request(artifact['archive_download_url'], headers=headers), timeout=30)
        except urllib.error.HTTPError as redirect:
            if redirect.code not in (301, 302, 303, 307, 308):
                raise
            response = urllib.request.urlopen(redirect.headers['Location'], timeout=60)
        with response, zipfile.ZipFile(io.BytesIO(response.read())) as archive:
            text = archive.read(TIMINGS_FILE).decode('utf-8')
        targets = targets_of(text)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        warn(f"could not read the recorded flow timings '{args.name}' ({error}); every target is split by index.")
        print(empty)
        return
    print(f"Using '{args.name}' artifact {artifact['id']} from run {(artifact.get('workflow_run') or {}).get('id')}: "
          f'{sum(len(flows) for flows in targets.values())} flow timing(s) over {len(targets)} target(s).', file=sys.stderr)
    print(json.dumps({'version': 1, 'targets': targets}, sort_keys=True))


def record(args):
    """Folds every shard artifact's flow-timings.tsv under records-dir into the aggregate timings."""
    try:
        targets = targets_of(os.environ.get('FLOW_TIMINGS', ''))
    except ValueError as error:
        warn(f'the previous flow timings are unreadable ({error}); starting from this run alone.')
        targets = {}
    shard = re.compile(re.escape(args.artifact_prefix) + r'(.+)-shard-[0-9]+')
    folded = 0
    for entry in sorted(os.listdir(args.records_dir)):
        match = shard.fullmatch(entry)
        tsv = os.path.join(args.records_dir, entry, 'flow-timings.tsv')
        if match and os.path.isfile(tsv):
            fold(targets.setdefault(match.group(1), {}), tsv)
            folded += 1
    if folded == 0:
        sys.exit(f"::error::No '{args.artifact_prefix}<target>-shard-<index>' artifact under '{args.records_dir}' holds a flow-timings.tsv; refusing to publish timings no shard recorded.")
    with open(args.output, 'w', encoding='utf-8') as handle:
        json.dump({'version': 1, 'targets': {name: dict(sorted(flows.items())) for name, flows in sorted(targets.items())}}, handle, indent=2)
        handle.write('\n')
    print(f'Folded {folded} shard record(s) into {sum(len(flows) for flows in targets.values())} flow timing(s) over {len(targets)} target(s).')


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest='command', required=True)
    balancer = commands.add_parser('balance')
    balancer.add_argument('--count', type=int, required=True)
    balancer.add_argument('--index', type=int, required=True)
    balancer.add_argument('--flows-dir', required=True)
    balancer.add_argument('--timings', default='')
    balancer.set_defaults(run=balance)
    merger = commands.add_parser('merge')
    merger.add_argument('--previous', default='')
    merger.add_argument('--output', required=True)
    merger.add_argument('records', nargs='*')
    merger.set_defaults(run=merge)
    selector = commands.add_parser('select')
    selector.add_argument('--target', required=True)
    selector.add_argument('--output', required=True)
    selector.set_defaults(run=select)
    fetcher = commands.add_parser('fetch')
    fetcher.add_argument('--repository', required=True)
    fetcher.add_argument('--name', required=True)
    fetcher.add_argument('--branch', required=True)
    fetcher.set_defaults(run=fetch)
    recorder = commands.add_parser('record')
    recorder.add_argument('--records-dir', required=True)
    recorder.add_argument('--artifact-prefix', required=True)
    recorder.add_argument('--output', required=True)
    recorder.set_defaults(run=record)
    args = parser.parse_args()
    args.run(args)


if __name__ == '__main__':
    main()
