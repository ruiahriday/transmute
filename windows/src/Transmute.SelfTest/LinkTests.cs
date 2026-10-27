using System.Text.Json.Nodes;
using Transmute;

/// "Create link": the format against FORMAT.md's test vectors, Link only on the wheel when a
/// service is set up, and, when SPINFORM_LINK_SERVICE points at a running service, real
/// uploads that are downloaded and decrypted again.
static partial class Tests
{
    static async Task LinkChecks(IReadOnlyList<string> inputs)
    {
        var key = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
        var plain = "Spinform"u8.ToArray();
        await Check("Links: test vectors match FORMAT.md", () =>
        {
            Expect(Convert.ToHexString(LinkCrypto.Seal(plain, key, LinkCrypto.ChunkNonce(0, true))).ToLowerInvariant()
                   == "b15ceb51c2c09e6a25bed4a095a883ff5d4a73a241d0e2d1", "chunk 0 differs");
            Expect(Convert.ToHexString(LinkCrypto.Seal(plain, key, LinkCrypto.ChunkNonce(1, false))).ToLowerInvariant()
                   == "46a6d692229b4273c0ec8d676e77d010a6c642928d1ddcd4", "chunk 1 differs");
            Expect(Convert.ToHexString(LinkCrypto.Seal("""{"name":"a.txt","size":8,"type":"text/plain"}"""u8, key, LinkCrypto.MetaNonce)).ToLowerInvariant()
                   == "e2adc4ae55e38c9d95523d6c3900f0f3722ac324e2d8e43eb1be94be0fc64165b0564cf454b4b5ebba92ef41357aec5f1743209464ff08268b9643aa33", "meta differs");
            var sealedLast = LinkCrypto.Seal(plain, key, LinkCrypto.ChunkNonce(3, true));
            var opened = true;
            try { LinkCrypto.Open(sealedLast, key, LinkCrypto.ChunkNonce(3, false)); } catch (System.Security.Cryptography.CryptographicException) { opened = false; }
            Expect(!opened, "a chunk with the wrong last flag opened");
            Expect(new[] { 0L, 1, LinkService.Chunk, LinkService.Chunk + 1L }.Select(LinkCrypto.ChunkCount).SequenceEqual([1, 1, 1, 2]), "chunk counts");
            Expect(LinkCrypto.FromBase64Url(LinkCrypto.Base64Url(key)).SequenceEqual(key), "base64url");
            return None();
        });

        var configured = LinkService.IsAvailable;
        var saved = (Environment.GetEnvironmentVariable("SPINFORM_LINK_SERVICE"), Environment.GetEnvironmentVariable("SPINFORM_LINK_TOKEN"));
        await Check("Drag wheel: Link only when a link service is set up", () =>
        {
            try
            {
                Environment.SetEnvironmentVariable("SPINFORM_LINK_SERVICE", null);
                Environment.SetEnvironmentVariable("SPINFORM_LINK_TOKEN", null);
                if (!LinkService.IsAvailable)
                    Expect(!WheelLayout.Resolve(WheelKind.Actions, [FileKind.Pdf], null).Contains("action:link"), "Link showed without a service");
                Environment.SetEnvironmentVariable("SPINFORM_LINK_SERVICE", "https://links.example");
                Environment.SetEnvironmentVariable("SPINFORM_LINK_TOKEN", "t");
                Expect(WheelLayout.Resolve(WheelKind.Actions, [FileKind.Pdf], null).LastOrDefault() == "action:link", "Link missing with a service");
            }
            finally
            {
                Environment.SetEnvironmentVariable("SPINFORM_LINK_SERVICE", saved.Item1);
                Environment.SetEnvironmentVariable("SPINFORM_LINK_TOKEN", saved.Item2);
            }
            return None();
        });

        if (!configured)
        {
            Console.WriteLine("SKIP  Links: upload (set SPINFORM_LINK_SERVICE and SPINFORM_LINK_TOKEN to run it)");
            skipped++;
            return;
        }
        var service = LinkService.Endpoint!;
        var appToken = LinkService.Token!;
        var big = Path.Combine(outDir, "link test.bin");
        var bigData = new byte[LinkService.Chunk * 2 + 4321];
        for (var i = 0; i < bigData.Length; i++) bigData[i] = (byte)(i * 31 + (i >> 12));
        File.WriteAllBytes(big, bigData);
        await Check("Links: an 8 MB+ file uploads and downloads intact", async () =>
        {
            await LinkRoundTrip([big], service, appToken, "link test.bin", bigData);
            return [];
        });
        if (inputs.Count >= 2)
        {
            await Check("Links: two files go as one zip", async () =>
            {
                await LinkRoundTrip(inputs.Take(2).ToList(), service, appToken, "2 files.zip", null);
                return [];
            });
        }
    }

    static async Task LinkRoundTrip(IReadOnlyList<string> paths, string service, string appToken, string expectName, byte[]? expect)
    {
        var (file, cleanup) = await LinkUploader.Prepare(paths, default);
        try
        {
            var link = await LinkUploader.Upload(file, service, appToken, (_, _) => { }, default);
            var key = LinkCrypto.FromBase64Url(link.Url.Split('#')[1]);
            Expect(key.Length == 32, "no key in the link");
            Expect(link.Url.StartsWith($"{service}/l/{link.Id}#"), $"odd link {link.Url}");
            using var http = new HttpClient();
            var info = JsonNode.Parse(await http.GetStringAsync($"{service}/api/links/{link.Id}"))!;
            var meta = JsonNode.Parse(LinkCrypto.Open(Convert.FromBase64String(info["meta"]!.GetValue<string>()), key, LinkCrypto.MetaNonce))!;
            Expect(meta["name"]!.GetValue<string>() == expectName, $"name {meta["name"]}");
            var total = info["size"]!.GetValue<long>();
            var sealedBytes = await http.GetByteArrayAsync($"{service}/api/links/{link.Id}/data");
            Expect(sealedBytes.Length == total, $"got {sealedBytes.Length} of {total} bytes");
            var part = LinkService.Chunk + LinkService.Tag;
            var chunks = (int)((total + part - 1) / part);
            using var plain = new MemoryStream();
            for (var i = 0; i < chunks; i++)
            {
                var start = i * part;
                var end = (int)Math.Min(total, start + part);
                plain.Write(LinkCrypto.Open(sealedBytes.AsSpan(start, end - start), key, LinkCrypto.ChunkNonce(i, i == chunks - 1)));
            }
            var original = expect ?? File.ReadAllBytes(file);
            Expect(plain.ToArray().AsSpan().SequenceEqual(original), $"the downloaded file differs ({plain.Length} vs {original.Length} bytes)");
            Console.WriteLine($"      {link.Url.Split('#')[0]} · {OutputPaths.FormatSize(original.Length)}");
            await LinkUploader.DeleteRemote(service, link.Id, link.DeleteToken);
            var gone = await http.GetAsync($"{service}/api/links/{link.Id}");
            Expect(gone.StatusCode == System.Net.HttpStatusCode.NotFound, "still there after delete");
        }
        finally
        {
            if (cleanup is not null) try { Directory.Delete(cleanup, true); } catch { }
        }
    }
}
