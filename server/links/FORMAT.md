# Link format (version 1)

The Mac app, the Windows app, the download page and `test/client.mjs` all follow this.

- **Key:** 32 random bytes per link, AES-256-GCM. It travels only in the link, after `#`,
  as base64url without padding: `https://<service>/l/<id>#<key>`. Browsers never send the
  part after `#` to a server.
- **File:** one file per link (the apps zip several files or a folder first). It is cut into
  chunks of 8 MiB (8,388,608 bytes); the last chunk may be shorter, and an empty file is one
  empty chunk. Each chunk is sealed on its own and becomes chunk + 16-byte tag.
- **Chunk nonce (12 bytes):** byte 0 is 1 for the last chunk and 0 otherwise, bytes 1–3 are 0,
  bytes 4–11 are the chunk number (from 0) big-endian. Marking the last chunk stops anyone
  cutting chunks off the end.
- **Upload:** chunk *n* is R2 multipart part *n + 1*, so every part but the last is
  8,388,624 bytes.
- **Name and size:** the JSON `{"name": "...", "size": <bytes>, "type": "<MIME type>"}` sealed
  with nonce `ff ff ff ff 00 00 00 00 00 00 00 00`, sent as standard base64 in `meta`. The
  service never sees the file name.
- **No associated data.**

## Test vector

Key `00 01 02 … 1f` (bytes 0 to 31), plaintext `Spinform` (UTF-8):

| Chunk | Last | Sealed (hex) |
|---|---|---|
| 0 | yes | `b15ceb51c2c09e6a25bed4a095a883ff5d4a73a241d0e2d1` |
| 1 | no | `46a6d692229b4273c0ec8d676e77d010a6c642928d1ddcd4` |

The meta `{"name":"a.txt","size":8,"type":"text/plain"}` with the same key seals to
`e2adc4ae55e38c9d95523d6c3900f0f3722ac324e2d8e43eb1be94be0fc64165b0564cf454b4b5ebba92ef41357aec5f1743209464ff08268b9643aa33`.
