# Spinform links

The service behind the drag wheel's **Link** bubble: drop files on it and Spinform uploads
them encrypted, then copies a link like `https://<service>/l/x7k2Qm9aPz#…` that anyone can
download from in a browser for 7 days. It's a Cloudflare Worker that keeps files in R2.

- Files are encrypted on the sender's computer (AES-256-GCM, [FORMAT.md](FORMAT.md)). The key
  is only in the link after `#`, which browsers never send, so neither this service nor
  Cloudflare can read files or their names.
- Up to 5 GB per link, links expire after 7 days, and each app token can upload 20 GB a day
  (all in `wrangler.toml`).
- Uploads need a token the app sends. Builds without one have no Link bubble.
- The download page decrypts in the browser through a service worker, so big files stream
  straight to disk. Browsers without service workers decrypt in memory instead.

## Cost (estimate)

R2 charges nothing for downloads, about US$0.015 per GB-month for storage (first 10 GB free)
and US$4.50 per million uploads of a part (first million a month free). A 2 GB link kept for
7 days costs about US$0.007. 1,000 such links a month ≈ US$7. The Workers free plan
(100,000 requests a day) is enough to start; each 8 MB of upload is one request.

## Setting it up (once)

The workflow **Deploy the link service** (`.github/workflows/deploy-links.yml`) creates the
R2 bucket and its clean-up rules, deploys the Worker and gives it the app token. It needs:

1. A Cloudflare account (https://dash.cloudflare.com/sign-up). Open **Workers & Pages** once
   so the account gets its `workers.dev` address, and **R2 Object Storage** once to turn R2
   on (it asks for a card; the free allowance covers the start).
2. An API token: **My Profile → API Tokens → Create Token → Create Custom Token** with
   *Account · Workers Scripts · Edit* and *Account · Workers R2 Storage · Edit*.
3. Three repository secrets (GitHub: **Settings → Secrets and variables → Actions**):
   `CLOUDFLARE_API_TOKEN` (step 2), `CLOUDFLARE_ACCOUNT_ID` (shown on the Workers & Pages
   page) and `SPINFORM_LINK_TOKEN` (any long random text; the apps send it).
4. Run the workflow (**Actions → Deploy the link service → Run workflow**). Its summary shows
   the address, e.g. `https://spinform-links.<name>.workers.dev`. Save it as a fourth secret,
   `SPINFORM_LINK_SERVICE`. From the next build on, the Mac and Windows apps have Link.

Optional: a nicer address. **Workers & Pages → spinform-links → Settings → Domains & Routes →
Add → Custom domain**, e.g. `links.spinform.app` (the domain must be on Cloudflare). Then
update the `SPINFORM_LINK_SERVICE` secret.

By hand instead: `npx wrangler login`, `npx wrangler r2 bucket create spinform-links`,
`npx wrangler deploy`, `npx wrangler secret put UPLOAD_TOKENS`.

Change `ABUSE_EMAIL` in `wrangler.toml` to an inbox you read before the link goes public.

## Before the paid launch

Today a token is baked into each build, which is fine for the beta. When the licence server
from the commercialization plan exists, `authorize()` in `src/worker.js` should accept a
signed Pro licence instead, with the daily allowance per licence.

## Testing

```
npx wrangler dev --local --test-scheduled     # with UPLOAD_TOKENS=test-token in .dev.vars
SERVICE=http://localhost:8787 node test/run.mjs
```

`PLAYWRIGHT=1` also downloads through the real page in Chromium, with and without the service
worker. A second instance started with `--var LINK_DAYS:0.00001` and passed as
`EXPIRY_SERVICE` checks that links expire and the hourly sweep deletes them. The Mac build
server runs these tests and the app's own upload checks on every build.
