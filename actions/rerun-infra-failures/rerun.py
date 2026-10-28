#!/usr/bin/env python3
"""Re-runs a failed workflow run's failed jobs once when every failure is infrastructure.

Classification is scripts/ci-metrics.py's, so the weekly report and the retry
agree on what counts as infra. A failed job without a matching annotation is
a test failure, and any test failure in the run means nothing is re-run:
re-running failed jobs would retry it too.
"""
import importlib.util
import os
import re
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location('ci_metrics', Path(__file__).resolve().parents[2] / 'scripts' / 'ci-metrics.py')
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)


def fail(message):
    print(f'::error::{message}')
    sys.exit(1)


def main():
    env = os.environ
    repository, run_id = env.get('REPOSITORY', ''), env.get('RUN_ID', '')
    max_attempts, dry_run = env.get('MAX_ATTEMPTS', ''), env.get('DRY_RUN', '')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        fail(f"repository '{repository}' must be owner/name.")
    if not re.fullmatch(r'[0-9]+', run_id):
        fail(f"run-id '{run_id}' must be a workflow run id.")
    if not re.fullmatch(r'[1-9][0-9]*', max_attempts):
        fail(f"max-attempts '{max_attempts}' must be a positive whole number.")
    if dry_run not in ('true', 'false'):
        fail(f"dry-run must be 'true' or 'false', got '{dry_run}'.")

    api = metrics.Api(None)
    run = api.get(f'/repos/{repository}/actions/runs/{run_id}', False) or fail(f'run {run_id} was not found in {repository}.')
    attempt = run.get('run_attempt', 1)
    rows, infra, test = [], [], []
    if run.get('status') != 'completed':
        decision = 'not-finished'
    elif run.get('conclusion') != 'failure':
        decision = 'nothing-failed'
    else:
        jobs = api.pages(f'/repos/{repository}/actions/runs/{run_id}/attempts/{attempt}/jobs', 'jobs', False)
        for job in jobs:
            if job.get('conclusion') not in ('failure', 'timed_out'):
                continue
            annotations = api.get(f'/repos/{repository}/check-runs/{job["id"]}/annotations', False) or []
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
        if test:
            decision = 'test-failure'
        elif not infra:
            decision = 'unclassified'
        elif attempt > int(max_attempts):
            decision = 'retries-exhausted'
        else:
            decision = 'rerun'
            if dry_run == 'false':
                api.post(f'/repos/{repository}/actions/runs/{run_id}/rerun-failed-jobs')

    explanation = {
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
