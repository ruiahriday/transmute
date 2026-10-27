// Tests against a running service (`npx wrangler dev --local --test-scheduled`, with
// UPLOAD_TOKENS=test-token in .dev.vars):
//   SERVICE=http://localhost:8787 node test/run.mjs
// With PLAYWRIGHT=1 it also downloads through the real page in Chromium, with and without
// the service worker.
import assert from "node:assert/strict";
import { webcrypto as crypto } from "node:crypto";
import { upload, seal, chunkNonce, metaNonce, CHUNK, TAG, b64url } from "./client.mjs";

const service = process.env.SERVICE || "http://localhost:8787";
const token = process.env.TOKEN || "test-token";
let passed = 0;

async function check(name, body) {
  try {
    await body();
    passed++;
    console.log("ok  ", name);
  } catch (error) {
    console.log("FAIL", name, "\n    ", error.message);
    process.exitCode = 1;
  }
}

async function open(rawKey, sealed, nonce) {
  const key = await crypto.subtle.importKey("raw", rawKey, "AES-GCM", false, ["decrypt"]);
  return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce }, key, sealed));
}

const keyOf = (share) => new Uint8Array(Buffer.from(share.split("#")[1], "base64url"));

await check("test vector matches FORMAT.md", async () => {
  const key = Uint8Array.from({ length: 32 }, (_, i) => i);
  const text = new TextEncoder().encode("Spinform");
  assert.equal(Buffer.from(await seal(key, text, chunkNonce(0, true))).toString("hex"), "b15ceb51c2c09e6a25bed4a095a883ff5d4a73a241d0e2d1");
  assert.equal(Buffer.from(await seal(key, text, chunkNonce(1, false))).toString("hex"), "46a6d692229b4273c0ec8d676e77d010a6c642928d1ddcd4");
});

await check("creating a link needs a token", async () => {
  const r = await fetch(`${service}/api/links`, { method: "POST", body: JSON.stringify({ size: 16, parts: 1, meta: "AA" }) });
  assert.equal(r.status, 401);
  const r2 = await fetch(`${service}/api/links`, { method: "POST", headers: { authorization: "Bearer nope" }, body: "{}" });
  assert.equal(r2.status, 401);
});

await check("sizes over the limit are refused", async () => {
  const size = 5368709120 + 2000;
  const parts = Math.ceil(size / CHUNK);
  const r = await fetch(`${service}/api/links`, {
    method: "POST", headers: { authorization: `Bearer ${token}` },
    body: JSON.stringify({ size: size + parts * TAG, parts, meta: "AAAA" }),
  });
  assert.equal(r.status, 413);
});

await check("parts must match the size", async () => {
  const r = await fetch(`${service}/api/links`, {
    method: "POST", headers: { authorization: `Bearer ${token}` },
    body: JSON.stringify({ size: 100, parts: 2, meta: "AAAA" }),
  });
  assert.equal(r.status, 400);
});

let small;
const smallData = new TextEncoder().encode("Hello from Spinform, a small file. ü 🎉");
await check("a small file round-trips", async () => {
  small = await upload(service, token, "hello wörld.txt", smallData, "text/plain");
  assert.match(small.share, /\/l\/[A-Za-z0-9]{10}#[A-Za-z0-9_-]{43}$/);
  const info = await (await fetch(`${service}/api/links/${small.id}`)).json();
  assert.equal(info.size, smallData.length + TAG);
  const meta = JSON.parse(new TextDecoder().decode(await open(keyOf(small.share), Buffer.from(info.meta, "base64"), metaNonce())));
  assert.deepEqual(meta, { name: "hello wörld.txt", size: smallData.length, type: "text/plain" });
  const sealed = new Uint8Array(await (await fetch(`${service}/api/links/${small.id}/data`)).arrayBuffer());
  assert.deepEqual(await open(keyOf(small.share), sealed, chunkNonce(0, true)), smallData);
});

await check("the server only sees ciphertext", async () => {
  const sealed = Buffer.from(await (await fetch(`${service}/api/links/${small.id}/data`)).arrayBuffer());
  assert.equal(sealed.includes(Buffer.from("Spinform")), false);
  const info = await (await fetch(`${service}/api/links/${small.id}`)).text();
  assert.equal(info.includes("hello"), false);
});

await check("the wrong last-chunk flag doesn't decrypt (no truncation)", async () => {
  const sealed = new Uint8Array(await (await fetch(`${service}/api/links/${small.id}/data`)).arrayBuffer());
  await assert.rejects(open(keyOf(small.share), sealed, chunkNonce(0, false)));
});

let big;
const bigData = new Uint8Array(2 * CHUNK + 12345).map((_, i) => (i * 7 + (i >> 13)) & 255);
await check("a 16 MB file in three parts round-trips with ranges", async () => {
  big = await upload(service, token, "video.mov", bigData, "video/quicktime");
  const info = await (await fetch(`${service}/api/links/${big.id}`)).json();
  assert.equal(info.parts, 3);
  const out = [];
  for (let i = 0; i < 3; i++) {
    const from = i * (CHUNK + TAG);
    const to = Math.min(info.size, from + CHUNK + TAG) - 1;
    const r = await fetch(`${service}/api/links/${big.id}/data`, { headers: { range: `bytes=${from}-${to}` } });
    assert.equal(r.status, 206);
    assert.equal(r.headers.get("content-range"), `bytes ${from}-${to}/${info.size}`);
    out.push(await open(keyOf(big.share), new Uint8Array(await r.arrayBuffer()), chunkNonce(i, i === 2)));
  }
  assert.deepEqual(Buffer.concat(out), Buffer.from(bigData));
});

await check("bad ranges get 416", async () => {
  const r = await fetch(`${service}/api/links/${small.id}/data`, { headers: { range: "bytes=999999-" } });
  assert.equal(r.status, 416);
});

await check("a part of the wrong size is refused", async () => {
  const r = await fetch(`${service}/api/links`, {
    method: "POST", headers: { authorization: `Bearer ${token}` },
    body: JSON.stringify({ size: CHUNK + TAG + 100, parts: 2, meta: "AAAA" }),
  });
  const link = await r.json();
  const bad = await fetch(`${service}/api/links/${link.id}/parts/1`, {
    method: "PUT", headers: { authorization: `Bearer ${token}` }, body: new Uint8Array(100),
  });
  assert.equal(bad.status, 400);
  // Not finished, so it can't be downloaded yet.
  assert.equal((await fetch(`${service}/api/links/${link.id}`)).status, 404);
});

await check("another token can't upload into someone's link", async () => {
  const r = await fetch(`${service}/api/links`, {
    method: "POST", headers: { authorization: `Bearer ${token}` },
    body: JSON.stringify({ size: 116, parts: 1, meta: "AAAA" }),
  });
  const link = await r.json();
  const other = await fetch(`${service}/api/links/${link.id}/parts/1`, {
    method: "PUT", headers: { authorization: "Bearer other" }, body: new Uint8Array(116),
  });
  assert.equal(other.status, 404);
});

await check("the download page and service worker are served", async () => {
  const page = await fetch(`${service}/l/${small.id}`);
  assert.equal(page.status, 200);
  assert.match(page.headers.get("content-security-policy"), /frame-ancestors 'none'/);
  assert.match(await page.text(), /Report this link/);
  const sw = await fetch(`${service}/sw.js`);
  assert.match(sw.headers.get("content-type"), /javascript/);
});

if (process.env.PLAYWRIGHT) {
  const playwright = await import(process.env.PLAYWRIGHT_PATH || "playwright");
  const { chromium } = playwright.default ?? playwright;
  const browser = await chromium.launch();
  for (const serviceWorkers of ["allow", "block"]) {
    await check(`the page downloads and decrypts (service worker ${serviceWorkers})`, async () => {
      const context = await browser.newContext({ acceptDownloads: true, serviceWorkers });
      const page = await context.newPage();
      page.on("console", (m) => m.type() === "error" && console.log("     console:", m.text()));
      await page.goto(big.share);
      await page.waitForFunction(() => !document.getElementById("download").disabled);
      assert.equal(await page.textContent("#name"), "video.mov");
      assert.match(await page.textContent("#details"), /^17 MB · available until/);
      if (process.env.SHOT) await page.screenshot({ path: `${process.env.SHOT}-${serviceWorkers}.png` });
      const [download] = await Promise.all([page.waitForEvent("download", { timeout: 30000 }), page.click("#download")]);
      assert.equal(download.suggestedFilename(), "video.mov");
      const path = await download.path();
      const { readFile } = await import("node:fs/promises");
      assert.deepEqual(await readFile(path), Buffer.from(bigData));
      await context.close();
    });
  }
  await check("a link with a damaged key says so", async () => {
    const page = await browser.newPage();
    await page.goto(small.share.slice(0, -4) + "AAAA");
    await page.waitForFunction(() => document.getElementById("name").textContent !== "Opening…");
    assert.equal(await page.textContent("#name"), "Can't open this link");
    if (process.env.SHOT) await page.screenshot({ path: `${process.env.SHOT}-error.png` });
    await page.close();
  });
  await browser.close();
}

await check("deleting needs the delete token, then the link is gone", async () => {
  const wrong = await fetch(`${service}/api/links/${small.id}`, { method: "DELETE", headers: { "x-delete-token": "nope" } });
  assert.equal(wrong.status, 404);
  const right = await fetch(`${service}/api/links/${small.id}`, { method: "DELETE", headers: { "x-delete-token": small.deleteToken } });
  assert.equal(right.status, 200);
  assert.equal((await fetch(`${service}/api/links/${small.id}`)).status, 404);
  assert.equal((await fetch(`${service}/api/links/${small.id}/data`)).status, 404);
});

if (process.env.EXPIRY_SERVICE) {
  // A second instance started with LINK_DAYS tiny, so links expire within a second.
  await check("expired links stop working and the hourly sweep deletes them", async () => {
    const link = await upload(process.env.EXPIRY_SERVICE, token, "old.txt", smallData);
    await new Promise((r) => setTimeout(r, 1500));
    assert.equal((await fetch(`${process.env.EXPIRY_SERVICE}/api/links/${link.id}`)).status, 404);
    await fetch(`${process.env.EXPIRY_SERVICE}/__scheduled?cron=17+*+*+*+*`);
    const del = await fetch(`${process.env.EXPIRY_SERVICE}/api/links/${link.id}`, { method: "DELETE", headers: { "x-delete-token": link.deleteToken } });
    assert.equal(del.status, 404, "the record should already be gone");
  });
}

console.log(`\n${passed} passed${process.exitCode ? ", some FAILED" : ""}`);
