# Local HTML-report browser checks

Optional integration checks, separate from Pester. Tested on Windows 11,
PowerShell 7.6.9, Node 26 and installed Edge 157. No npm dependencies or browser
download are required. Use fictional fixtures only; do not put tenant evidence in
this screenshot test. The script controls only a new test-owned browser profile.
It does not change browser security, trust stores, user profiles or permissions.

From `public-handoff/`, choose new private local directories:

```powershell
pwsh -NoProfile -File ./tests/browser/New-ReportBrowserFixtures.ps1 `
    -OutDirectory 'C:\private\new-report-fixtures'

node ./tests/browser/verify-report.mjs `
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' `
    'C:\private\new-report-fixtures\group-investigation.html' `
    'C:\private\new-report-fixtures\incomplete-observation.html' `
    'C:\private\new-report-fixtures\hostile-observation.html' `
    'C:\private\new-report-browser-checks'
```

The fixture script refuses an already loaded Graph authentication module and
creates complete/incomplete reports plus a deliberately hostile name/note/filter
payload, all offline. The browser script starts headless Chromium with its own
new profile and a loopback-only, ephemeral debugging endpoint. It uses Node's
built-in WebSocket client to run 31 assertions and saves desktop/mobile screenshots
and `browser-checks.json`. A failure exits nonzero and records the error. It stops
its own browser; reports, screenshots and the test-owned profile are retained for
inspection, never committed automatically. Existing output directories are refused.

Checks cover semantic document structure, internal links, matching hash-based
stylesheet CSP, literal hostile markup (no executable/resource elements or injected
dialog), two-reference known answers, incomplete warnings, 390/320 px overflow,
native keyboard disclosure, print-style emulation and zero HTTP(S) **page** requests.
This is not monitoring of every browser background process, a screen-reader audit,
physical printer/PDF pagination test, or acceptance of other browser engines.
No real credential, SDK login, tenant operation or consent is part of these checks.
