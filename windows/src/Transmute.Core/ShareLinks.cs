using System.Net;
using System.Net.Http.Headers;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Transmute;

/// "Create link": the drag wheel's Link bubble uploads files, encrypted, to the Spinform link
/// service and copies a link anyone can download from for 7 days. The service and its format
/// are in server/links on the main branch (FORMAT.md). The key is made here and only travels
/// in the link after "#", so the service never sees the file or its name.
public static class LinkService
{
    /// The service's address and the token this build sends: from the environment, or baked in
    /// at build time (MSBuild properties SpinformLinkService / SpinformLinkToken). Builds without
    /// them leave Link off every wheel.
    public static string? Endpoint => Setting("SPINFORM_LINK_SERVICE", "SpinformLinkService")?.TrimEnd('/');
    public static string? Token => Setting("SPINFORM_LINK_TOKEN", "SpinformLinkToken");
    public static bool IsAvailable => Endpoint is not null && Token is not null;

    public const int Chunk = 8 * 1024 * 1024;
    public const int Tag = 16;
    /// The service's limit (MAX_BYTES in wrangler.toml).
    public const long MaxBytes = 5L * 1024 * 1024 * 1024;
    public const int Days = 7;

    static string? Setting(string variable, string metadata)
    {
        var value = Environment.GetEnvironmentVariable(variable);
        if (string.IsNullOrEmpty(value))
        {
            value = typeof(LinkService).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
                .FirstOrDefault(a => a.Key == metadata)?.Value;
        }
        return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }
}

public static class LinkCrypto
{
    public static byte[] ChunkNonce(long index, bool last)
    {
        var nonce = new byte[12];
        nonce[0] = last ? (byte)1 : (byte)0;
        System.Buffers.Binary.BinaryPrimitives.WriteUInt64BigEndian(nonce.AsSpan(4), (ulong)index);
        return nonce;
    }

    public static byte[] MetaNonce => [0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0];

    /// Ciphertext followed by the 16-byte tag.
    public static byte[] Seal(ReadOnlySpan<byte> plain, byte[] key, byte[] nonce)
    {
        using var aes = new AesGcm(key, LinkService.Tag);
        var sealedBytes = new byte[plain.Length + LinkService.Tag];
        aes.Encrypt(nonce, plain, sealedBytes.AsSpan(0, plain.Length), sealedBytes.AsSpan(plain.Length));
        return sealedBytes;
    }

    public static byte[] Open(ReadOnlySpan<byte> sealedBytes, byte[] key, byte[] nonce)
    {
        if (sealedBytes.Length < LinkService.Tag) throw new CryptographicException("Damaged data.");
        using var aes = new AesGcm(key, LinkService.Tag);
        var plain = new byte[sealedBytes.Length - LinkService.Tag];
        aes.Decrypt(nonce, sealedBytes[..plain.Length], sealedBytes[plain.Length..], plain);
        return plain;
    }

    public static string Base64Url(byte[] data) => Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    public static byte[] FromBase64Url(string text)
    {
        var s = text.Replace('-', '+').Replace('_', '/');
        return Convert.FromBase64String(s.PadRight(s.Length + (4 - s.Length % 4) % 4, '='));
    }

    /// Chunks a file of this size is cut into (an empty file is one empty chunk).
    public static int ChunkCount(long size) => (int)Math.Max(1, (size + LinkService.Chunk - 1) / LinkService.Chunk);
}

/// A link made on this PC, kept so it can be copied again or deleted early.
public sealed record SharedLink(string Id, string Name, long Size, string Url, string DeleteToken, DateTimeOffset Expires, string Service)
{
    public bool IsExpired => Expires < DateTimeOffset.Now;
}

/// Links made on this PC, in %APPDATA%\Spinform\links.json.
public static class SharedLinks
{
    static readonly object Gate = new();
    public static string FilePath { get; set; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Spinform", "links.json");

    public static List<SharedLink> Load()
    {
        lock (Gate)
        {
            try
            {
                return (JsonSerializer.Deserialize<List<SharedLink>>(File.ReadAllText(FilePath)) ?? [])
                    .Where(l => !l.IsExpired).ToList();
            }
            catch { return []; }
        }
    }

    public static void Add(SharedLink link) => Save([link, .. Load()]);

    public static async Task Delete(SharedLink link)
    {
        await LinkUploader.DeleteRemote(link.Service, link.Id, link.DeleteToken);
        Save(Load().Where(l => l.Id != link.Id).ToList());
    }

    static void Save(List<SharedLink> links)
    {
        lock (Gate)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(links.Where(l => !l.IsExpired).ToList()));
        }
    }
}

public static class LinkUploader
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(3) };

    /// One file to send: the file itself, or a zip of several files or a folder.
    public static async Task<(string File, string? Cleanup)> Prepare(IReadOnlyList<string> paths, CancellationToken token)
    {
        if (paths.Count == 1 && File.Exists(paths[0])) return (paths[0], null);
        var folder = Path.Combine(Path.GetTempPath(), "spinform-link-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(folder);
        var zip = await Archives.Compress(paths, OutputFormat.Zip, paths.Count == 1 ? null : $"{paths.Count} files",
                                          new ConversionOptions { OutputFolder = folder }, token);
        return (zip, folder);
    }

    /// Encrypts and uploads one file; returns the link (key included). progress gets (sent, total) in bytes.
    public static async Task<SharedLink> Upload(string file, string service, string appToken, Action<long, long> progress, CancellationToken token)
    {
        var size = new FileInfo(file).Length;
        if (size > LinkService.MaxBytes)
            throw new ConversionException($"Links can hold up to 5 GB. This is {OutputPaths.FormatSize(size)}.");
        var key = RandomNumberGenerator.GetBytes(32);
        var chunks = LinkCrypto.ChunkCount(size);
        var total = size + (long)chunks * LinkService.Tag;
        var name = Path.GetFileName(file);
        var meta = LinkCrypto.Seal(JsonSerializer.SerializeToUtf8Bytes(new { name, size, type = MimeType(name) }), key, LinkCrypto.MetaNonce);

        var created = await Call(service, HttpMethod.Post, "/api/links", appToken,
            Json(new { size = total, parts = chunks, meta = Convert.ToBase64String(meta) }), 0, token);
        var id = created["id"]?.GetValue<string>() ?? throw new ConversionException("The link service gave an odd answer.");
        var pageUrl = created["url"]!.GetValue<string>();
        var deleteToken = created["deleteToken"]!.GetValue<string>();
        try
        {
            using var stream = File.OpenRead(file);
            var buffer = new byte[LinkService.Chunk];
            var parts = new JsonArray();
            long sent = 0;
            progress(0, total);
            for (var i = 0; i < chunks; i++)
            {
                token.ThrowIfCancellationRequested();
                var read = await stream.ReadAtLeastAsync(buffer, buffer.Length, throwOnEndOfStream: false, token);
                var sealedBytes = LinkCrypto.Seal(buffer.AsSpan(0, read), key, LinkCrypto.ChunkNonce(i, i == chunks - 1));
                var answer = await Call(service, HttpMethod.Put, $"/api/links/{id}/parts/{i + 1}", appToken,
                    () => new ByteArrayContent(sealedBytes) { Headers = { ContentType = new MediaTypeHeaderValue("application/octet-stream") } }, 4, token);
                parts.Add(new JsonObject { ["partNumber"] = i + 1, ["etag"] = answer["etag"]?.GetValue<string>() });
                sent += sealedBytes.Length;
                progress(sent, total);
            }
            var done = await Call(service, HttpMethod.Post, $"/api/links/{id}/complete", appToken,
                Json(new JsonObject { ["parts"] = parts }), 2, token);
            var expires = DateTimeOffset.TryParse(done["expires"]?.GetValue<string>(), out var e) ? e : DateTimeOffset.Now.AddDays(LinkService.Days);
            return new SharedLink(id, name, size, pageUrl + "#" + LinkCrypto.Base64Url(key), deleteToken, expires, service);
        }
        catch
        {
            // Don't leave half an upload behind.
            try { await DeleteRemote(service, id, deleteToken); } catch { }
            throw;
        }
    }

    public static async Task DeleteRemote(string service, string id, string deleteToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Delete, $"{service}/api/links/{id}");
        request.Headers.Add("X-Delete-Token", deleteToken);
        using var response = await Http.SendAsync(request);
        // 404: already gone, which is what we wanted.
        if (response.StatusCode is not (HttpStatusCode.OK or HttpStatusCode.NotFound))
            throw new ConversionException($"The link service didn't delete it ({(int)response.StatusCode}).");
    }

    static Func<HttpContent> Json(object value) => () => new StringContent(
        value is JsonNode node ? node.ToJsonString() : JsonSerializer.Serialize(value), Encoding.UTF8, "application/json");

    static async Task<JsonObject> Call(string service, HttpMethod method, string path, string appToken,
                                       Func<HttpContent> content, int retries, CancellationToken token)
    {
        for (var attempt = 0; ; attempt++)
        {
            string message;
            try
            {
                using var request = new HttpRequestMessage(method, service + path) { Content = content() };
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", appToken);
                using var response = await Http.SendAsync(request, token);
                var text = await response.Content.ReadAsStringAsync(token);
                JsonObject? body = null;
                try { body = JsonNode.Parse(text) as JsonObject; } catch (JsonException) { }
                if (response.IsSuccessStatusCode) return body ?? [];
                message = body?["error"]?.GetValue<string>() ?? $"The link service answered {(int)response.StatusCode}.";
                // Our mistakes and refusals won't fix themselves; the server's might.
                if ((int)response.StatusCode < 500) throw new ConversionException(message);
            }
            catch (HttpRequestException e)
            {
                message = $"Couldn't reach the link service: {e.Message}";
            }
            catch (TaskCanceledException) when (!token.IsCancellationRequested)
            {
                message = "The link service took too long to answer.";
            }
            if (attempt >= retries) throw new ConversionException(message);
            await Task.Delay(TimeSpan.FromSeconds(1 << (attempt + 1)), token);
        }
    }

    static string MimeType(string name) => Path.GetExtension(name).ToLowerInvariant() switch
    {
        ".zip" => "application/zip",
        ".pdf" => "application/pdf",
        ".jpg" or ".jpeg" => "image/jpeg",
        ".png" => "image/png",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        ".heic" => "image/heic",
        ".mp4" => "video/mp4",
        ".mov" => "video/quicktime",
        ".mkv" => "video/x-matroska",
        ".webm" => "video/webm",
        ".mp3" => "audio/mpeg",
        ".m4a" => "audio/mp4",
        ".wav" => "audio/wav",
        ".txt" => "text/plain",
        ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ".pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        _ => "application/octet-stream",
    };
}
