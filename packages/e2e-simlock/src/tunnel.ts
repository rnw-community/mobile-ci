/**
 * Runs `work` across the public tunnel, asking again when it fails in a way `transient` recognizes: at most three
 * attempts, 2 s × attempt apart. A tunnel blip clears within that; a farm that is really down still fails.
 */
export async function acrossTunnel<T>(work: () => Promise<T>, transient: (cause: unknown) => boolean): Promise<T> {
    for (let attempt = 1; ; attempt++) {
        try {
            return await work();
        } catch (cause) {
            if (attempt === 3 || !transient(cause)) {
                throw cause;
            }
            await new Promise(resolve => setTimeout(resolve, 2_000 * attempt));
        }
    }
}
