// Runs the compiled budget logic (src/budget.dart.js) against a fake Google
// Drive holding a made-up synced budget: a read, a write, and the write
// read back. `npm run smoke` builds both first.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fakeDrive } from "./fake-drive.mjs";

const fixture = JSON.parse(readFileSync(new URL("./.fixture.json", import.meta.url), "utf8"));
const drive = fakeDrive(fixture.files);
globalThis.fetch = drive.fetch;
await import("../src/prelude.js");
await import("../src/budget.dart.js");

const config = { pairingCode: fixture.pairingCode, mode: "read-write" };
const ask = async (request) =>
  JSON.parse(await globalThis.budgetMcp(JSON.stringify({ config, accessToken: "test-token", ...request })));
const call = async (name, args, client = "Smoke") => {
  const answer = await ask({ method: "call", name, client, arguments: { budgetId: fixture.budgetId, ...args } });
  return { ...answer, body: JSON.parse(answer.text) };
};

const { tools } = await ask({ method: "list" });
const names = tools.map((tool) => tool.name);
assert.ok(names.includes("list_accounts"));
assert.ok(names.includes("suggest_review"));
assert.ok(!names.some((name) => name.startsWith("delete") || name === "mark_reviewed"));

const accounts = await call("list_accounts", {});
assert.equal(accounts.isError, false, accounts.text);
assert.equal(accounts.body.accounts.length, 1);

const suggestion = await call("suggest_review", {
  transactionId: fixture.transactionId,
  lineId: fixture.lineId,
  categoryId: fixture.categoryId,
});
assert.equal(suggestion.isError, false, suggestion.text);
assert.equal(suggestion.body.actor, "mcp:Smoke");

const unreviewed = await call("list_unreviewed", {});
assert.equal(unreviewed.body.lines.length, 1, "the line stays Unreviewed");
assert.equal(unreviewed.body.lines[0].needs, "businessStatus", "its Category came back from Drive");

const refused = await call("assign", { categoryId: fixture.categoryId, amountCents: 100 });
assert.equal(refused.isError, true);

console.log("smoke: ok");
