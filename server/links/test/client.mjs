// A small client for the link service, the same format the apps use (FORMAT.md). Used by
// the tests, and handy by hand:
//   node test/client.mjs <service url> <token> <file>
import { readFile } from "node:fs/promises";
import { webcrypto as crypto } from "node:crypto";
import { basename } from "node:path";

export const CHUNK = 8 * 1024 * 1024;
export const TAG = 16;

export function chunkNonce(i, last) {
  const n = new Uint8Array(12);
  n[0] = last ? 1 : 0;
  new DataView(n.buffer).setBigUint64(4, BigInt(i));
  return n;
}

export const metaNonce = () => Uint8Array.from([255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0]);

export const b64url = (bytes) => Buffer.from(bytes).toString("base64url");

export async function seal(rawKey, data, nonce) {
  const key = await crypto.subtle.importKey("raw", rawKey, "AES-GCM", false, ["encrypt"]);
  return new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, data));
}

export async function upload(service, token, name, data, type = "application/octet-stream", rawKey) {
  rawKey ??= crypto.getRandomValues(new Uint8Array(32));
  const count = Math.max(1, Math.ceil(data.length / CHUNK));
  const total = data.length + count * TAG;
  const meta = await seal(rawKey, new TextEncoder().encode(JSON.stringify({ name, size: data.length, type })), metaNonce());
  const auth = { authorization: `Bearer ${token}` };
  let response = await fetch(`${service}/api/links`, {
    method: "POST", headers: { ...auth, "content-type": "application/json" },
    body: JSON.stringify({ size: total, parts: count, meta: Buffer.from(meta).toString("base64") }),
  });
  if (response.status !== 201) throw new Error(`create: ${response.status} ${await response.text()}`);
  const link = await response.json();
  const parts = [];
  for (let i = 0; i < count; i++) {
    const sealed = await seal(rawKey, data.subarray(i * CHUNK, (i + 1) * CHUNK), chunkNonce(i, i === count - 1));
    response = await fetch(`${service}/api/links/${link.id}/parts/${i + 1}`, { method: "PUT", headers: auth, body: sealed });
    if (!response.ok) throw new Error(`part ${i + 1}: ${response.status} ${await response.text()}`);
    parts.push(await response.json());
  }
  response = await fetch(`${service}/api/links/${link.id}/complete`, {
    method: "POST", headers: { ...auth, "content-type": "application/json" }, body: JSON.stringify({ parts }),
  });
  if (!response.ok) throw new Error(`complete: ${response.status} ${await response.text()}`);
  return { ...link, share: `${link.url}#${b64url(rawKey)}` };
}

if (process.argv[1] && import.meta.url.endsWith(basename(process.argv[1]))) {
  const [service, token, file] = process.argv.slice(2);
  const link = await upload(service, token, basename(file), await readFile(file));
  console.log(link.share);
  console.log(`delete: curl -X DELETE -H 'x-delete-token: ${link.deleteToken}' ${service}/api/links/${link.id}`);
}
