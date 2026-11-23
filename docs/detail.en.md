# TIA Portal Access (Openness)

Installing this plugin adds two things to DSH: the `tia-openness` skill and one
read-only diagnostic tool, `tia_openness_status`. The skill lets the agent drive a
local Siemens TIA Portal project through the Openness API without opening the TIA
GUI; the tool answers the question an agent asks first — can this machine run the
skill right now, and what exactly should be executed next.

## What it registers

- **The skill**: the payload in `tia-openness/` (`SKILL.md` + `references/` +
  `scripts/`) is registered as a runtime skill whose resource base is that
  directory, so the relative paths written in `SKILL.md` (`scripts\setup.ps1`,
  `references\troubleshooting.md`) keep resolving wherever the package is
  installed.
- **One read-only tool**: `tia_openness_status`, no arguments. It reads paths and
  environment variables only — it starts no process and writes no file. It reports
  the skill directory, which of the four scripts are present, whether
  `C:\ProgramData\TiaOpenness` exists, whether `bin\TiaOpen.exe` has been built,
  whether `config.json` has been written, which `Portal V*` installations are
  found, and a `nextStep` string with the exact command to run.
- Neither touches a PLC project: the actual work is done by the skill's
  PowerShell scripts, invoked by the agent as a visible action.

## Requirements

1. Windows.
2. TIA Portal **V15.1–V20**, installed with the Openness component; target CPUs
   are S7-1200 / S7-1500.
3. Administrator rights for the one-time setup (it writes
   `C:\ProgramData\TiaOpenness` and `HKLM\SOFTWARE\Siemens\Automation\Openness`).
4. Node.js >= 22 (shipped with DSH; you do not install it separately).

## One-time setup

After installing, call `tia_openness_status` once. If `nextStep` reports the setup
has not run, execute this in an **elevated** PowerShell (the script re-launches
itself when it is not):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<install path>\tia-openness\scripts\setup.ps1"
```

`setup.ps1` does three things: creates a dedicated local user (`TiaOpenness` by
default), compiles `scripts\tools\TiaOpen.cs` into
`C:\ProgramData\TiaOpenness\bin\TiaOpen.exe` with the .NET compiler, and registers
that exe's **SHA-256 plus last-write time** in the Openness firewall whitelist
while writing `C:\ProgramData\TiaOpenness\config.json` (which holds that user's
password).

> After editing `TiaOpen.cs` you must re-run `setup.ps1`: the whitelist is bound to
> the exe hash, and a freshly compiled exe is rejected until the entry is rewritten.

## Daily use

The skill has a fixed workflow (details in `tia-openness/SKILL.md`):

1. `scripts\stage-project.ps1 -Project "<path to .ap1x>"` — copy the project into
   `C:\ProgramData\TiaOpenness\work\` and grant the dedicated user access. The
   original project is never modified.
2. Write a job file and hand it to
   `scripts\run.ps1 -Job <file> -DataDir <dataDir>`.
3. Job actions: `info` (project and block inventory), `dump`, `export` (block XML
   and tag-table XML), `import` (block XML and, on V15.1+, tag-table XML),
   `compile` (verify), `saveas`, `selfcheck`.
4. Exit codes: `0` ok / `2` usage / `3` tool failure (including import or compile
   errors) / `4` timeout / `5` not elevated / `6` launch failed. The tool log is
   `C:\ProgramData\TiaOpenness\logs\<tag>.log`.

## Capabilities and limits

Supported: list projects, devices and block groups; export blocks as SCL or LAD
XML; edit SCL source and interfaces; import blocks; create DBs and their members;
import and export PLC tag tables (V15.1+); compile and read every error and
warning; save a project under a new name. System instructions such as `MC_Power`
resolve by name and need no extra file.

Not supported: download to the PLC, online monitoring or forcing, HMI/WinCC,
hardware configuration and telegram selection, creating technological objects,
dragging library blocks from the global library (`SINA_POS`, `FB_PN352`), deleting
blocks. Those still need one pass in the TIA GUI; the tool takes over the
iteration afterwards.

## Security model

- Every action starts a fresh logon as the dedicated user and runs `TiaOpen.exe`
  once; it exits afterwards. Nothing stays resident, no port is opened.
- Work happens on a **copy** under `work\`; the original project is untouched.
- The Openness whitelist is verified against the exe's SHA-256 plus last-write
  time, so a rebuilt exe requires a fresh `setup.ps1`.
- The password lives in `C:\ProgramData\TiaOpenness\config.json`; this plugin
  never reads or transmits it.

## Verification status

- `node --test test/smoke.mjs` passes; `tia_openness_status` returns correct results on a real
  machine, including both an installation outside `C:\Program Files` (it reads the Openness
  registry, not just the default directory) and an exe that predates the shipped source.
- `TiaOpen.cs` compiles with zero syntax errors under `csc` (only the Siemens types are
  unresolved), and the new method bodies were compiled against stubs.
- The **block pipeline (dump / export / import / compile) has been run against a real TIA
  Portal V20 project**. The **tag-table import added in this release** has only been verified
  at the code level so far, not yet through a full round trip on a real project.

On first use in a target environment, therefore: `export` the tag tables once, push the same
XML straight back through `import`, then `compile` — confirm `IMPORT TOTAL imported = N
errors = 0` before changing any program. Note also that after editing `TiaOpen.cs`,
`tia_openness_status` reports `exe matches shipped source: no`; re-run `setup.ps1` to rebuild
and rewrite the whitelist entry.

## Uninstalling

Remove the plugin from DSH; the skill and the tool disappear with it. To clean up
completely, delete `C:\ProgramData\TiaOpenness`, the local user created by
`setup.ps1`, and the Openness whitelist entry under
`HKLM\SOFTWARE\Siemens\Automation\Openness\<version>\Whitelist\TiaOpen.exe`.
