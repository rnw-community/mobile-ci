#!/usr/bin/env python3
"""Mobile CI metrics across consumer repositories, read from the Actions API.

Usage:
  scripts/ci-metrics.py --repo owner/name [--repo ...] --since YYYY-MM-DD --until YYYY-MM-DD
                        [--baseline-since YYYY-MM-DD --baseline-until YYYY-MM-DD]
                        [--cache-dir DIR] [--json FILE]

Prints a Markdown report. With a baseline window, every number gets a delta
against it. `--until` is exclusive. GH_TOKEN (or GITHUB_TOKEN) must be able to
read Actions on every repository. CI_METRICS_FIXTURES=<dir> answers every API
path from <dir> instead of the network (used by tests/ci-metrics_test.sh).

Definitions:
  PR feedback   per pull-request head commit whose mobile lane ran (a Plan
                job): that run's creation -> its last first-attempt job.
                This is the definition #273's baseline used.
  Queue         job started_at - created_at for jobs a runner picked up,
                grouped by the job's most specific runner label.
  Native share  head commits whose iOS/Android lane ran a native Build job,
                over head commits whose lane ran a Plan job.
  Shards        duration of jobs named "Maestro shard ...".
  Failures      failed or timed-out jobs, except roll-up jobs that only
                report other jobs' results; infra when an annotation or the
                conclusion matches INFRA_PATTERNS, test otherwise.
"""
import argparse
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

API = os.environ.get('GITHUB_API_URL', 'https://api.github.com')
INFRA_PATTERNS = [
    re.compile(p, re.I) for p in (
        r'runner (has )?lost communication',
        r'exec format error',
        r'job was not started because',
        r'runner has received a shutdown signal',
        r'no space left on device',
        r'the operation was canceled',
        r'could not resolve host|connection (reset|refused|timed out)',
        r'unable to resolve action',
        r'exceeded the maximum execution time',
        r'an error occurred trying to start process',
        r'process completed with exit code (127|137|143)\b',
    )
]
ROLLUP = re.compile(r'required jobs did not succeed', re.I)
POOL_LABEL = re.compile(r'^(trf-|linux-|macos-|ubuntu|windows)', re.I)


def parse_time(value):
    return dt.datetime.fromisoformat(value.replace('Z', '+00:00')) if value else None


def minutes(start, end):
    return (end - start).total_seconds() / 60


class Api:
    def __init__(self, cache_dir):
        self.token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN') or ''
        self.fixtures = os.environ.get('CI_METRICS_FIXTURES')
        self.cache_dir = Path(cache_dir) if cache_dir else None
        if not self.fixtures and not self.token:
            raise SystemExit('ci-metrics: GH_TOKEN or GITHUB_TOKEN is required')

    @staticmethod
    def _slug(path):
        return re.sub(r'[^A-Za-z0-9._-]+', '_', path.strip('/'))

    def get(self, path, cacheable):
        if self.fixtures:
            fixture = Path(self.fixtures) / f'{self._slug(path)}.json'
            return json.loads(fixture.read_text()) if fixture.exists() else {}
        cached = self.cache_dir / f'{self._slug(path)}.json' if self.cache_dir and cacheable else None
        if cached and cached.exists():
            return json.loads(cached.read_text())
        request = urllib.request.Request(f'{API}{path}', headers={
            'Authorization': f'Bearer {self.token}',
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
        })
        for attempt in range(6):
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    data = json.load(response)
                break
            except urllib.error.HTTPError as error:
                remaining = error.headers.get('x-ratelimit-remaining')
                if error.code in (403, 429) and (remaining == '0' or error.headers.get('retry-after')):
                    reset = int(error.headers.get('x-ratelimit-reset') or 0)
                    wait = int(error.headers.get('retry-after') or 0) or max(reset - int(time.time()), 1) + 1
                    print(f'ci-metrics: rate limited; sleeping {min(wait, 3600)}s', file=sys.stderr)
                    time.sleep(min(wait, 3600))
                    continue
                if error.code >= 500 and attempt < 5:
                    time.sleep(2 ** attempt)
                    continue
                raise
            except urllib.error.URLError:
                if attempt == 5:
                    raise
                time.sleep(2 ** attempt)
        else:
            raise SystemExit(f'ci-metrics: giving up on {path}')
        if cached:
            cached.parent.mkdir(parents=True, exist_ok=True)
            cached.write_text(json.dumps(data))
        return data

    def pages(self, path, key, cacheable):
        items, page = [], 1
        while True:
            separator = '&' if '?' in path else '?'
            data = self.get(f'{path}{separator}per_page=100&page={page}', cacheable)
            batch = data.get(key, [])
            items.extend(batch)
            if len(batch) < 100:
                return items
            page += 1


def collect(api, repo, since, until):
    today = dt.datetime.now(dt.timezone.utc).date()
    runs = []
    day = since
    while day < until:
        runs.extend(api.pages(f'/repos/{repo}/actions/runs?created={day.isoformat()}', 'workflow_runs', day < today))
        day += dt.timedelta(days=1)
    runs = [run for run in runs if run.get('status') == 'completed']

    def jobs_of(run):
        return run, api.pages(f'/repos/{repo}/actions/runs/{run["id"]}/attempts/1/jobs', 'jobs', True)

    with ThreadPoolExecutor(max_workers=8) as pool:
        pairs = list(pool.map(jobs_of, runs))

    def annotations_of(job):
        return job['id'], api.get(f'/repos/{repo}/check-runs/{job["id"]}/annotations', True) or []

    failed = [job for _, jobs in pairs for job in jobs if job.get('conclusion') in ('failure', 'timed_out')]
    with ThreadPoolExecutor(max_workers=8) as pool:
        annotations = dict(pool.map(annotations_of, failed))
    return pairs, annotations


def pool_of(job):
    labels = [label for label in job.get('labels', []) if label != 'self-hosted']
    specific = [label for label in labels if POOL_LABEL.match(label)]
    return (specific or labels or ['unlabelled'])[-1]


def is_infra(job, annotations):
    texts = [job.get('conclusion', '')] + [a.get('message', '') + ' ' + a.get('title', '') for a in annotations]
    if job.get('conclusion') == 'timed_out':
        return True
    return any(pattern.search(text) for pattern in INFRA_PATTERNS for text in texts)


def quantile(values, q):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, round(q * (len(ordered) - 1))))]


def summarize(pairs, annotations):
    feedback, queue, native, planned, shards = {}, {}, set(), set(), []
    infra = test = 0
    for run, jobs in pairs:
        ran = [job for job in jobs if job.get('conclusion') not in (None, 'skipped')]
        if run.get('event') == 'pull_request' and any(re.search(r'Plan \(', job['name']) for job in ran):
            sha = run['head_sha']
            created = parse_time(run['created_at'])
            ends = [parse_time(job['completed_at']) for job in jobs if job.get('completed_at')]
            start, end = feedback.get(sha, (created, created))
            feedback[sha] = (min(start, created), max([end] + ends))
            planned.add(sha)
            if any(re.search(r'(^|/ )Build \(', job['name']) for job in ran):
                native.add(sha)
        for job in jobs:
            if job.get('runner_name') and job.get('started_at') and job.get('conclusion') != 'skipped':
                queue.setdefault(pool_of(job), []).append(minutes(parse_time(job['created_at']), parse_time(job['started_at'])))
            if re.search(r'Maestro shard', job['name']) and job.get('conclusion') in ('success', 'failure') and job.get('completed_at'):
                shards.append(minutes(parse_time(job['started_at']), parse_time(job['completed_at'])))
            if job['id'] in annotations and not any(ROLLUP.search(a.get('message', '')) for a in annotations[job['id']]):
                if is_infra(job, annotations[job['id']]):
                    infra += 1
                else:
                    test += 1
    durations = [minutes(start, end) for start, end in feedback.values()]
    return {
        'prCommits': len(durations),
        'feedbackP50': quantile(durations, 0.5),
        'feedbackP90': quantile(durations, 0.9),
        'queue': {pool: {'jobs': len(v), 'p50': quantile(v, 0.5), 'p90': quantile(v, 0.9)} for pool, v in sorted(queue.items())},
        'nativeShare': (len(native & planned) / len(planned)) if planned else None,
        'shards': {'jobs': len(shards), 'p50': quantile(shards, 0.5), 'p90': quantile(shards, 0.9), 'max': max(shards) if shards else None},
        'failures': {'infra': infra, 'test': test, 'infraShare': infra / (infra + test) if infra + test else None},
    }


def fmt(value, unit=' min', baseline=None, percent=False):
    if value is None:
        return '—'
    text = f'{value * 100:.0f}%' if percent else f'{value:.1f}{unit}'
    if baseline is not None:
        delta = value - baseline
        text += f' ({delta * 100:+.0f} pp)' if percent else f' ({delta:+.1f})'
    return text


def report(results, baselines, window):
    lines = [f'## Mobile CI metrics, {window}', '']
    lines += ['| Repository | PR commits | Feedback p50 | Feedback p90 | Native share | Shard p50 | Shard p90 | Shard max | Infra share of failures |',
              '| --- | --- | --- | --- | --- | --- | --- | --- | --- |']
    for repo, summary in results.items():
        base = baselines.get(repo, {})
        shard_base = base.get('shards', {})
        lines.append('| ' + ' | '.join([
            repo,
            str(summary['prCommits']),
            fmt(summary['feedbackP50'], baseline=base.get('feedbackP50')),
            fmt(summary['feedbackP90'], baseline=base.get('feedbackP90')),
            fmt(summary['nativeShare'], percent=True, baseline=base.get('nativeShare')),
            fmt(summary['shards']['p50'], baseline=shard_base.get('p50')),
            fmt(summary['shards']['p90'], baseline=shard_base.get('p90')),
            fmt(summary['shards']['max'], baseline=shard_base.get('max')),
            fmt(summary['failures']['infraShare'], percent=True, baseline=base.get('failures', {}).get('infraShare'))
            + f" ({summary['failures']['infra']}/{summary['failures']['infra'] + summary['failures']['test']})",
        ]) + ' |')
    pools = {}
    for repo, summary in results.items():
        for pool, stats in summary['queue'].items():
            pools.setdefault(pool, []).append((repo, stats))
    lines += ['', '| Pool | Repository | Jobs | Queue p50 | Queue p90 |', '| --- | --- | --- | --- | --- |']
    for pool in sorted(pools):
        for repo, stats in pools[pool]:
            base = baselines.get(repo, {}).get('queue', {}).get(pool, {})
            lines.append(f"| `{pool}` | {repo} | {stats['jobs']} | {fmt(stats['p50'], baseline=base.get('p50'))} | {fmt(stats['p90'], baseline=base.get('p90'))} |")
    lines += ['', 'Cache hit rates are not measured yet: they need job logs, which the Actions API does not summarize.']
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--repo', action='append', required=True)
    parser.add_argument('--since', required=True, type=dt.date.fromisoformat)
    parser.add_argument('--until', required=True, type=dt.date.fromisoformat)
    parser.add_argument('--baseline-since', type=dt.date.fromisoformat)
    parser.add_argument('--baseline-until', type=dt.date.fromisoformat)
    parser.add_argument('--cache-dir')
    parser.add_argument('--json')
    args = parser.parse_args()
    if args.since >= args.until:
        parser.error('--since must be before --until')
    if (args.baseline_since is None) != (args.baseline_until is None):
        parser.error('--baseline-since and --baseline-until go together')
    for repo in args.repo:
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
            parser.error(f'invalid repository {repo!r}')
    api = Api(args.cache_dir)
    results, baselines = {}, {}
    for repo in args.repo:
        results[repo] = summarize(*collect(api, repo, args.since, args.until))
        if args.baseline_since:
            baselines[repo] = summarize(*collect(api, repo, args.baseline_since, args.baseline_until))
    window = f'{args.since} to {args.until - dt.timedelta(days=1)}'
    if args.baseline_since:
        window += f' (deltas against {args.baseline_since} to {args.baseline_until - dt.timedelta(days=1)})'
    sys.stdout.write(report(results, baselines, window))
    if args.json:
        Path(args.json).write_text(json.dumps({'results': results, 'baselines': baselines}, indent=2, default=str))


if __name__ == '__main__':
    main()
