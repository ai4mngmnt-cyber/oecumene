# OECUMENE Cloud Capsule v2

## Objective

Provide a portable OECUMENE admin session on another Windows computer without requiring the Owner to know internal paths.

v2 builds on Smart SIM-2 v1.

## Session modes

### Trusted

Use on a device the Owner trusts.

- state is stored under `%LOCALAPPDATA%\OECUMENE`;
- environment manifest may persist;
- existing GitHub CLI authentication may be reused;
- cloud-mounted OECUMENE clone may be used as the data plane.

### Ephemeral

Use on a foreign or untrusted computer.

- state is created under a unique `%TEMP%\OECUMENE-EPHEMERAL-<session>` folder;
- GitHub CLI config is redirected into that temporary state when `gh` is available;
- bootstrap does not store passwords, cookies, API keys, recovery codes or private keys;
- manifest includes an explicit cleanup command.

Ephemeral mode reduces local persistence. It does not make an untrusted computer trustworthy and cannot protect against malware or keyloggers on that computer.

## Admin gate

`-Admin` requests admin capability.

Current v2 gate:

1. Detect GitHub CLI (`gh`).
2. Check `gh auth status --hostname github.com`.
3. Report one of:
   - `AUTHENTICATED`
   - `AUTH_REQUIRED`
   - `CLI_MISSING`

No GitHub password or token is embedded in the public bootstrap.

If authentication is required, the intended flow is browser/device authentication through GitHub CLI.

## Data plane vs control plane

- **Data plane:** OECUMENE vault clone (local carrier or cloud-mounted clone).
- **Control plane:** public bootstrap/protocol plus authenticated private repositories when required.
- **Identity plane:** external browser/device authentication.
- **Session plane:** trusted or ephemeral local runtime.

## Example intents

Trusted admin:

```powershell
bootstrap.ps1 -Source auto -SessionMode trusted -Admin
```

Ephemeral cloud admin:

```powershell
bootstrap.ps1 -Source cloud -SessionMode ephemeral -Admin
```

## v2 acceptance

- trusted session produces persistent local manifest;
- ephemeral session writes only to its temporary state root;
- cloud source resolution continues to work;
- admin gate reports GitHub authentication state without embedding credentials;
- cleanup metadata is present for ephemeral sessions.

## Next step after v2

Portable GitHub CLI acquisition for a machine that has only browser + PowerShell, followed by browser/device login and controlled removal after the session.


## Portable GitHub CLI

If `gh` is absent and admin capability is requested, bootstrap downloads the latest official GitHub CLI release for Windows from `cli/cli`, extracts only the executable into the session state, and uses it without a machine-wide install.

- trusted mode: portable tool may live under the trusted OECUMENE state;
- ephemeral mode: portable tool lives under the temporary session state and is removed with that state;
- `-LoginAdmin` starts GitHub browser/device authentication;
- bootstrap itself does not embed a password or personal access token;
- the GitHub CLI credential store/config may contain a session credential, so ephemeral cleanup is mandatory.

Example:

```powershell
bootstrap.ps1 -Source cloud -SessionMode ephemeral -Admin -LoginAdmin
```
