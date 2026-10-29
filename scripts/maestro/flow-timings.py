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
"""
import argparse
import json
import math
import statistics
import sys

ALPHA = 0.3


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
    with open(args.output, 'w', encoding='utf-8') as handle:
        json.dump({'version': 1, 'flows': dict(sorted(flows.items()))}, handle, indent=2)
        handle.write('\n')
    print(f'Wrote {len(flows)} flow timing(s) to {args.output}.')


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
    args = parser.parse_args()
    args.run(args)


if __name__ == '__main__':
    main()
