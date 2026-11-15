(function () {
const UNIT = 10n ** 18n;
const TICKER = "NEW";

function parseAmount(text) {
  const match = /^(\d+)(?:\.(\d{1,18}))?$/.exec(text.trim());
  if (!match) throw new Error("Enter an amount with up to 18 decimal places.");
  const amount = BigInt(match[1]) * UNIT + BigInt((match[2] ?? "").padEnd(18, "0"));
  if (amount === 0n) throw new Error("Enter an amount greater than zero.");
  return amount;
}

function formatAmount(amount) {
  const whole = amount / UNIT;
  const fraction = (amount % UNIT).toString().padStart(18, "0").replace(/0+$/, "");
  return fraction ? whole + "." + fraction : whole.toString();
}

function quote(state, action, text) {
  const amount = parseAmount(text);
  if (action === "retire") {
    if (state.now >= state.maturity) throw new Error("Debt retirement closes at redemption.");
    if (!state.isOwner) throw new Error("Only the position owner can retire debt.");
    if (amount > state.debt) throw new Error("This amount exceeds your position debt.");
  } else if (action === "redeem") {
    if (state.now < state.maturity) throw new Error("Redemption opens at the UTC maturity shown.");
  } else {
    throw new Error("Choose an action.");
  }
  if (amount > state.claims) throw new Error("You don’t have enough " + TICKER + ".");
  return { action, amount, maturity: state.maturity };
}

function applyPreview(state, preview) {
  const verified = quote(state, preview.action, formatAmount(preview.amount));
  if (verified.maturity !== preview.maturity) throw new Error("Review the updated redemption date.");
  const updated = { ...state, claims: state.claims - verified.amount };
  if (verified.action === "retire") {
    updated.debt -= verified.amount;
    updated.free += verified.amount;
  } else {
    updated.walletNdai += verified.amount;
  }
  return updated;
}

function demoState() {
  const maturity = Date.parse("2027-03-25T08:00:00Z");
  return {
    maturity,
    now: maturity - 86400000,
    isOwner: true,
    claims: 450n * UNIT,
    debt: 320n * UNIT,
    free: 680n * UNIT,
    walletNdai: 25n * UNIT,
  };
}

const api = { applyPreview, demoState, quote, parseAmount, formatAmount, TICKER };
if (typeof module !== 'undefined') module.exports = api;
else window.NdaiStakePreview = api;
})();
