/**
 * Runs `work` across the public tunnel, asking again when it fails in a way `transient` recognizes: at most three
 * attempts, `backoffMs` × attempt apart (2 s). A tunnel blip clears within that; a farm that is really down still fails.
 */
export async function acrossTunnel<T>(work: (attempt: number) => Promise<T>, transient: (cause: unknown) => boolean, backoffMs = 2_000): Promise<T> {
    for (let attempt = 1; ; attempt++) {
        try {
            return await work(attempt);
        } catch (cause) {
            if (attempt === 3 || !transient(cause)) {
                throw cause;
            }
            await new Promise(resolve => setTimeout(resolve, backoffMs * attempt));
        }
    }
}
