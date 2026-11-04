import type { Device } from '@e2e-dev/mobile';
import type { Locator, Screen } from 'e2e';

export { measureRecording, type RecordingStats } from './recording.ts';

/** A React Native testID shows up on the host view and its wrapper; this takes the first. */
export const byId = (screen: Screen, id: string): Locator => screen.getByTestId(id).first();

/** Scrolls until visible: `direction` is where the content goes (`down` reveals what is below). A visible target does not scroll. */
export async function scrollTo(screen: Screen, target: Locator, direction: 'up' | 'down' = 'down', timeoutMs = 20_000): Promise<void> {
    if (!(await target.isVisible())) {
        await screen.scrollUntilVisible(target, { direction, timeout: timeoutMs });
    }
}

export interface TapUntilOptions {
    /** Taps at most this many times. Default 2: one more tap. */
    readonly attempts?: number;
    /** How long each tap waits for `next`; omitted, `next` keeps its own timeout. */
    readonly timeoutMs?: number;
}

/**
 * Taps `target`, then waits for `next` (the state the tap leads to). A tap a
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
 * Taps Done: the keyboard's own Done key (a `key` whose id is `Done`), else an accessory bar's Done
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

/** Runs `body` up to `1 + retries` times, logging each failure and rethrowing the last. */
export async function retry(retries: number, body: (attempt: number) => Promise<void>): Promise<void> {
    if (!Number.isInteger(retries) || retries < 0) {
        throw new Error(`retry: retries must be a whole number; got ${String(retries)}`);
    }
    for (let attempt = 1; ; attempt++) {
        try {
            await body(attempt);
            return;
        } catch (cause) {
            if (attempt > retries) {
                throw cause;
            }
            console.log(`[retry] attempt ${attempt} of ${retries + 1} failed: ${String(cause instanceof Error ? cause.message : cause).split('\n')[0]}`);
        }
    }
}

/** How long the list gets to come to rest after a drag before the node is measured again. */
const SETTLE_MS = 600;
const MAX_DRAGS = 3;
/** The share of a drag the node must follow for the list to count as moving: a list at its end only bounces. */
const MOVING_SHARE = 1 / 4;
/** How far from the edge of the screen a drag stays, and from a band it must start clear of. */
const EDGE_PX = 40;

type Box = NonNullable<Awaited<ReturnType<Locator['boundingBox']>>>;

/** Where to drag from and how far the content moves up (negative: down), or undefined when the node is in place. */
type Placement = (box: Box) => { readonly fromY: number; readonly upPx: number } | undefined;

const centreY = (box: Box): number => box.y + box.height / 2;

/**
 * Drags the content until `placement` is satisfied. The drag starts where the placement says, never on the node,
 * which may be under the overlay it is being moved away from. A drag the node did not follow for a quarter of its
 * length means the list is at its end, and the node stays where it is. A list still moving after three drags fails.
 */
async function dragInto(helper: string, screen: Screen, id: string, node: Locator, placement: Placement, viewportHeight: number, dragX: number | undefined): Promise<void> {
    const onScreen = (y: number): number => Math.max(EDGE_PX, Math.min(viewportHeight - EDGE_PX, y));
    let previous: { readonly y: number; readonly askedUp: number } | undefined;
    for (let drags = 0; ; drags++) {
        const box = await node.boundingBox();
        if (box === null) {
            throw new Error(`${helper}: ${id} has no bounds`);
        }
        const drag = placement(box);
        if (drag === undefined || (previous !== undefined && (previous.y - box.y) * Math.sign(previous.askedUp) < Math.max(1, Math.abs(previous.askedUp) * MOVING_SHARE))) {
            return;
        }
        if (drags === MAX_DRAGS) {
            throw new Error(`${helper}: ${id} is still out of place after ${MAX_DRAGS} drags (centre y ${centreY(box)} of ${viewportHeight})`);
        }
        const x = dragX ?? box.x + box.width / 2;
        const fromY = onScreen(drag.fromY);
        const toY = onScreen(fromY - drag.upPx);
        await screen.swipe({ from: { x, y: fromY }, to: { x, y: toY }, duration: 600 });
        await new Promise(resolve => setTimeout(resolve, SETTLE_MS));
        previous = { y: box.y, askedUp: fromY - toY };
    }
}

export interface DragOptions {
    /** The x every drag runs along, clear of switches and other controls that would take it. Default the node's centre. */
    readonly dragX?: number;
}

export interface ScrollToCenteredOptions extends DragOptions {
    /** The device's viewport height, in the points `boundingBox()` reports. */
    readonly viewportHeight: number;
    /** Height of the bottom band a tab bar or floating button covers. Default a third of the viewport. */
    readonly bottomBandPx?: number;
}

/**
 * Scrolls `id` into view and, when its centre lies in the bottom band, where a tab bar
 * or floating button would take the tap, drags the content from above the band to bring it to the middle of the viewport.
 */
export async function scrollToCentered({ screen }: { readonly screen: Screen }, id: string, options: ScrollToCenteredOptions): Promise<void> {
    const { viewportHeight, bottomBandPx = viewportHeight / 3, dragX } = options;
    if (!(viewportHeight > 0) || !(bottomBandPx >= 0) || bottomBandPx >= viewportHeight) {
        throw new Error(`scrollToCentered: viewportHeight must be positive and bottomBandPx inside it; got ${viewportHeight} and ${bottomBandPx}`);
    }
    const node = byId(screen, id);
    await scrollTo(screen, node);
    const bandTop = viewportHeight - bottomBandPx;
    const placement: Placement = box => (centreY(box) <= bandTop ? undefined : { fromY: bandTop - EDGE_PX, upPx: centreY(box) - viewportHeight / 2 });
    await dragInto('scrollToCentered', screen, id, node, placement, viewportHeight, dragX);
}

export interface ScrollToMiddleOptions extends DragOptions {
    /** The device's viewport height, in the points `boundingBox()` reports. */
    readonly viewportHeight: number;
    /** Where the content goes while scrolling the node into view. Default `'down'`. */
    readonly direction?: 'up' | 'down';
    /** How far from the middle the node's centre may be. Default 150. */
    readonly tolerancePx?: number;
    /** The longest single drag. Default 300. */
    readonly maxDragPx?: number;
}

/**
 * Scrolls a node into the clear when it can sit under a header or a floating tab bar:
 * scrolls `id` into view in either direction, then drags the content until its centre is near the viewport's middle.
 */
export async function scrollToMiddle({ screen }: { readonly screen: Screen }, id: string, options: ScrollToMiddleOptions): Promise<void> {
    const { viewportHeight, direction = 'down', tolerancePx = 150, maxDragPx = 300, dragX } = options;
    const node = byId(screen, id);
    await scrollTo(screen, node, direction);
    const middle = viewportHeight / 2;
    const placement: Placement = box => {
        const away = centreY(box) - middle;
        return Math.abs(away) < tolerancePx ? undefined : { fromY: middle, upPx: Math.max(-maxDragPx, Math.min(maxDragPx, away)) };
    };
    await dragInto('scrollToMiddle', screen, id, node, placement, viewportHeight, dragX);
}

export interface ScrollAboveOptions extends DragOptions {
    /** How far above the element the node's bottom edge must end up. Default 8. */
    readonly marginPx?: number;
    /** The length of each drag. Default 250. */
    readonly dragPx?: number;
}

/**
 * Scrolls `id` into view, then drags the content until the node's bottom edge sits above `element`, a sticky footer
 * that would take a tap aimed at the node. Each drag starts above the element, since one that starts on a fixed
 * footer moves nothing. An element that is not on screen has nothing to clear.
 */
export async function scrollAbove({ screen }: { readonly screen: Screen }, id: string, element: Locator, options: ScrollAboveOptions = {}): Promise<void> {
    const { marginPx = 8, dragPx = 250, dragX } = options;
    const node = byId(screen, id);
    await scrollTo(screen, node);
    const top = (await element.boundingBox())?.y;
    const placement: Placement = box => (top === undefined || box.y + box.height < top - marginPx ? undefined : { fromY: top - 150, upPx: dragPx });
    await dragInto('scrollAbove', screen, id, node, placement, Number.POSITIVE_INFINITY, dragX);
}
