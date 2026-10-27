// Spinform links: holds the encrypted files behind "Create link" links for a few days.
//
// The app encrypts every file before it uploads it (see FORMAT.md), so this service only
// ever sees ciphertext: the key is in the part of the link after "#", which browsers never
// send to a server. A link is two R2 objects:
//   links/<id>/meta  JSON: expiry, sizes, the encrypted file name, a hash of the delete token
//   links/<id>/data  the encrypted file, uploaded in parts (R2 multipart upload)
//
// API (all JSON):
//   POST   /api/links                      create a link: { size, parts, meta } → { id, url, deleteToken, expires, partSize }
//   PUT    /api/links/:id/parts/:n         upload part n (1-based) → { etag }
//   POST   /api/links/:id/complete         { parts: [{ partNumber, etag }] } → { url, expires }
//   GET    /api/links/:id                  what the download page needs
//   GET    /api/links/:id/data             the encrypted file (Range requests work)
//   DELETE /api/links/:id                  header X-Delete-Token
// Creating and uploading need "Authorization: Bearer <app token>".

import { PAGE_HTML, SERVICE_WORKER_JS, HOME_HTML } from "./page.js";

// Must match the apps: 8 MiB of the file per encrypted chunk, plus a 16-byte tag.
const CHUNK = 8 * 1024 * 1024;
const TAG = 16;
const PART = CHUNK + TAG;
const ID_ALPHABET = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (error) {
      if (error instanceof HttpError) return json({ error: error.message }, error.status);
      console.error(error);
      return json({ error: "Something went wrong on our side." }, 500);
    }
  },

  async scheduled(_event, env) {
    await sweep(env, Date.now());
  },
};

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function route(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;
  let m;

  if (method === "GET" && path === "/") return html(HOME_HTML);
  if (method === "GET" && path === "/sw.js") {
    return new Response(SERVICE_WORKER_JS, {
      headers: { "content-type": "text/javascript; charset=utf-8", "cache-control": "no-cache" },
    });
  }
  if (method === "GET" && (m = path.match(/^\/l\/([A-Za-z0-9]{6,32})\/?$/))) {
    return html(PAGE_HTML.replaceAll("{{ABUSE_EMAIL}}", escapeHTML(env.ABUSE_EMAIL || "")));
  }

  if (method === "POST" && path === "/api/links") return create(request, env, url);
  if ((m = path.match(/^\/api\/links\/([A-Za-z0-9]{6,32})(\/.*)?$/))) {
    const id = m[1];
    const rest = m[2] || "";
    let pm;
    if (method === "PUT" && (pm = rest.match(/^\/parts\/(\d{1,5})$/))) return uploadPart(request, env, id, Number(pm[1]));
    if (method === "POST" && rest === "/complete") return complete(request, env, id, url);
    if (method === "GET" && rest === "") return info(env, id);
    if ((method === "GET" || method === "HEAD") && rest === "/data") return data(request, env, id);
    if (method === "DELETE" && rest === "") return remove(request, env, id);
  }
  throw new HttpError(404, "Not found.");
}

// MARK: Creating and uploading

async function create(request, env, url) {
  const tokenHash = await authorize(request, env);
  const body = await readJSON(request, 64 * 1024);
  const size = body.size;
  const parts = body.parts;
  const max = Number(env.MAX_BYTES || 5368709120);
  if (!Number.isSafeInteger(size) || size < TAG) throw new HttpError(400, "size is missing.");
  if (!Number.isSafeInteger(parts) || parts !== Math.max(1, Math.ceil(size / PART))) {
    throw new HttpError(400, "parts doesn't match size.");
  }
  if (size - parts * TAG > max) throw new HttpError(413, `Links can hold up to ${formatBytes(max)}.`);
  if (typeof body.meta !== "string" || body.meta.length > 8192 || !/^[A-Za-z0-9+/=_-]+$/.test(body.meta)) {
    throw new HttpError(400, "meta is missing.");
  }

  await spendQuota(env, tokenHash, size);

  const id = randomID(10);
  const deleteToken = base64url(crypto.getRandomValues(new Uint8Array(24)));
  const now = Date.now();
  const expires = now + Number(env.LINK_DAYS || 7) * 86400_000;
  const upload = await env.BUCKET.createMultipartUpload(`links/${id}/data`);
  const record = {
    v: 1, created: now, expires, size, parts, meta: body.meta, ready: false,
    uploadId: upload.uploadId, tokenHash, deleteHash: await sha256(deleteToken),
  };
  await putRecord(env, id, record);
  return json({ id, url: `${url.origin}/l/${id}`, deleteToken, expires: new Date(expires).toISOString(), partSize: PART }, 201);
}

async function uploadPart(request, env, id, n) {
  const tokenHash = await authorize(request, env);
  const record = await getRecord(env, id);
  if (!record || record.tokenHash !== tokenHash) throw new HttpError(404, "Not found.");
  if (record.ready) throw new HttpError(409, "This link is already complete.");
  if (n < 1 || n > record.parts) throw new HttpError(400, "Part number out of range.");
  const expected = n < record.parts ? PART : record.size - (record.parts - 1) * PART;
  const length = Number(request.headers.get("content-length"));
  if (length !== expected) throw new HttpError(400, `Part ${n} should be ${expected} bytes.`);
  const upload = env.BUCKET.resumeMultipartUpload(`links/${id}/data`, record.uploadId);
  const part = await upload.uploadPart(n, request.body);
  return json({ partNumber: n, etag: part.etag });
}

async function complete(request, env, id, url) {
  const tokenHash = await authorize(request, env);
  const record = await getRecord(env, id);
  if (!record || record.tokenHash !== tokenHash) throw new HttpError(404, "Not found.");
  if (!record.ready) {
    const body = await readJSON(request, 1024 * 1024);
    const parts = Array.isArray(body.parts) ? body.parts : [];
    if (parts.length !== record.parts) throw new HttpError(400, `Expected ${record.parts} parts.`);
    const list = parts
      .map((p) => ({ partNumber: Number(p.partNumber), etag: String(p.etag) }))
      .sort((a, b) => a.partNumber - b.partNumber);
    const upload = env.BUCKET.resumeMultipartUpload(`links/${id}/data`, record.uploadId);
    const object = await upload.complete(list);
    if (object.size !== record.size) {
      await env.BUCKET.delete(`links/${id}/data`);
      throw new HttpError(400, "The uploaded size doesn't match.");
    }
    record.ready = true;
    delete record.uploadId;
    await putRecord(env, id, record);
  }
  return json({ url: `${url.origin}/l/${id}`, expires: new Date(record.expires).toISOString() });
}

// MARK: Downloading

async function info(env, id) {
  const record = await liveRecord(env, id);
  return json({
    v: record.v, size: record.size, parts: record.parts, meta: record.meta,
    chunk: CHUNK, expires: new Date(record.expires).toISOString(),
  }, 200, { "cache-control": "no-store" });
}

async function data(request, env, id) {
  const record = await liveRecord(env, id);
  const range = parseRange(request.headers.get("range"), record.size);
  if (range === "bad") {
    return new Response(null, { status: 416, headers: { "content-range": `bytes */${record.size}` } });
  }
  const headers = {
    "content-type": "application/octet-stream",
    "accept-ranges": "bytes",
    "cache-control": "private, no-store",
  };
  if (request.method === "HEAD") return new Response(null, { headers: { ...headers, "content-length": String(record.size) } });
  const object = await env.BUCKET.get(`links/${id}/data`, range ? { range } : {});
  if (!object) throw new HttpError(404, "This link has expired or was deleted.");
  if (!range) return new Response(object.body, { headers: { ...headers, "content-length": String(record.size) } });
  const end = range.offset + range.length - 1;
  return new Response(object.body, {
    status: 206,
    headers: { ...headers, "content-length": String(range.length), "content-range": `bytes ${range.offset}-${end}/${record.size}` },
  });
}

/// A "bytes=a-b" header as R2's { offset, length }; null for none, "bad" when it can't be met.
function parseRange(header, size) {
  if (!header) return null;
  const m = header.match(/^bytes=(\d*)-(\d*)$/);
  if (!m || (m[1] === "" && m[2] === "")) return "bad";
  let start, end;
  if (m[1] === "") {
    const suffix = Number(m[2]);
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(m[1]);
    end = m[2] === "" ? size - 1 : Math.min(Number(m[2]), size - 1);
  }
  if (start >= size || end < start) return "bad";
  return { offset: start, length: end - start + 1 };
}

// MARK: Deleting

async function remove(request, env, id) {
  const record = await getRecord(env, id);
  const token = request.headers.get("x-delete-token") || "";
  if (!record || !token || (await sha256(token)) !== record.deleteHash) throw new HttpError(404, "Not found.");
  await destroy(env, id, record);
  return json({ deleted: true });
}

async function destroy(env, id, record) {
  if (record && record.uploadId) {
    try {
      await env.BUCKET.resumeMultipartUpload(`links/${id}/data`, record.uploadId).abort();
    } catch (_) {
      // Already completed or aborted.
    }
  }
  await env.BUCKET.delete([`links/${id}/data`, `links/${id}/meta`]);
}

/// Deletes expired links, and uploads that never finished within a day.
async function sweep(env, now) {
  let cursor;
  let removed = 0;
  do {
    const page = await env.BUCKET.list({ prefix: "links/", include: ["customMetadata"], cursor });
    for (const object of page.objects) {
      if (!object.key.endsWith("/meta")) continue;
      const expires = Number(object.customMetadata?.expires || 0);
      const created = Number(object.customMetadata?.created || 0);
      const stale = object.customMetadata?.ready !== "1" && now - created > 86400_000;
      if (now > expires || stale) {
        const id = object.key.split("/")[1];
        await destroy(env, id, await getRecord(env, id));
        removed++;
      }
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);

  // Old quota counters.
  const quotas = await env.BUCKET.list({ prefix: "quota/" });
  const old = quotas.objects.map((o) => o.key).filter((key) => key.split("/")[2] < day(now - 86400_000));
  if (old.length) await env.BUCKET.delete(old.slice(0, 1000));
  return removed;
}

// MARK: Records

async function getRecord(env, id) {
  const object = await env.BUCKET.get(`links/${id}/meta`);
  return object ? object.json() : null;
}

async function putRecord(env, id, record) {
  await env.BUCKET.put(`links/${id}/meta`, JSON.stringify(record), {
    httpMetadata: { contentType: "application/json" },
    customMetadata: { expires: String(record.expires), created: String(record.created), ready: record.ready ? "1" : "0" },
  });
}

async function liveRecord(env, id) {
  const record = await getRecord(env, id);
  if (!record || !record.ready || Date.now() > record.expires) {
    throw new HttpError(404, "This link has expired or was deleted.");
  }
  return record;
}

// MARK: Tokens and quota

async function authorize(request, env) {
  const header = request.headers.get("authorization") || "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  const allowed = (env.UPLOAD_TOKENS || "").split(",").map((t) => t.trim()).filter(Boolean);
  if (!token || allowed.length === 0) throw new HttpError(401, "This copy of Spinform can't create links.");
  const hash = await sha256(token);
  for (const t of allowed) {
    if ((await sha256(t)) === hash) return hash;
  }
  throw new HttpError(401, "This copy of Spinform can't create links.");
}

async function spendQuota(env, tokenHash, bytes) {
  const limit = Number(env.DAILY_BYTES || 21474836480);
  const key = `quota/${tokenHash.slice(0, 32)}/${day(Date.now())}`;
  const object = await env.BUCKET.get(key);
  const used = object ? Number(await object.text()) || 0 : 0;
  if (used + bytes > limit) {
    throw new HttpError(429, `You've reached today's limit of ${formatBytes(limit)} of links. Try again tomorrow.`);
  }
  await env.BUCKET.put(key, String(used + bytes));
}

// MARK: Helpers

function day(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

function randomID(length) {
  const bytes = crypto.getRandomValues(new Uint8Array(length * 2));
  let out = "";
  for (const b of bytes) {
    // Rejection sampling keeps every letter equally likely.
    if (b < 256 - (256 % ID_ALPHABET.length)) out += ID_ALPHABET[b % ID_ALPHABET.length];
    if (out.length === length) return out;
  }
  return out + randomID(length - out.length);
}

function base64url(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function readJSON(request, limit) {
  const text = await request.text();
  if (text.length > limit) throw new HttpError(413, "Request too large.");
  try {
    const value = JSON.parse(text);
    if (value && typeof value === "object") return value;
  } catch (_) {}
  throw new HttpError(400, "Expected JSON.");
}

function formatBytes(n) {
  return n >= 1e9 ? `${Math.round(n / 1e8) / 10} GB` : `${Math.round(n / 1e5) / 10} MB`;
}

function escapeHTML(s) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

function json(value, status = 200, headers = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}

function html(body) {
  return new Response(body, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-cache",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
      "content-security-policy": "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'",
    },
  });
}
