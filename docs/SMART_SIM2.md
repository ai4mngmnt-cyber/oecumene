# OECUMENE Smart SIM-2 v1

## Purpose

The Owner does not manage drive letters, vault paths, browser-extension folders, or cloud-sync internals.

The bootstrap resolver discovers the best available OECUMENE environment and writes one canonical environment manifest.

## Resolution order

1. **Local Carrier** — SIM-2 or another local OECUMENE carrier.
2. **Cloud-mounted clone** — an already mounted/synced cloud clone of OECUMENE.
3. **Fail closed** — if neither source is available, bootstrap stops with an explicit status.

Local Carrier always outranks Cloud-mounted clone.

## Canonical signature

- Vault relative path: `OECUMENE_HUB\10_VAULTS\OECUMENE_Corpus`
- Obsidian marker: `.obsidian`
- Export root: `AI-Export`

The resolver uses the signature, not a fixed drive letter.

## Cloud-mounted roots

v1 checks an explicit `-CloudRoot` plus common Windows cloud roots such as OneDrive, Proton Drive, Dropbox, Google Drive and iCloud Drive.

The resolver does not recursively scan the full computer.

## Canonical manifest

Local machine:

`%LOCALAPPDATA%\OECUMENE\environment.json`

Vault mirror:

`<resolved-vault>\.oecumene-environment.json`

The manifest records:

- schema version;
- resolution time;
- machine;
- mode: `local-carrier` or `cloud-mounted`;
- provider;
- volume identity when local;
- cloud root when cloud-mounted;
- vault and export paths;
- discovered applications.

## Security model

- No passwords, API keys, recovery codes, browser cookies or private keys are stored in the manifest.
- Browser/device authentication belongs to the identity layer and is out of scope for v1.
- v1 does not bypass Chrome or Windows security prompts.
- If no trusted source is available, bootstrap fails closed.

## Owner UX

The Owner should only run bootstrap and approve unavoidable OS/browser prompts.

The Owner must not be required to derive or type OECUMENE internal paths.

## Future layers

- Cloud-authenticated capsule discovery.
- Ephemeral Admin mode for untrusted computers.
- Provider adapters for remote cloud data planes.
- Controlled restoration of applications and extensions.
- Remote integrity/provenance validation.


## Source selection

Bootstrap supports three explicit source modes:

- `-Source auto` — default; prefer Local Carrier, then Cloud-mounted clone.
- `-Source local` — test or require the local carrier path only.
- `-Source cloud` — test or require the cloud-mounted path only.

This allows Customer 00 testing of the cloud path without disconnecting SIM-2.
