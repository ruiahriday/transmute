// The pages the link service serves: the download page a link opens, its service worker
// (which decrypts while the browser saves, so even a 5 GB file never sits in memory), and
// a short home page.

const STYLE = `
:root { color-scheme: light dark; --bg: #f5f5f7; --card: #fff; --text: #1d1d1f; --muted: #6e6e73;
  --line: rgba(0,0,0,.1); --accent: #0a66d8; --accent-text: #fff; --bad: #c4321c; }
@media (prefers-color-scheme: dark) { :root { --bg: #161618; --card: #232326; --text: #f5f5f7;
  --muted: #a1a1a6; --line: rgba(255,255,255,.12); --accent: #3b8cff; --bad: #ff6b55; } }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 24px 16px;
  background: var(--bg); color: var(--text); font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
main { width: 100%; max-width: 420px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 28px 24px; }
.brand { display: flex; align-items: center; gap: 8px; font-weight: 600; margin-bottom: 22px; color: var(--muted); font-size: 13px; letter-spacing: .02em; }
.brand i { width: 18px; height: 18px; border-radius: 50%; border: 3px solid var(--accent); border-right-color: transparent; display: inline-block; }
h1 { font-size: 20px; line-height: 1.3; margin: 0 0 4px; word-break: break-word; }
.sub { color: var(--muted); margin: 0 0 22px; font-size: 14px; }
button, .button { display: block; width: 100%; padding: 12px 16px; border: 0; border-radius: 10px; background: var(--accent);
  color: var(--accent-text); font: inherit; font-weight: 600; cursor: pointer; text-align: center; text-decoration: none; }
button:disabled { opacity: .55; cursor: default; }
.bar { height: 6px; border-radius: 3px; background: var(--line); overflow: hidden; margin-top: 16px; display: none; }
.bar > div { height: 100%; width: 0; background: var(--accent); transition: width .2s; }
.note { color: var(--muted); font-size: 13px; margin: 14px 0 0; }
.error { color: var(--bad); }
footer { color: var(--muted); font-size: 12px; text-align: center; margin-top: 16px; }
footer a { color: inherit; }
`;

export const PAGE_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Spinform link</title>
<style>${STYLE}</style>
</head>
<body>
<main>
  <div class="card">
    <div class="brand"><i></i>Spinform</div>
    <h1 id="name">Opening…</h1>
    <p class="sub" id="details">&nbsp;</p>
    <button id="download" disabled>Download</button>
    <div class="bar" id="bar"><div></div></div>
    <p class="note" id="note">Encrypted end to end. Only people with this link can open the file.</p>
  </div>
  <footer>Sent with Spinform · <a id="report" href="mailto:{{ABUSE_EMAIL}}">Report this link</a></footer>
</main>
<script>
(() => {
  const CHUNK = 8 * 1024 * 1024, TAG = 16;
  const $ = (id) => document.getElementById(id);
  const id = location.pathname.split("/")[2];
  const keyText = location.hash.slice(1);
  $("report").href += "?subject=" + encodeURIComponent("Report link " + id);

  function fail(message) {
    $("name").textContent = "Can't open this link";
    $("details").textContent = message;
    $("details").className = "sub error";
    $("download").style.display = "none";
    $("note").style.display = "none";
    $("bar").style.display = "none";
  }

  function bytes(b64) {
    const s = atob(b64.replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(s, (c) => c.charCodeAt(0));
  }

  function size(n) {
    const units = ["bytes", "KB", "MB", "GB"];
    let i = 0;
    while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
    return (i ? n.toFixed(n < 10 ? 1 : 0) : n) + " " + units[i];
  }

  function metaNonce() {
    const n = new Uint8Array(12);
    n.set([255, 255, 255, 255]);
    return n;
  }

  function chunkNonce(i, last) {
    const n = new Uint8Array(12);
    n[0] = last ? 1 : 0;
    new DataView(n.buffer).setBigUint64(4, BigInt(i));
    return n;
  }

  async function start() {
    if (!keyText) return fail("This link is missing its key. Ask the sender to copy the whole link again.");
    if (!window.crypto || !crypto.subtle) return fail("This browser can't decrypt files. Try an up-to-date Chrome, Safari, Edge or Firefox.");
    let key, info, meta;
    try {
      const raw = bytes(keyText);
      if (raw.length !== 32) throw new Error();
      key = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["decrypt"]);
    } catch (_) {
      return fail("This link's key is damaged. Ask the sender to copy the whole link again.");
    }
    try {
      const response = await fetch("/api/links/" + id, { cache: "no-store" });
      if (!response.ok) return fail(response.status === 404 ? "This link has expired or was deleted." : "The link service didn't answer. Try again in a minute.");
      info = await response.json();
    } catch (_) {
      return fail("Couldn't reach the link service. Check your connection and try again.");
    }
    try {
      const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: metaNonce() }, key, bytes(info.meta));
      meta = JSON.parse(new TextDecoder().decode(plain));
    } catch (_) {
      return fail("This link's key doesn't match the file. Ask the sender to copy the whole link again.");
    }
    const name = String(meta.name || "file").replace(/[\\\\/:*?"<>|\\u0000-\\u001f]/g, "_");
    const expires = new Date(info.expires);
    document.title = name + " · Spinform";
    $("name").textContent = name;
    $("details").textContent = size(meta.size) + " · available until " +
      expires.toLocaleDateString(undefined, { day: "numeric", month: "long" }) + ", " +
      expires.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
    const button = $("download");
    button.disabled = false;
    button.onclick = () => download(key, info, meta, name).catch((e) => {
      console.error(e);
      button.disabled = false;
      $("note").textContent = "The download stopped: " + (e && e.message || e) + ". Try again.";
      $("note").className = "note error";
    });
  }

  async function download(key, info, meta, name) {
    const button = $("download");
    button.disabled = true;
    $("note").className = "note";
    // The service worker decrypts as the browser saves, so big files never sit in memory.
    const worker = await serviceWorker();
    if (worker) {
      const ticket = await new Promise((resolve, reject) => {
        const channel = new MessageChannel();
        channel.port1.onmessage = (event) => resolve(event.data.ticket);
        setTimeout(() => reject(new Error("the browser didn't respond")), 5000);
        worker.postMessage({ type: "download", id, key: keyText, name, size: meta.size, total: info.size,
          type2: meta.type || "application/octet-stream" }, [channel.port2]);
      });
      const frame = document.createElement("iframe");
      frame.hidden = true;
      frame.src = "/dl/" + ticket + "/" + encodeURIComponent(name);
      document.body.appendChild(frame);
      $("note").textContent = "Downloading. Your browser shows the progress.";
      setTimeout(() => { button.disabled = false; }, 4000);
      return;
    }
    // Without a service worker (private windows in some browsers): decrypt in memory.
    $("bar").style.display = "block";
    const parts = [];
    const count = Math.max(1, Math.ceil(info.size / (CHUNK + TAG)));
    for (let i = 0; i < count; i++) {
      const from = i * (CHUNK + TAG);
      const to = Math.min(info.size, from + CHUNK + TAG) - 1;
      const response = await fetch("/api/links/" + id + "/data", { headers: { range: "bytes=" + from + "-" + to } });
      if (!response.ok) throw new Error("the server answered " + response.status);
      const sealed = await response.arrayBuffer();
      parts.push(await crypto.subtle.decrypt({ name: "AES-GCM", iv: chunkNonce(i, i === count - 1) }, key, sealed));
      $("bar").firstElementChild.style.width = Math.round(((i + 1) / count) * 100) + "%";
    }
    const url = URL.createObjectURL(new Blob(parts, { type: meta.type || "application/octet-stream" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = name;
    document.body.appendChild(a);
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    button.disabled = false;
    $("note").textContent = "Downloaded.";
  }

  // Some browsers (private windows, locked-down settings) never finish registering.
  function serviceWorker() {
    return Promise.race([registerWorker(), new Promise((resolve) => setTimeout(() => resolve(null), 4000))]);
  }

  async function registerWorker() {
    if (!("serviceWorker" in navigator)) return null;
    try {
      const registration = await navigator.serviceWorker.register("/sw.js", { scope: "/" });
      await navigator.serviceWorker.ready;
      if (navigator.serviceWorker.controller) return navigator.serviceWorker.controller;
      await new Promise((resolve) => {
        navigator.serviceWorker.addEventListener("controllerchange", resolve, { once: true });
        setTimeout(resolve, 3000);
      });
      return navigator.serviceWorker.controller || null;
    } catch (_) {
      return null;
    }
  }

  start();
})();
</script>
</body>
</html>`;

export const SERVICE_WORKER_JS = `// Spinform links: decrypts a download as the browser saves it.
const CHUNK = 8 * 1024 * 1024, TAG = 16;
const tickets = new Map();

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("message", (event) => {
  const data = event.data || {};
  if (data.type !== "download") return;
  const ticket = Array.from(crypto.getRandomValues(new Uint8Array(12)), (b) => b.toString(16).padStart(2, "0")).join("");
  tickets.set(ticket, data);
  setTimeout(() => tickets.delete(ticket), 10 * 60 * 1000);
  event.ports[0].postMessage({ ticket });
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  const m = url.pathname.match(/^\\/dl\\/([0-9a-f]{24})\\//);
  if (!m) return;
  const job = tickets.get(m[1]);
  if (!job) {
    event.respondWith(new Response("This download has expired. Go back and press Download again.", { status: 410 }));
    return;
  }
  tickets.delete(m[1]);
  event.respondWith(stream(job));
});

function bytes(b64) {
  const s = atob(b64.replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
}

function chunkNonce(i, last) {
  const n = new Uint8Array(12);
  n[0] = last ? 1 : 0;
  new DataView(n.buffer).setBigUint64(4, BigInt(i));
  return n;
}

async function stream(job) {
  const key = await crypto.subtle.importKey("raw", bytes(job.key), "AES-GCM", false, ["decrypt"]);
  const count = Math.max(1, Math.ceil(job.total / (CHUNK + TAG)));
  const fetchChunk = (i) => {
    const from = i * (CHUNK + TAG);
    const to = Math.min(job.total, from + CHUNK + TAG) - 1;
    return fetch("/api/links/" + job.id + "/data", { headers: { range: "bytes=" + from + "-" + to } }).then((r) => {
      if (!r.ok) throw new Error("server answered " + r.status);
      return r.arrayBuffer();
    });
  };
  let next = 0;
  // One chunk is fetched ahead while the last one is written.
  let pending = fetchChunk(0);
  const body = new ReadableStream({
    async pull(controller) {
      if (next >= count) return controller.close();
      const i = next++;
      const sealed = await pending;
      if (next < count) pending = fetchChunk(next);
      const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: chunkNonce(i, i === count - 1) }, key, sealed);
      controller.enqueue(new Uint8Array(plain));
      if (next >= count) controller.close();
    },
  });
  const ascii = job.name.replace(/[^\\x20-\\x7e]/g, "_").replace(/["\\\\]/g, "_");
  return new Response(body, {
    headers: {
      "content-type": job.type2 || "application/octet-stream",
      "content-length": String(job.size),
      "content-disposition": "attachment; filename=\\"" + ascii + "\\"; filename*=UTF-8''" + encodeURIComponent(job.name),
    },
  });
}
`;

export const HOME_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Spinform links</title>
<style>${STYLE}</style>
</head>
<body>
<main>
  <div class="card">
    <div class="brand"><i></i>Spinform</div>
    <h1>Spinform links</h1>
    <p class="sub">Files shared from Spinform's drag wheel. They're encrypted on the sender's computer, and links stop working after 7 days.</p>
  </div>
</main>
</body>
</html>`;
