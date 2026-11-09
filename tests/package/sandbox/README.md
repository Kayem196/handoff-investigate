# Offline Windows Sandbox check

Windows Sandbox must be enabled on a supported Windows Pro/Enterprise machine.
Enabling the optional feature requires administrator approval and may require a
restart. This kit never enables features or restarts the host for you.

To build a kit, download the official `PowerShell-7.6.9-win-x64.zip` from the
PowerShell GitHub release, then run `New-SandboxKit.ps1 -OutDirectory <new-folder>
-PortablePowerShellZip <zip>`. The builder requires that release's exact SHA256.
The runtime is bundled separately, not installed on the host.

1. Double-click `Run-Handoff-Check.wsb` in the generated folder.
2. Wait for a `DONE` file inside `results/sandbox-<time>/` on the host.
3. Inspect `sandbox-results.json` and `check/clean-install-results.json` there.
   `DONE` means finished, **not** passed. Both JSON files must say `PASS`.
4. Close Sandbox. Its installed module and portable runtime are discarded.
   The results remain on the host.

Networking, clipboard sharing and vGPU are disabled. The kit is mapped
read-only; only the dedicated results folder is writable from Sandbox. No
credentials, SDK, API key or tenant connection are needed. Keep unrelated files
out of that results folder.

The bootstrap uses a process-only execution-policy bypass to start the check.
The actual module import runs in a fresh PowerShell process with that override
removed, under Sandbox's normal execution policy. A policy failure is reported,
not silently bypassed. This checks offline installation, reports and transport
compilation, not Graph login, AI providers or downloaded-file trust prompts.
