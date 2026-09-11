import { createHash } from 'node:crypto';
import { appendFileSync, existsSync } from 'node:fs';
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const MIME_TYPES = {
    png: 'image/png',
    jpg: 'image/jpeg',
    jpeg: 'image/jpeg',
    gif: 'image/gif',
    webp: 'image/webp',
    bmp: 'image/bmp',
    svg: 'image/svg+xml',
    ico: 'image/x-icon',
    ttf: 'font/ttf',
    otf: 'font/otf',
    woff: 'font/woff',
    woff2: 'font/woff2',
    mp4: 'video/mp4',
    mov: 'video/quicktime',
    webm: 'video/webm',
    mp3: 'audio/mpeg',
    wav: 'audio/wav',
    m4a: 'audio/mp4',
    json: 'application/json',
    txt: 'text/plain'
};

const fail = message => {
    console.error(`::error::${message}`);
    process.exit(1);
};

const appendOutput = (name, value) => {
    if (existsSync(process.env.GITHUB_OUTPUT ?? '')) {
        appendFileSync(process.env.GITHUB_OUTPUT, `${name}=${value}\n`);
    }
};

const base64Url = buffer => buffer.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

const sha256Hex = buffer => createHash('sha256').update(buffer).digest('hex');

const toUuid = hex => `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;

const parsePlatforms = raw =>
    raw
        .split(',')
        .map(value => value.trim())
        .filter(Boolean);

const distDir = path.resolve(process.env.DIST_DIR || 'dist');
const publicBaseUrl = (process.env.PUBLIC_BASE_URL || '').replace(/\/+$/, '');
const platforms = parsePlatforms(process.env.PLATFORMS || 'ios,android');
const urlStyle = process.env.URL_STYLE || 'path';
const runtimeVersions = {
    ios: process.env.RUNTIME_VERSION_IOS || '',
    android: process.env.RUNTIME_VERSION_ANDROID || ''
};

if (publicBaseUrl === '') {
    fail('public-base-url is required: it is the URL prefix every manifest asset URL is built from.');
}
if (urlStyle !== 'path' && urlStyle !== 'release') {
    fail(`Unsupported url-style '${urlStyle}'; expected path or release.`);
}
if (platforms.length === 0) {
    fail('platforms must list at least one of ios, android.');
}
for (const platform of platforms) {
    if (platform !== 'ios' && platform !== 'android') {
        fail(`Unsupported platform '${platform}'; expected ios or android.`);
    }
    if (runtimeVersions[platform] === '') {
        fail(`runtime-version-${platform} is required to generate the ${platform} manifest.`);
    }
}

const flatten = relativePath => (urlStyle === 'release' ? relativePath.split('/').join('__') : relativePath);
const assetUrl = relativePath => `${publicBaseUrl}/${flatten(relativePath)}`;

const metadataPath = path.join(distDir, 'metadata.json');
if (!existsSync(metadataPath)) {
    fail(`No metadata.json found at ${metadataPath}; run \`expo export\` before this action.`);
}

const metadataBuffer = await readFile(metadataPath);
const metadata = JSON.parse(metadataBuffer.toString('utf8'));
if (metadata?.fileMetadata === undefined || metadata.fileMetadata === null) {
    fail('metadata.json has no fileMetadata object; export output is not usable.');
}

const updateId = toUuid(sha256Hex(metadataBuffer));
const metadataStat = await stat(metadataPath);
const createdAt = process.env.CREATED_AT || metadataStat.mtime.toISOString();

const expoConfigPath = process.env.EXPO_CONFIG_PATH || path.join(distDir, 'expoConfig.json');
let expoClient;
if (process.env.INCLUDE_EXPO_CONFIG !== 'false' && existsSync(expoConfigPath)) {
    expoClient = JSON.parse(await readFile(expoConfigPath, 'utf8'));
}

const extra = {};
if (expoClient !== undefined) {
    extra.expoClient = expoClient;
}
if ((process.env.PROJECT_ID || '') !== '') {
    extra.eas = { projectId: process.env.PROJECT_ID };
}

const digestCache = new Map();
const digestFor = async relativePath => {
    if (digestCache.has(relativePath)) {
        return digestCache.get(relativePath);
    }
    const absolutePath = path.join(distDir, relativePath);
    if (!existsSync(absolutePath)) {
        fail(`Manifest references '${relativePath}' but ${absolutePath} does not exist.`);
    }
    const buffer = await readFile(absolutePath);
    const value = { hash: base64Url(createHash('sha256').update(buffer).digest()), key: createHash('md5').update(buffer).digest('hex') };
    digestCache.set(relativePath, value);

    return value;
};

const assetMetadata = async (relativePath, ext, isLaunchAsset) => {
    const { hash, key } = await digestFor(relativePath);
    const suffix = isLaunchAsset ? 'bundle' : ext;

    return {
        hash,
        key,
        fileExtension: `.${suffix}`,
        contentType: isLaunchAsset ? 'application/javascript' : MIME_TYPES[String(ext).toLowerCase()] || 'application/octet-stream',
        url: assetUrl(relativePath)
    };
};

for (const platform of platforms) {
    const platformMetadata = metadata.fileMetadata[platform];
    if (platformMetadata === undefined || platformMetadata === null) {
        fail(`metadata.json has no fileMetadata.${platform}; run \`expo export\` for that platform.`);
    }
    if (typeof platformMetadata.bundle !== 'string' || platformMetadata.bundle === '') {
        fail(`metadata.json fileMetadata.${platform}.bundle is missing.`);
    }

    const assets = [];
    for (const asset of platformMetadata.assets ?? []) {
        assets.push(await assetMetadata(asset.path, asset.ext, false));
    }
    const launchAsset = await assetMetadata(platformMetadata.bundle, null, true);

    const manifest = {
        id: updateId,
        createdAt,
        runtimeVersion: runtimeVersions[platform],
        assets,
        launchAsset,
        metadata: {},
        extra
    };

    const outputDir = path.join(distDir, platform);
    await mkdir(outputDir, { recursive: true });
    const outputPath = path.join(outputDir, 'manifest.json');
    await writeFile(outputPath, `${JSON.stringify(manifest, null, 2)}\n`);

    const url = assetUrl(`${platform}/manifest.json`);
    appendOutput(`manifest-${platform}`, outputPath);
    appendOutput(`url-${platform}`, url);
    console.log(`Wrote ${outputPath} (${assets.length} assets, runtime ${runtimeVersions[platform]}) -> ${url}`);
}
