# OECUMENE Phoenix v0.1

## Role

Phoenix is the OECUMENE resilience and recovery engine.

v0.1 is deliberately diagnostic-only:

`CHECK -> DIAGNOSE -> REPORT`

It does not repair, delete, move, overwrite, or restore user data.

## Why Phoenix exists

Bootstrap starts OECUMENE.
Resolver discovers the environment.
Capsule provides portability.
Phoenix determines whether the environment is healthy and what recovery class is required.

## Health classes

- `HEALTHY`
- `DEGRADED`
- `RECOVERABLE`
- `REBUILD_REQUIRED`
- `MANUAL_ESCALATION`

## Checks in v0.1

Phoenix can inspect:

- OECUMENE vault signature on mounted filesystem drives;
- local environment manifest existence and JSON validity;
- manifest vault path availability;
- `.obsidian` marker;
- `AI-Export` root;
- vault mirror environment manifest;
- optional reachability of public bootstrap and GitHub.

## Safety contract

Phoenix v0.1:

- modifies no user data;
- performs no repair;
- writes only a diagnostic JSON report;
- reports repair hints but does not execute them;
- treats repair as a separate future gate.

## Report

Default location:

`%LOCALAPPDATA%\OECUMENE\phoenix\phoenix-report-<timestamp>.json`

## Example

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\phoenix.ps1 -Mode diagnose -OnlineChecks
```

## Next release

Phoenix v0.2 will introduce `HEAL` for a small allowlist of deterministic, reversible repairs only.

No destructive or user-data repair will be automatic.
