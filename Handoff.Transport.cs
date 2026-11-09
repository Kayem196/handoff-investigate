using System;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Handoff.Investigation
{
    // Owns only the investigation deadline, never the SDK client or credentials.
    public sealed class ReadBudget : IDisposable
    {
        private readonly CancellationTokenSource deadline;
        public readonly int MaxResponseBytes;
        public bool Expired => deadline.IsCancellationRequested;

        public ReadBudget(int seconds, int maxResponseBytes, CancellationToken cancellation)
        {
            MaxResponseBytes = maxResponseBytes;
            deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            deadline.CancelAfter(TimeSpan.FromSeconds(seconds));
        }

        public async Task<string> ReadAsync(HttpClient client, string uri, object redirectOption, object retryOption)
        {
            var token = deadline.Token;
            token.ThrowIfCancellationRequested();
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            // Kiota's public request-option contract uses the option's full type name.
            request.Options.Set(new HttpRequestOptionsKey<object>(redirectOption.GetType().FullName), redirectOption);
            request.Options.Set(new HttpRequestOptionsKey<object>(retryOption.GetType().FullName), retryOption);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
            if ((int)response.StatusCode >= 300 && (int)response.StatusCode < 400)
                throw new InvalidOperationException("redirect_rejected");
            // Never buffer or disclose an error body, including authentication failures.
            if (!response.IsSuccessStatusCode) throw new InvalidOperationException("request_failed");
            // The SDK decompresses supported encodings. Never parse a residual encoding.
            if (response.Content.Headers.ContentEncoding.Count != 0)
                throw new InvalidOperationException("request_failed");
            if (response.Content.Headers.ContentLength > MaxResponseBytes)
                throw new InvalidOperationException("response_limit");
            using var stream = await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
            using var body = new MemoryStream();
            var buffer = new byte[Math.Min(8192, MaxResponseBytes + 1)];
            while (true)
            {
                var remaining = MaxResponseBytes - (int)body.Length;
                var read = await stream.ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, remaining + 1)), token).ConfigureAwait(false);
                if (read == 0) break;
                if (read > remaining) throw new InvalidOperationException("response_limit");
                body.Write(buffer, 0, read);
            }
            token.ThrowIfCancellationRequested();
            return new UTF8Encoding(false, true).GetString(body.GetBuffer(), 0, (int)body.Length);
        }

        public void Dispose() => deadline.Dispose();
    }
}
