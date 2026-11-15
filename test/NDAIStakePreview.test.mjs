import test from "node:test";
import assert from "node:assert/strict";
import model from "../outputs/ndai-stake-preview.js";
const { applyPreview, demoState, formatAmount, parseAmount, quote } = model;

test("exact decimals and invalid amounts", () => {
  assert.equal(parseAmount("0.000000000000000001"), 1n);
  assert.equal(formatAmount(parseAmount("200.000000000000000001")), "200.000000000000000001");
  for (const invalid of ["", "0", "-1", "1e18", "1.0000000000000000001"]) {
    assert.throws(() => parseAmount(invalid));
  }
});

test("retirement reduces claims and debt and increases free position balance only", () => {
  const initial = demoState();
  const result = applyPreview(initial, quote(initial, "retire", "200"));
  assert.equal(formatAmount(result.claims), "250");
  assert.equal(formatAmount(result.debt), "120");
  assert.equal(formatAmount(result.free), "880");
  assert.equal(result.walletNdai, initial.walletNdai);
  assert.throws(() => quote({ ...initial, isOwner: false }, "retire", "1"), /position owner/);
  assert.throws(() => quote(initial, "retire", "321"), /position debt/);
  assert.throws(() => quote({ ...initial, claims: 1n }, "retire", "200"), /enough NEW/);
});

test("redemption starts at exact maturity and pays the holder directly", () => {
  const initial = demoState();
  assert.throws(() => quote({ ...initial, now: initial.maturity - 1 }, "redeem", "1"), /opens at/);
  for (const now of [initial.maturity, initial.maturity + 1]) {
    const mature = { ...initial, now, isOwner: false };
    const result = applyPreview(mature, quote(mature, "redeem", "200"));
    assert.equal(formatAmount(result.walletNdai), "225");
    assert.equal(formatAmount(result.claims), "250");
    assert.equal(result.free, initial.free);
    assert.equal(result.debt, initial.debt);
    assert.throws(() => quote({ ...mature, isOwner: true }, "retire", "1"), /closes at/);
  }
});

test("confirmation rechecks timing, balances and maturity", () => {
  const initial = demoState();
  const retirement = quote(initial, "retire", "200");
  assert.throws(() => applyPreview({ ...initial, now: initial.maturity }, retirement), /closes at/);
  assert.throws(() => applyPreview({ ...initial, claims: 0n }, retirement), /enough/);
  assert.throws(() => applyPreview({ ...initial, maturity: initial.maturity + 1 }, retirement), /updated redemption date/);
});

test("confirmation handlers display custody and update the correct balances", async () => {
  const { readFileSync } = await import("node:fs");
  const { runInNewContext } = await import("node:vm");
  const html = readFileSync(new URL("../outputs/NDAI-Stake-Preview.html", import.meta.url), "utf8");
  const elements = new Map([...html.matchAll(/ id="([^"]+)"/g)].map(([, id]) => {
    const button = {};
    const listeners = {};
    return [id, { value: id.endsWith("-amount") ? "200" : "", listeners, querySelector: () => button,
      addEventListener: (type, handler) => { listeners[type] = handler; } }];
  }));
  const el = (id) => {
    assert.ok(elements.has(id), "missing markup id " + id);
    return elements.get(id);
  };
  const dialog = { open: false, showModal() { this.open = true; }, close() { this.open = false; } };
  const inline = html.match(/<script>([\s\S]+)<\/script>/)[1];
  runInNewContext(inline, { window: { NdaiStakePreview: model },
    document: { getElementById: el, querySelector: () => dialog } });
  assert.ok(el("redeem").querySelector("button").disabled);
  el("retire").listeners.submit({ preventDefault() {} });
  assert.equal(dialog.open, true);
  assert.match(el("effect").textContent, /Burn 200 NEW.*free 200 NDAI inside your position/);
  assert.match(el("timing").textContent, /2027-03-25 08:00 UTC/);
  el("apply").listeners.click();
  assert.equal(el("free").textContent, "880");
  assert.equal(el("wallet").textContent, "25");
  el("clock").listeners.change({ target: { value: "at" } });
  assert.ok(el("retire").querySelector("button").disabled);
  el("redeem").listeners.submit({ preventDefault() {} });
  assert.match(el("effect").textContent, /Burn 200 NEW.*receive 200 NDAI in your wallet/);
  el("apply").listeners.click();
  assert.equal(el("wallet").textContent, "225");
  assert.equal(el("free").textContent, "880");
  assert.equal(el("claims").textContent, "50");
  assert.equal(dialog.open, false);
});
