import type { Device } from '@e2e-dev/mobile';
import type { Locator, Screen } from 'e2e';

/** A React Native testID shows up on the host view and its wrapper; Maestro takes the first, so does this. */
export const byId = (screen: Screen, id: string): Locator => screen.getByTestId(id).first();

/** Maestro's `scrollUntilVisible`: `direction` is where the content goes (`down` reveals what is below). A visible target does not scroll. */
export async function scrollTo(screen: Screen, target: Locator, direction: 'up' | 'down' = 'down', timeoutMs = 20_000): Promise<void> {
    if (!(await target.isVisible())) {
        await screen.scrollUntilVisible(target, { direction, timeout: timeoutMs });
    }
}

export interface TapUntilOptions {
    /** Taps at most this many times. Default 2: Maestro's `retryTapIfNoChange` taps once more. */
    readonly attempts?: number;
    /** How long each tap waits for `next`; omitted, `next` keeps its own timeout. */
    readonly timeoutMs?: number;
}

/**
 * Maestro's `retryTapIfNoChange`: taps `target`, then waits for `next` (the state the tap leads to). A tap a
 * screen swallows while it settles leaves `target` on screen, so while it is still visible the tap is made again,
 * up to `attempts` taps. A `target` that is gone took the tap: `next`'s failure is then the test's, and is thrown.
 */
export async function tapUntil(target: Locator, next: () => Promise<unknown>, { attempts = 2, timeoutMs }: TapUntilOptions = {}): Promise<void> {
    if (!Number.isInteger(attempts) || attempts < 1) {
        throw new Error(`tapUntil: attempts must be a whole number of at least 1; got ${String(attempts)}`);
    }
    for (let attempt = 1; ; attempt++) {
        await target.tap();
        try {
            await (timeoutMs === undefined ? next() : within(next(), timeoutMs));
            return;
        } catch (cause) {
            if (attempt === attempts || !(await target.isVisible())) {
                throw cause;
            }
        }
    }
}

function within<T>(work: Promise<T>, ms: number): Promise<T> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const late = new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(`tapUntil: the next state did not show within ${ms} ms`)), ms);
    });
    return Promise.race([work, late]).finally(() => clearTimeout(timer));
}

/**
 * Maestro's `tapOn: Done`: the keyboard's own Done key (a `key` whose id is `Done`), else an accessory bar's Done
 * button, else the keyboard is dismissed. Looking for the button alone leaves `dismissKeyboard` to time out (30 s)
 * on a keyboard whose Done key is the key itself.
 */
export async function done({ screen, device }: { readonly screen: Screen; readonly device: Pick<Device, 'dismissKeyboard'> }): Promise<void> {
    const key = screen.getByTestId('Done');
    const button = screen.getByRole('button', { name: 'Done' });
    if (await key.first().isVisible()) {
        await key.last().tap();
    } else if (await button.first().isVisible()) {
        await button.last().tap();
    } else {
        await device.dismissKeyboard();
    }
}

/** How long the list gets to come to rest after the drag before the node is measured again. */
const SETTLE_MS = 600;

export interface ScrollToCenteredOptions {
    /** The device's viewport height, in the points `boundingBox()` reports. */
    readonly viewportHeight: number;
    /** Height of the bottom band a tab bar or floating button covers. Default a third of the viewport. */
    readonly bottomBandPx?: number;
}

/**
 * Maestro's `centerElement`: scrolls `id` into view and, when its centre lies in the bottom band, where a tab bar
 * or floating button would take the tap, drags it to the middle of the viewport. Fails when it cannot leave the band.
 */
export async function scrollToCentered({ screen }: { readonly screen: Screen }, id: string, options: ScrollToCenteredOptions): Promise<void> {
    const { viewportHeight, bottomBandPx = viewportHeight / 3 } = options;
    if (!(viewportHeight > 0) || !(bottomBandPx >= 0) || bottomBandPx >= viewportHeight) {
        throw new Error(`scrollToCentered: viewportHeight must be positive and bottomBandPx inside it; got ${viewportHeight} and ${bottomBandPx}`);
    }
    const node = byId(screen, id);
    await scrollTo(screen, node);
    const bandTop = viewportHeight - bottomBandPx;
    const centre = async () => {
        const box = await node.boundingBox();
        if (box === null) {
            throw new Error(`scrollToCentered: ${id} has no bounds`);
        }
        return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
    };
    const from = await centre();
    if (from.y <= bandTop) {
        return;
    }
    await screen.swipe({ from, to: { x: from.x, y: viewportHeight / 2 }, duration: 600 });
    await new Promise(resolve => setTimeout(resolve, SETTLE_MS));
    const after = await centre();
    if (after.y > bandTop) {
        throw new Error(`scrollToCentered: ${id} is still in the bottom ${bottomBandPx} px band (centre y ${after.y} of ${viewportHeight}); the content did not scroll`);
    }
}
