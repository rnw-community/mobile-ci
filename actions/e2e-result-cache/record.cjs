const fs = require('node:fs');
const path = require('node:path');

try {
    const environment = process.env;
    if (!/^[0-9a-f]{64}$/.test(environment.KEY)) throw new Error('Invalid key');
    const directory = path.join('.ci-cache/e2e-result', environment.KEY);
    const filename = path.join(directory, 'pass.json');
    const runPrefix = `${environment.GITHUB_SERVER_URL}/${environment.GITHUB_REPOSITORY}/actions/runs/`;
    if (environment.MODE === 'publish') {
        if (!/^\d+$/.test(environment.GITHUB_RUN_ID) || !/^\d+$/.test(environment.GITHUB_RUN_ATTEMPT)) {
            throw new Error('Missing producer identity');
        }
        fs.rmSync(directory, { recursive: true, force: true });
        fs.mkdirSync(directory, { recursive: true });
        fs.writeFileSync(filename, JSON.stringify({
            schema: 1, key: environment.KEY, repository: environment.GITHUB_REPOSITORY,
            verdict: 'passed', runUrl: `${runPrefix}${environment.GITHUB_RUN_ID}/attempts/${environment.GITHUB_RUN_ATTEMPT}`
        }));
        fs.appendFileSync(environment.GITHUB_OUTPUT, 'ready=true\n');
    } else if (environment.MODE === 'lookup') {
        const record = JSON.parse(fs.readFileSync(filename, 'utf8'));
        if (record.schema !== 1 || record.key !== environment.KEY || record.verdict !== 'passed' ||
            record.repository !== environment.GITHUB_REPOSITORY || typeof record.runUrl !== 'string' ||
            !record.runUrl.startsWith(runPrefix) || !/^\d+\/attempts\/\d+$/.test(record.runUrl.slice(runPrefix.length))) {
            throw new Error('Invalid pass record');
        }
        fs.appendFileSync(environment.GITHUB_OUTPUT, `hit=true\nrun-url=${record.runUrl}\n`);
        fs.appendFileSync(environment.GITHUB_STEP_SUMMARY,
            `### E2E cached pass\n[Successful producer run](${record.runUrl}) covers this native key, bundle and test contract. No build, repack or Maestro slot is needed.\n`);
    } else {
        throw new Error('Invalid record mode');
    }
} catch {
    process.stdout.write('::warning::E2E pass record unavailable; no cached verdict accepted or published.\n');
    process.exitCode = 1;
}
