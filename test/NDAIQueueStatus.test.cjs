const test = require("node:test");
const assert = require("node:assert/strict");

function evaluate({ timestamp, blockedSince, lastProgress, fresh = true }) {
    if (!fresh) return { status: "unavailable", backup: false };
    if (blockedSince === null) return { status: "ready", backup: false };
    const stalled = timestamp - Math.max(blockedSince, lastProgress ?? blockedSince) >= 32;
    return { status: stalled ? "stalled" : "catching up", backup: stalled };
}

function observeSync(state, timestamp, processedKeys) {
    return { ...state, timestamp, lastProgress: processedKeys > 0 ? timestamp : state.lastProgress };
}

const start = { timestamp: 100, blockedSince: 100, lastProgress: null };

test("pending or dropped sync does not defer backup handoff", () => {
    assert.deepEqual(evaluate({ ...start, timestamp: 131 }), { status: "catching up", backup: false });
    assert.deepEqual(evaluate({ ...start, timestamp: 132 }), { status: "stalled", backup: true });
});

test("delayed inclusion resets the timer only after confirmed progress", () => {
    const delayed = { ...start, timestamp: 138 };
    assert.equal(evaluate(delayed).backup, true);
    const progressed = observeSync(delayed, 140, 32);
    assert.equal(evaluate(progressed).status, "catching up");
    assert.equal(evaluate({ ...progressed, timestamp: 171 }).backup, false);
    assert.equal(evaluate({ ...progressed, timestamp: 172 }).backup, true);
});

test("a successful zero-key sync preserves the last progress timestamp", () => {
    const stalled = observeSync({ ...start, lastProgress: 104 }, 136, 0);
    assert.equal(stalled.lastProgress, 104);
    assert.deepEqual(evaluate(stalled), { status: "stalled", backup: true });
});

test("confirmed recovery clears stall and a new blocked period starts a new timer", () => {
    assert.deepEqual(evaluate({ ...start, timestamp: 140, blockedSince: null }), { status: "ready", backup: false });
    assert.equal(evaluate({ ...start, timestamp: 171, blockedSince: 150 }).status, "catching up");
});

test("stale data does not trigger dispatch based on an unverified queue", () => {
    assert.deepEqual(evaluate({ ...start, timestamp: 200, fresh: false }), { status: "unavailable", backup: false });
});

function observeCanonical(history, block) {
    if (!block.fresh) return evaluate({ fresh: false });
    const parent = history.get(block.parentHash);
    if (!parent && history.size !== 0) return evaluate({ fresh: false });
    const blocked = block.due > 32;
    const state = {
        timestamp: block.timestamp,
        blockedSince: blocked ? parent?.blockedSince ?? block.timestamp : null,
        lastProgress: block.processed > 0 ? block.timestamp : parent?.lastProgress,
    };
    history.set(block.hash, state);
    return evaluate(state);
}

test("only overdue and exactly due keys count toward the inline limit", () => {
    const history = new Map();
    const timestamp = 100;
    const activations = [...Array(32).fill(99), 100, ...Array(100).fill(101)];
    // Individual deposits coalesce into unique activation keys.
    const dueKeys = [...new Set(activations)].filter((at) => at <= timestamp).length;
    assert.equal(dueKeys, 2);
    assert.equal(observeCanonical(history, { hash: "a", timestamp, due: dueKeys, fresh: true }).status, "ready");
    assert.equal(observeCanonical(history, { hash: "b", parentHash: "a", timestamp: 101, due: 33, fresh: true }).status, "catching up");
});

test("replacing a progress block restores the previous stall timer", () => {
    const history = new Map();
    observeCanonical(history, { hash: "a", timestamp: 100, due: 64, fresh: true });
    const progress = observeCanonical(history, { hash: "b", parentHash: "a", timestamp: 132, due: 32, processed: 32, fresh: true });
    assert.equal(progress.status, "ready");
    const replacement = observeCanonical(history, { hash: "c", parentHash: "a", timestamp: 132, due: 64, processed: 0, fresh: true });
    assert.deepEqual(replacement, { status: "stalled", backup: true });
    assert.equal(observeCanonical(history, { hash: "d", parentHash: "missing", timestamp: 133, due: 64, fresh: true }).status, "unavailable");
    assert.equal(observeCanonical(history, { hash: "e", parentHash: "c", timestamp: 134, due: 64, fresh: false }).status, "unavailable");
});
