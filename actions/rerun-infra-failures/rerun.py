#!/usr/bin/env python3
"""Re-runs a failed workflow run's failed jobs, or the whole run, once when every failure is infrastructure.

Classification is scripts/ci-metrics.py's, so the weekly report and the retry
agree on what counts as infra. A failed job without a matching annotation is
a test failure, and any test failure in the run means nothing is re-run:
re-running failed jobs would retry it too.

A job past its timeout-minutes concludes `cancelled`, and so does its run, like
one a user or a concurrency group cancelled. Only the annotation tells them
apart, so a `cancelled` job counts only when it names the timeout, and a
`cancelled` run with no such job is left alone whatever else failed in it.
"""
import importlib.util
import os
import re
import sys
from pathlib import Path
from urllib.parse import quote, urlencode

spec = importlib.util.spec_from_file_location('ci_metrics', Path(__file__).resolve().parents[2] / 'scripts' / 'ci-metrics.py')
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)


def fail(message):
    print(f'::error::{message}')
    sys.exit(1)


def freshness(api, repository, run):
    try:
        branch, sha = run['head_branch'], run['head_sha']
        if not branch or not sha:
            raise ValueError('missing run head branch or SHA')
        current_pulls = set()
        if run['event'] in ('pull_request', 'pull_request_target'):
            pulls = run.get('pull_requests') or []
            if not pulls and run['event'] == 'pull_request_target':
                raise ValueError('missing target run PR association')
            if not pulls:
                owner = run['head_repository']['owner']['login']
                query = urlencode({'state': 'open', 'head': f'{owner}:{branch}'})
                pulls = checked_pages(api, f'/repos/{repository}/pulls?{query}')
            for pull in pulls:
                detail = api.get(f"/repos/{repository}/pulls/{pull['number']}", False)
                if not detail['head']['sha']:
                    raise ValueError('missing PR head SHA')
                trigger_sha = pull.get('head', {}).get('sha') if run['event'] == 'pull_request_target' else sha
                if detail['state'] == 'open' and (not trigger_sha or detail['head']['sha'] == trigger_sha):
                    current_pulls.add(pull['number'])
            if not current_pulls:
                return 'superseded', 'the run head is no longer the head of an associated open PR'
        elif run['event'] == 'push':
            ref = api.get(f'/repos/{repository}/git/ref/heads/{quote(branch, safe="")}', False)
            if ref['object']['sha'] != sha:
                return 'superseded', 'the run head is no longer the tip of its push branch'
        query = urlencode({'branch': branch})
        runs = checked_pages(api, f"/repos/{repository}/actions/workflows/{run['workflow_id']}/runs?{query}", 'workflow_runs')
        for candidate in runs:
            if candidate['run_number'] > run['run_number']:
                if candidate['event'] != run['event'] or candidate['head_sha'] == sha:
                    continue
                if current_pulls and not current_pulls.intersection(pull['number'] for pull in candidate['pull_requests']):
                    continue
                if candidate.get('head_repository', {}).get('full_name') != run.get('head_repository', {}).get('full_name'):
                    continue
                return 'superseded', f"newer workflow run {candidate['id']} exists on this branch"
        return 'rerun', 'every failure is infrastructure'
    except (Exception, SystemExit) as error:
        return 'freshness-check-failed', f'could not verify run freshness ({type(error).__name__}); skipping to avoid retrying a superseded run'


def checked_pages(api, path, key=None):
    items, page = [], 1
    while True:
        separator = '&' if '?' in path else '?'
        data = api.get(f'{path}{separator}per_page=100&page={page}', False)
        batch = data[key] if key else data
        if not isinstance(batch, list):
            raise ValueError('invalid freshness API response')
        items.extend(batch)
        if len(batch) < 100:
            return items
        page += 1


def main():
    env = os.environ
    repository, run_id = env.get('REPOSITORY', ''), env.get('RUN_ID', '')
    max_attempts, dry_run, scope = env.get('MAX_ATTEMPTS', ''), env.get('DRY_RUN', ''), env.get('SCOPE', '')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        fail(f"repository '{repository}' must be owner/name.")
    if not re.fullmatch(r'[0-9]+', run_id):
        fail(f"run-id '{run_id}' must be a workflow run id.")
    if not re.fullmatch(r'[1-9][0-9]*', max_attempts):
        fail(f"max-attempts '{max_attempts}' must be a positive whole number.")
    if dry_run not in ('true', 'false'):
        fail(f"dry-run must be 'true' or 'false', got '{dry_run}'.")
    if scope not in ('failed-jobs', 'all'):
        fail(f"scope must be 'failed-jobs' or 'all', got '{scope}'.")

    api = metrics.Api(None)
    run = api.get(f'/repos/{repository}/actions/runs/{run_id}', False) or fail(f'run {run_id} was not found in {repository}.')
    attempt = run.get('run_attempt', 1)
    rows, infra, test = [], [], []
    freshness_reason = ''
    if run.get('status') != 'completed':
        decision = 'not-finished'
    elif run.get('conclusion') not in ('failure', 'timed_out', 'cancelled'):
        decision = 'nothing-failed'
    else:
        jobs = api.pages(f'/repos/{repository}/actions/runs/{run_id}/attempts/{attempt}/jobs', 'jobs', False)
        timed_out = False
        for job in jobs:
            if job.get('conclusion') not in ('failure', 'timed_out', 'cancelled'):
                continue
            annotations = api.get(f'/repos/{repository}/check-runs/{job["id"]}/annotations', False) or []
            if job['conclusion'] == 'cancelled':
                if not any(metrics.TIMED_OUT.search(a.get('message', '')) for a in annotations):
                    continue
                timed_out = True
            message = next((a.get('message', '') for a in annotations if a.get('message')), job.get('conclusion', ''))
            if any(metrics.ROLLUP.search(a.get('message', '')) for a in annotations):
                kind = 'roll-up'
            elif metrics.is_infra(job, annotations):
                kind = 'infra'
                infra.append(job['name'])
            else:
                kind = 'test'
                test.append(job['name'])
            rows.append((job['name'], kind, message.splitlines()[0][:160] if message else ''))
        if run['conclusion'] == 'cancelled' and not timed_out:
            decision = 'nothing-failed'
        elif test:
            decision = 'test-failure'
        elif not infra:
            decision = 'unclassified'
        elif attempt > int(max_attempts):
            decision = 'retries-exhausted'
        else:
            decision, freshness_reason = freshness(api, repository, run)
            if decision != 'rerun':
                level = 'warning' if decision == 'freshness-check-failed' else 'notice'
                print(f'::{level}::{freshness_reason}.')
            if decision == 'rerun' and dry_run == 'false':
                api.post(f"/repos/{repository}/actions/runs/{run_id}/{'rerun' if scope == 'all' else 'rerun-failed-jobs'}")

    explanation = {
        'superseded': freshness_reason,
        'freshness-check-failed': freshness_reason,
        'not-finished': 'the run has not completed',
        'nothing-failed': f"the run concluded {run.get('conclusion')}",
        'test-failure': 'a test failure is never retried, and re-running failed jobs would retry it',
        'unclassified': 'no failed job could be classified',
        'retries-exhausted': f'attempt {attempt} already used the {max_attempts} automatic retry(s)',
        'rerun': 'every failure is infrastructure' + (' (dry run: nothing was re-run)' if dry_run == 'true' else ''),
    }[decision]
    print(f'Decision: {decision} ({explanation}).')
    summary = [f'### Infra-failure retry: {decision}', '', f"[Run {run_id}]({run.get('html_url', '')}) attempt {attempt}: {explanation}.", '']
    if rows:
        summary += ['| Job | Class | First annotation |', '| --- | --- | --- |']
        summary += [f"| {name} | {kind} | {text.replace('|', '/')} |" for name, kind, text in rows]
    if env.get('GITHUB_STEP_SUMMARY'):
        with open(env['GITHUB_STEP_SUMMARY'], 'a') as handle:
            handle.write('\n'.join(summary) + '\n')
    if env.get('GITHUB_OUTPUT'):
        with open(env['GITHUB_OUTPUT'], 'a') as handle:
            handle.write(f'decision={decision}\ninfra-jobs={len(infra)}\ntest-jobs={len(test)}\n')


if __name__ == '__main__':
    main()
