# Security

Please report suspected vulnerabilities privately using GitHub's **Report a
vulnerability** button on this repository's Security tab, not in a public issue.

**Useful to include:** the module version, PowerShell and Graph SDK versions,
the fixed outcome or failure code you saw, and minimal reproduction steps using
fictional data.

**Never send:** access tokens, API keys, client secrets, tenant dumps, saved
investigation files, or real tenant, user or group identifiers.

## Design boundaries we treat as security issues

- Any way this tool could modify a tenant or request write permissions.
- Leaking a token, API key or raw provider/SDK error body into output, reports
  or saved evidence.
- Following a redirect or `nextLink` outside the expected Microsoft Graph
  resource or provider endpoint.
- Executing, or rendering as markup, text that comes from the tenant, for
  example policy or group names in the terminal or HTML reports.
- Sending Axon data without the explicit `SHARE` confirmation, or sending
  anything outside the allow-listed payload (including the tenant ID).
- Overwriting or silently altering existing saved evidence.

Saved investigations and exports are plaintext and are not signed audit
records. Protecting the folders that hold them is the operator's responsibility.
