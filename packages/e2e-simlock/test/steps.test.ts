import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { byId, done, retry, scrollAbove, scrollTo, scrollToCentered, scrollToMiddle, tapUntil } from '../src/steps.ts';

import type { Locator, Screen } from 'e2e';

type Box = { x: number; y: number; width: number; height: number } | null;

/** A fake locator: `visible` is read in order (the last value repeats), `boxes` likewise; taps are counted. */
function locator(visible: boolean[] = [true], boxes: Box[] = [null]) {
    const calls = { taps: 0, visibleReads: 0 };
    const at = <T>(list: T[], i: number): T => list[Math.min(i, list.length - 1)]!;
    let boxReads = 0;
    const self = {
        calls,
        tap: async () => {
            calls.taps += 1;
        },
        isVisible: async () => at(visible, calls.visibleReads++),
        boundingBox: async () => at(boxes, boxReads++),
        first: () => self,
        last: () => self
    };
    return self;
}

const asLocator = (fake: ReturnType<typeof locator>) => fake as unknown as Locator;

describe('byId', () => {
    it('takes the first node with the testID, since React Native reports it on the host view and its wrapper', () => {
        const seen: string[] = [];
        const first = { id: 'first' };
        const screen = { getByTestId: (id: string) => (seen.push(id), { first: () => first }) } as unknown as Screen;
        assert.equal(byId(screen, 'Home.Start'), first);
        assert.deepEqual(seen, ['Home.Start']);
    });
});

describe('scrollTo', () => {
    it('scrolls only when the target is not visible yet', async () => {
        const scrolled: unknown[] = [];
        const screen = { scrollUntilVisible: async (_t: unknown, options: unknown) => scrolled.push(options) } as unknown as Screen;
        await scrollTo(screen, asLocator(locator([true])));
        await scrollTo(screen, asLocator(locator([false])), 'up', 5_000);
        assert.deepEqual(scrolled, [{ direction: 'up', timeout: 5_000 }]);
    });
});

describe('tapUntil', () => {
    const failsThen = (failures: number) => {
        let calls = 0;
        return {
            next: async () => {
                calls += 1;
                if (calls <= failures) throw new Error(`next state missing (${calls})`);
            },
            calls: () => calls
        };
    };

    it('taps once when the next state shows', async () => {
        const target = locator();
        await tapUntil(asLocator(target), failsThen(0).next);
        assert.equal(target.calls.taps, 1);
    });

    it('taps once more when the tap was swallowed (the target is still visible)', async () => {
        const target = locator([true]);
        const next = failsThen(1);
        await tapUntil(asLocator(target), next.next);
        assert.deepEqual([target.calls.taps, next.calls()], [2, 2]);
    });

    it("throws next's failure without tapping again when the target is gone (the tap took)", async () => {
        const target = locator([false]);
        await assert.rejects(tapUntil(asLocator(target), failsThen(9).next), { message: 'next state missing (1)' });
        assert.equal(target.calls.taps, 1);
    });

    it('stops after `attempts` taps, with the last failure', async () => {
        const target = locator([true]);
        await assert.rejects(tapUntil(asLocator(target), failsThen(9).next, { attempts: 3 }), { message: 'next state missing (3)' });
        assert.equal(target.calls.taps, 3);
    });

    it('bounds each wait by timeoutMs, naming it', async () => {
        const target = locator([false]);
        const never = () => new Promise<void>(() => undefined);
        await assert.rejects(tapUntil(asLocator(target), never, { timeoutMs: 20 }), { message: 'tapUntil: the next state did not show within 20 ms' });
    });

    it('refuses an attempt count that is not a whole number of at least 1', async () => {
        for (const attempts of [0, 1.5, Number.NaN]) {
            await assert.rejects(tapUntil(asLocator(locator()), failsThen(0).next, { attempts }), {
                message: `tapUntil: attempts must be a whole number of at least 1; got ${String(attempts)}`
            });
        }
    });
});

describe('done', () => {
    const keyboard = (keyVisible: boolean, buttonVisible: boolean) => {
        const key = locator([keyVisible]);
        const button = locator([buttonVisible]);
        let dismissed = 0;
        const screen = {
            getByTestId: (id: string) => (assert.equal(id, 'Done'), key),
            getByRole: (role: string, options: unknown) => (assert.deepEqual([role, options], ['button', { name: 'Done' }]), button)
        } as unknown as Screen;
        const device = { dismissKeyboard: async () => void (dismissed += 1) };
        return { ctx: { screen, device }, key, button, dismissed: () => dismissed };
    };

    it("taps the keyboard's own Done key first", async () => {
        const k = keyboard(true, true);
        await done(k.ctx);
        assert.deepEqual([k.key.calls.taps, k.button.calls.taps, k.dismissed()], [1, 0, 0]);
    });

    it("taps an accessory bar's Done button when the keyboard has no Done key", async () => {
        const k = keyboard(false, true);
        await done(k.ctx);
        assert.deepEqual([k.key.calls.taps, k.button.calls.taps, k.dismissed()], [0, 1, 0]);
    });

    it('dismisses the keyboard when neither shows', async () => {
        const k = keyboard(false, false);
        await done(k.ctx);
        assert.deepEqual([k.key.calls.taps, k.button.calls.taps, k.dismissed()], [0, 0, 1]);
    });
});

type Swipe = { from: { x: number; y: number }; to: { x: number; y: number }; duration: number };

/**
 * A scrolling list under a fixed overlay. A drag that starts below `overlayTop` lands on the overlay and moves nothing;
 * any other drag moves the node with the content, as far as the list can still go (`up` and `down`, in px).
 */
function list({ y, height = 40, overlayTop = Number.POSITIVE_INFINITY, up = Number.POSITIVE_INFINITY, down = Number.POSITIVE_INFINITY, width = 100, box = true }: { y: number; height?: number; overlayTop?: number; up?: number; down?: number; width?: number; box?: boolean }) {
    let position = y;
    const swipes: Swipe[] = [];
    const scrolled: unknown[] = [];
    const node = { isVisible: async () => true, boundingBox: async () => (box ? { x: 0, y: position, width, height } : null) };
    const screen = {
        getByTestId: () => ({ first: () => node }),
        scrollUntilVisible: async (_target: unknown, options: unknown) => void scrolled.push(options),
        swipe: async (swipe: Swipe) => {
            swipes.push(swipe);
            if (swipe.from.y < overlayTop) {
                const moved = Math.max(-up, Math.min(down, swipe.to.y - swipe.from.y));
                position += moved;
                up += moved;
                down -= moved;
            }
        }
    } as unknown as Screen;
    return { ctx: { screen }, node, swipes, scrolled, y: () => position };
}

describe('scrollToCentered', () => {
    const phone = { viewportHeight: 874, bottomBandPx: 314 };

    it('leaves a node clear of the bottom band where it is', async () => {
        const { ctx, swipes } = list({ y: 500 });
        await scrollToCentered(ctx, 'Card', phone);
        assert.deepEqual(swipes, []);
    });

    it('drags from above the band, by the distance to the middle of the viewport', async () => {
        const { ctx, swipes, y } = list({ y: 700 });
        await scrollToCentered(ctx, 'Card', phone);
        assert.deepEqual(swipes, [{ from: { x: 50, y: 520 }, to: { x: 50, y: 237 }, duration: 600 }]);
        assert.equal(y(), 417);
    });

    it("moves a node under a tab bar: a drag from the node itself lands on the bar and moves nothing (budgie's y 869.8)", async () => {
        const { ctx, y } = list({ y: 849.8, overlayTop: 780 });
        await scrollToCentered(ctx, 'SettingsPage.Switch', phone);
        assert.equal(Math.round(y() + 20), 437);
    });

    it("leaves a node at a list's end where it is: the drag moved nothing and that is no failure (budgie's y 665.3)", async () => {
        const { ctx, swipes, y } = list({ y: 645.3, up: 0 });
        await scrollToCentered(ctx, 'AccountCard.Deposit', phone);
        assert.equal(y(), 645.3);
        assert.equal(swipes.length, 1);
    });

    it('drags again while the list still moves, and stops at its end', async () => {
        const { ctx, swipes, y } = list({ y: 780, up: 100 });
        await scrollToCentered(ctx, 'Card', phone);
        assert.equal(y(), 680);
        assert.equal(swipes.length, 2);
    });

    it('takes the x to drag at, since a drag on a control in the node column would take the gesture', async () => {
        const { ctx, swipes } = list({ y: 700 });
        await scrollToCentered(ctx, 'Card', { ...phone, dragX: 200 });
        assert.deepEqual([swipes[0]!.from.x, swipes[0]!.to.x], [200, 200]);
    });

    it('keeps the drag on screen, whatever the band', async () => {
        const { ctx, swipes } = list({ y: 800, up: 0 });
        await scrollToCentered(ctx, 'Card', { viewportHeight: 874, bottomBandPx: 700 });
        assert.deepEqual([swipes[0]!.from.y, swipes[0]!.to.y], [134, 40]);
    });

    it('defaults the band to the bottom third of the viewport', async () => {
        const { ctx, swipes } = list({ y: 620, height: 20 });
        // 630 lies below 900 - 900 / 3 = 600.
        await scrollToCentered(ctx, 'Card', { viewportHeight: 900 });
        assert.equal(swipes.length, 1);
    });

    it('fails closed when the node has no bounds, or is still moving and in the band after three drags', async () => {
        await assert.rejects(scrollToCentered(list({ y: 800, box: false }).ctx, 'Card', { viewportHeight: 874 }), { message: 'scrollToCentered: Card has no bounds' });
        const creeping = list({ y: 800 });
        creeping.node.boundingBox = async () => ({ x: 0, y: 1400 - 200 * creeping.swipes.length, width: 100, height: 40 });
        await assert.rejects(scrollToCentered(creeping.ctx, 'Card', phone), { message: 'scrollToCentered: Card is still out of place after 3 drags (centre y 820 of 874)' });
        assert.equal(creeping.swipes.length, 3);
    });

    it('refuses a band that does not fit the viewport', async () => {
        await assert.rejects(scrollToCentered(list({ y: 0 }).ctx, 'Card', { viewportHeight: 0 }), {
            message: 'scrollToCentered: viewportHeight must be positive and bottomBandPx inside it; got 0 and 0'
        });
        await assert.rejects(scrollToCentered(list({ y: 0 }).ctx, 'Card', { viewportHeight: 800, bottomBandPx: 800 }), /bottomBandPx inside it; got 800 and 800/);
    });
});

describe('scrollToMiddle', () => {
    const phone = { viewportHeight: 874 };

    it('leaves a node within the tolerance of the middle where it is', async () => {
        const { ctx, swipes } = list({ y: 540 });
        await scrollToMiddle(ctx, 'Card', phone);
        assert.deepEqual(swipes, []);
    });

    it('drags a node under a header down toward the middle: the bottom-band helper would leave it there', async () => {
        const { ctx, swipes, y } = list({ y: 30 });
        await scrollToMiddle(ctx, 'Card', phone);
        assert.deepEqual(swipes[0], { from: { x: 50, y: 437 }, to: { x: 50, y: 737 }, duration: 600 });
        assert.ok(Math.abs(y() + 20 - 437) < 150);
    });

    it('drags at most 300 at a time, up to three times', async () => {
        const { ctx, swipes, y } = list({ y: 1000 });
        await scrollToMiddle(ctx, 'Card', phone);
        assert.deepEqual(swipes.map(swipe => swipe.from.y - swipe.to.y), [300, 283]);
        assert.ok(Math.abs(y() + 20 - 437) < 150);
    });

    it('scrolls in the direction it is told, and stops when the list ends', async () => {
        const { ctx, node, scrolled, swipes } = list({ y: 800, up: 0 });
        node.isVisible = async () => false;
        await scrollToMiddle(ctx, 'Card', { ...phone, direction: 'up' });
        assert.deepEqual(scrolled, [{ direction: 'up', timeout: 20_000 }]);
        assert.equal(swipes.length, 1);
    });

    // budgie-at/budgie run 41791370019: the last row of a list, its centre read at 613.8, 615.2 and 621.8 of 874.
    it("leaves a node at a list's end where it is when the drag only made the list bounce", async () => {
        const centres = [613.8, 615.2, 621.8];
        const { ctx, node, swipes } = list({ y: 0 });
        node.boundingBox = async () => ({ x: 0, y: centres[swipes.length]! - 20, width: 100, height: 40 });
        await scrollToMiddle(ctx, 'Row', phone);
        assert.equal(swipes.length, 1);
    });

    it('counts a bounce by its share of the drag, whichever way it moved the node', async () => {
        for (const bounce of [-40, 40, -1, 60]) {
            const { ctx, node, swipes } = list({ y: 0 });
            // A 300 pt drag: a quarter of it is 75.
            node.boundingBox = async () => ({ x: 0, y: 800 + (swipes.length === 0 ? 0 : bounce), width: 100, height: 40 });
            await scrollToMiddle(ctx, 'Row', phone);
            assert.equal(swipes.length, 1, `bounce ${bounce}`);
        }
    });

    it('takes the tolerance, the longest drag and the x to drag at', async () => {
        const { ctx, swipes } = list({ y: 540, up: 0 });
        await scrollToMiddle(ctx, 'Card', { ...phone, tolerancePx: 50, maxDragPx: 40, dragX: 200 });
        assert.deepEqual(swipes[0], { from: { x: 200, y: 437 }, to: { x: 200, y: 397 }, duration: 600 });
    });

    it('fails closed when the node has no bounds', async () => {
        await assert.rejects(scrollToMiddle(list({ y: 0, box: false }).ctx, 'Card', phone), { message: 'scrollToMiddle: Card has no bounds' });
    });
});

describe('scrollAbove', () => {
    const footerAt = (y: number | null) => ({ boundingBox: async () => (y === null ? null : { x: 0, y, width: 400, height: 60 }) }) as unknown as Locator;

    it('leaves a node whose bottom edge is above the element where it is', async () => {
        const { ctx, swipes } = list({ y: 700 });
        await scrollAbove(ctx, 'Limit', footerAt(800));
        assert.deepEqual(swipes, []);
    });

    it('drags from above the element, since a drag that starts on a fixed footer moves nothing, until the node clears it', async () => {
        const { ctx, swipes, y } = list({ y: 790, overlayTop: 800 });
        await scrollAbove(ctx, 'Limit', footerAt(800));
        assert.deepEqual(swipes, [{ from: { x: 50, y: 650 }, to: { x: 50, y: 400 }, duration: 600 }]);
        assert.equal(y(), 540);
    });

    it('stops when the content ends, and takes the margin, the drag length and the x', async () => {
        const { ctx, swipes } = list({ y: 750, up: 0 });
        await scrollAbove(ctx, 'Limit', footerAt(800), { marginPx: 20, dragPx: 100, dragX: 200 });
        assert.deepEqual(swipes, [{ from: { x: 200, y: 650 }, to: { x: 200, y: 550 }, duration: 600 }]);
    });

    it('has nothing to clear when the element is not on screen', async () => {
        const { ctx, swipes } = list({ y: 790 });
        await scrollAbove(ctx, 'Limit', footerAt(null));
        assert.deepEqual(swipes, []);
    });

    it('fails closed when the node has no bounds', async () => {
        await assert.rejects(scrollAbove(list({ y: 0, box: false }).ctx, 'Limit', footerAt(800)), { message: 'scrollAbove: Limit has no bounds' });
    });
});

describe('retry', () => {
    it('runs the body once when it passes, handing it the attempt number', async () => {
        const seen: number[] = [];
        await retry(2, async attempt => void seen.push(attempt));
        assert.deepEqual(seen, [1]);
    });

    it('runs the body up to 1 + retries times, logging each failure, and rethrows the last', async t => {
        const log = t.mock.method(console, 'log', () => undefined);
        const seen: number[] = [];
        await assert.rejects(
            retry(2, async attempt => {
                seen.push(attempt);
                throw new Error(`failed ${attempt}\nstack detail`);
            }),
            /^Error: failed 3/
        );
        assert.deepEqual(seen, [1, 2, 3]);
        assert.deepEqual(log.mock.calls.map(call => call.arguments[0]), ['[retry] attempt 1 of 3 failed: failed 1', '[retry] attempt 2 of 3 failed: failed 2']);
    });

    it('stops at the first attempt that passes', async t => {
        t.mock.method(console, 'log', () => undefined);
        const seen: number[] = [];
        await retry(3, async attempt => {
            seen.push(attempt);
            if (attempt < 2) throw new Error('not yet');
        });
        assert.deepEqual(seen, [1, 2]);
    });

    it('refuses a retry count that is not a whole number', async () => {
        for (const retries of [-1, 1.5, Number.NaN]) {
            await assert.rejects(retry(retries, async () => undefined), { message: `retry: retries must be a whole number; got ${String(retries)}` });
        }
    });
});
