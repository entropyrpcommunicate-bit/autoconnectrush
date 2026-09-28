# Validation

Locally on macOS (cross-compilation):
- .NET 10 scheduler/storage tests: 18 passing.
- JavaScript fixtures: browser interstitial, camera notice, guest-name confirmation, duplicate input refusal, button cooldown, landing recovery, blocked capture, expiry, manual preview, foreign-origin rejection.
- Windows project build: no warnings or errors.

GitHub Actions additionally publishes x64/x86/ARM64 self-contained builds, checks Windows x64/x86 GUI startup, and uploads ZIPs. See the actual run result; configuration alone is not evidence of passing CI. ARM64 startup is not exercised on the x64 runner.

Not verified: real Telemost connection on Windows, UI appearance on Windows 10/11, ARM64 hardware, locked-session behavior, organizer admission, long-running reconnection. The macOS prototype was tried by the original requester, but that does not validate this Windows port.
