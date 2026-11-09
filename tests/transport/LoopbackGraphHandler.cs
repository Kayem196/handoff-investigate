using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace Handoff.TransportChecks
{
    // Test-only routing: the SDK still owns retries, redirects, decompression and auth.
    public sealed class LoopbackGraphHandler : HttpMessageHandler
    {
        public HttpClient Sdk { get; set; }
        private readonly Uri origin;
        public string NextPath { get; set; } = "/empty";
        public string GroupPath { get; set; } = "/collector-group";
        public string PolicyPath { get; set; } = "/collector-ca";
        public string CatalogNextPath { get; set; } = "/empty";

        public LoopbackGraphHandler(HttpClient sdk, string origin)
        {
            Sdk = sdk;
            this.origin = new Uri(origin);
            if (this.origin.Scheme != "http" || this.origin.Host != "127.0.0.1")
                throw new ArgumentException("Expected loopback fixture");
        }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            var path = request.RequestUri.AbsolutePath;
            if (path == "/v1.0/groups") path = request.RequestUri.Query.Contains("$skiptoken=") ? CatalogNextPath : "/collector-groups";
            else if (path.Contains("/groups/")) path = GroupPath;
            else if (path.EndsWith("/identity/conditionalAccess/policies"))
                path = request.RequestUri.Query.Length == 0 ? PolicyPath : NextPath;
            else if (path.EndsWith("/deviceManagement/deviceCompliancePolicies")) path = "/empty";
            else throw new InvalidOperationException("Unexpected collector resource");
            using var forwarded = new HttpRequestMessage(HttpMethod.Get, new Uri(origin, path));
            foreach (var option in request.Options)
                forwarded.Options.Set(new HttpRequestOptionsKey<object>(option.Key), option.Value);
            forwarded.Headers.TryAddWithoutValidation("Authorization", "Bearer fictional-local-transport-probe");
            return await Sdk.SendAsync(forwarded, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
        }
    }
}
