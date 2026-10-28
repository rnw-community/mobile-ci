const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const childProcess = require('node:child_process');

const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const canonical = value => {
    if (Array.isArray(value)) return value.map(canonical);
    if (value && typeof value === 'object') {
        return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
    }
    return value;
};
const tree = (root, skip = () => false) => {
    const hash = crypto.createHash('sha256');
    const visit = (filename, relative, ancestors) => {
        const resolved = fs.realpathSync(filename);
        if (ancestors.includes(resolved)) throw new Error('Cyclic tree');
        const stat = fs.statSync(filename);
        hash.update(JSON.stringify([relative, stat.mode & 0o777, stat.isDirectory() ? 'directory' : 'file']));
        if (stat.isDirectory()) {
            for (const name of fs.readdirSync(filename).sort().filter(name => !(skip(name) && fs.statSync(path.join(filename, name)).isFile()))) {
                visit(path.join(filename, name), `${relative}/${name}`, [...ancestors, resolved]);
            }
        } else if (stat.isFile()) {
            hash.update(digest(fs.readFileSync(filename)));
        } else {
            throw new Error('Unsupported tree entry');
        }
    };
    visit(root, '.', []);
    return hash.digest('hex');
};

let outputDirectory;
try {
    const environment = process.env;
    if (!environment.NATIVE_KEY || !['ios', 'android'].includes(environment.PLATFORM)) {
        throw new Error('Missing native identity');
    }
    if (environment.SECRETS_DIGEST && !/^[0-9a-f]{64}$/.test(environment.SECRETS_DIGEST)) throw new Error('Invalid secrets digest');
    const exportEnvironment = { ...environment, NODE_ENV: 'production', CI: '1' };
    for (const line of environment.REPACK_ENV.split('\n').filter(Boolean)) {
        const match = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line);
        if (!match) throw new Error('Invalid repack environment');
        exportEnvironment[match[1]] = match[2];
    }
    outputDirectory = fs.mkdtempSync(path.join(environment.RUNNER_TEMP, 'e2e-export-'));
    const expo = args => childProcess.execFileSync('npx', ['--no-install', 'expo', ...args], {
        cwd: environment.APP_DIR,
        env: exportEnvironment,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
        timeout: 600000,
        maxBuffer: 64 * 1024 * 1024
    });
    const started = Date.now();
    let config;
    if (environment.EXPORT_COMMAND) {
        childProcess.execFileSync('bash', ['-e', '-o', 'pipefail', '-c', environment.EXPORT_COMMAND], {
            cwd: environment.APP_DIR,
            env: { ...exportEnvironment, E2E_CACHE_EXPORT_DIR: outputDirectory },
            stdio: ['ignore', 'pipe', 'pipe'],
            timeout: 600000,
            maxBuffer: 64 * 1024 * 1024
        });
        if (fs.statSync(path.join(outputDirectory, 'bundle')).size === 0) throw new Error('Empty custom bundle');
        config = JSON.parse(fs.readFileSync(path.join(outputDirectory, 'config.json'), 'utf8'));
    } else {
        expo(['export', '--platform', environment.PLATFORM, '--output-dir', outputDirectory, '--clear', '--source-maps']);
        const bundleDirectory = path.join(outputDirectory, '_expo', 'static', 'js', environment.PLATFORM);
        if (!fs.readdirSync(bundleDirectory).some(name => /\.(hbc|js)$/.test(name) && fs.statSync(path.join(bundleDirectory, name)).size > 0)) {
            throw new Error('Export has no production bundle');
        }
        config = JSON.parse(expo(['config', '--type', 'public', '--json']));
    }
    let stateVersion = '';
    if (environment.STATE_COMMAND) {
        stateVersion = childProcess.execFileSync('bash', ['-e', '-o', 'pipefail', '-c', environment.STATE_COMMAND], {
            cwd: environment.APP_DIR,
            env: exportEnvironment,
            encoding: 'utf8',
            stdio: ['ignore', 'pipe', 'pipe'],
            timeout: 60000,
            maxBuffer: 1024 * 1024
        }).trim();
        if (!stateVersion) throw new Error('Empty mutable state version');
    }
    const patterns = [...new Set(`${environment.TEST_PATHS}\n${environment.EXTRA_PATHS}`.split('\n').map(value => value.trim()).filter(Boolean))].sort();
    if (patterns.length === 0) throw new Error('No test trees');
    const paths = new Set();
    for (const pattern of patterns) {
        if (path.isAbsolute(pattern) || pattern.split('/').includes('..') || pattern === '.') {
            throw new Error('Test path must be inside the checkout');
        }
        const matches = fs.globSync(pattern);
        if (matches.length === 0) throw new Error('Missing test path');
        for (const filename of matches) paths.add(filename);
    }
    const testTrees = [...paths].sort().map(filename => [filename, tree(filename)]);
    const key = digest(JSON.stringify(canonical({
        schema: 1,
        repository: environment.GITHUB_REPOSITORY,
        platform: environment.PLATFORM,
        nativeKey: environment.NATIVE_KEY,
        bundle: tree(outputDirectory, name => name.endsWith('.map')),
        config,
        testTrees,
        stateVersion: digest(stateVersion),
        workflowRefs: JSON.parse(environment.WORKFLOW_REFS || '[]'),
        mobileCiRef: environment.MOBILE_CI_REF,
        mobileCiActions: tree(path.resolve(environment.ACTION_PATH, '..')),
        mobileCiWorkflows: tree(path.resolve(environment.ACTION_PATH, '../../.github/workflows')),
        inputs: JSON.parse(environment.LANE_INPUTS),
        target: JSON.parse(environment.TARGET),
        maestroSecrets: environment.SECRETS_DIGEST || ''
    })));
    fs.rmSync(path.join('.ci-cache/e2e-result', key), { recursive: true, force: true });
    fs.appendFileSync(environment.GITHUB_OUTPUT, `key=${key}\n`);
    fs.appendFileSync(environment.GITHUB_STEP_SUMMARY, `E2E result identity: \`${key}\` (export and hash: ${((Date.now() - started) / 1000).toFixed(1)}s).\n`);
} catch {
    process.stdout.write('::warning::E2E identity unavailable; full build/repack and Maestro remain required.\n');
    process.exitCode = 1;
} finally {
    if (outputDirectory) fs.rmSync(outputDirectory, { recursive: true, force: true });
}
