// Preloaded with NODE_OPTIONS=--import: replaces fetch with canned responses
// keyed by "METHOD decoded-url" from $FETCH_MOCK_ROUTES, and logs every request
// as a JSON line to $FETCH_MOCK_LOG. An unrouted request answers 418.
import { appendFileSync, readFileSync } from 'node:fs';

const routes = JSON.parse(readFileSync(process.env.FETCH_MOCK_ROUTES, 'utf8'));

globalThis.fetch = async (input, init = {}) => {
    const method = (init.method ?? 'GET').toUpperCase();
    const url = decodeURIComponent(String(input));
    const key = `${method} ${url}`;
    appendFileSync(
        process.env.FETCH_MOCK_LOG,
        `${JSON.stringify({ key, body: init.body === undefined ? null : String(init.body), authorization: new Headers(init.headers).get('authorization') })}\n`,
    );
    const route = routes[key] ?? { status: 418, body: { errors: [{ title: `unrouted request ${key}` }] } };
    const status = route.status ?? 200;
    const body = route.body === undefined || route.body === null || status === 204 ? null : JSON.stringify(route.body);
    return new Response(body, { status });
};
