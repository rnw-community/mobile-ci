import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { byId, done, scrollTo, scrollToCentered, tapUntil } from '../src/steps.ts';

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

describe('scrollToCentered', () => {
    const screenWith = (node: ReturnType<typeof locator>) => {
        const swipes: unknown[] = [];
        const screen = {
            getByTestId: () => ({ first: () => node }),
            scrollUntilVisible: async () => undefined,
            swipe: async (options: unknown) => void swipes.push(options)
        } as unknown as Screen;
        return { ctx: { screen }, swipes };
    };

    it('leaves a node clear of the bottom band where it is', async () => {
        const { ctx, swipes } = screenWith(locator([true], [{ x: 0, y: 500, width: 100, height: 40 }]));
        await scrollToCentered(ctx, 'Card', { viewportHeight: 874, bottomBandPx: 314 });
        assert.deepEqual(swipes, []);
    });

    it('drags a node out of the bottom band to the middle of the viewport', async () => {
        const { ctx, swipes } = screenWith(locator([true], [{ x: 0, y: 700, width: 100, height: 40 }, { x: 0, y: 417, width: 100, height: 40 }]));
        await scrollToCentered(ctx, 'Card', { viewportHeight: 874, bottomBandPx: 314 });
        assert.deepEqual(swipes, [{ from: { x: 50, y: 720 }, to: { x: 50, y: 437 }, duration: 600 }]);
    });

    it('defaults the band to the bottom third of the viewport', async () => {
        const { ctx, swipes } = screenWith(locator([true], [{ x: 0, y: 620, width: 100, height: 20 }, { x: 0, y: 290, width: 100, height: 20 }]));
        // 630 lies below 900 - 900 / 3 = 600.
        await scrollToCentered(ctx, 'Card', { viewportHeight: 900 });
        assert.equal(swipes.length, 1);
    });

    it('fails closed when the node has no bounds, or cannot leave the band', async () => {
        await assert.rejects(scrollToCentered(screenWith(locator([true], [null])).ctx, 'Card', { viewportHeight: 874 }), {
            message: 'scrollToCentered: Card has no bounds'
        });
        await assert.rejects(scrollToCentered(screenWith(locator([true], [{ x: 0, y: 800, width: 100, height: 40 }])).ctx, 'Card', { viewportHeight: 874, bottomBandPx: 314 }), {
            message: 'scrollToCentered: Card is still in the bottom 314 px band (centre y 820 of 874); the content did not scroll'
        });
    });

    it('refuses a band that does not fit the viewport', async () => {
        await assert.rejects(scrollToCentered(screenWith(locator()).ctx, 'Card', { viewportHeight: 0 }), {
            message: 'scrollToCentered: viewportHeight must be positive and bottomBandPx inside it; got 0 and 0'
        });
        await assert.rejects(scrollToCentered(screenWith(locator()).ctx, 'Card', { viewportHeight: 800, bottomBandPx: 800 }), /bottomBandPx inside it; got 800 and 800/);
    });
});
