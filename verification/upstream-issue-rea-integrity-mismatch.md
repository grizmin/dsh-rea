# Upstream issue draft: `integrity_mismatch` on Windows under Node 23.x

> **Correction, measured after the first draft.** This was initially reported as a
> Windows platform bug present in 6.5.0–6.7.0. It is narrower than that: the
> divergence is a **Node 23.x** behaviour, not a Windows behaviour and not an REA
> regression. Node 22.19.0 and Node 24.21.0 both report a matching `dev`, and
> `pnpm verify` passes 35/35 on both. Node 23 is an odd-numbered (non-LTS) line
> that REA's own `engines` field excludes, so no supported configuration is
> affected. See "Affected versions" and "Field comparison" below for the
> corrected measurements. The report is kept for upstream because the failure is
> still reachable on Node 23 and the error message is misleading when it happens.

Status: **draft, not yet filed, and now low priority.** It reproduces only on an
unsupported Node line. It is unrelated to the DSH adapter in this repository: the
failure reproduces with no plugin, no DSH and no MCP client involved.

---

## Title

`DirectoryArtifactReader` reports `integrity_mismatch` on Windows under Node 23.x, where `lstat().dev` is `0n` but `fstat().dev` is the volume serial

## Summary

On Windows under Node 23.x, `analyze_javascript_application` (and every other tool
that reads an artifact) fails with:

```
integrity_mismatch: Directory entry changed before open
```

The bytes did not change. The check compares a filesystem identity captured with
`lstat()` against one observed with `fstat()` on the opened handle, and on this Node
line those two calls disagree on exactly one field: `dev`. Node 23.x reports `dev: 0n`
from `lstat()` on Windows, while `fstat()` on the opened handle reports the real volume
serial number. Every other compared field is identical, so the mismatch is a false
positive.

The same code reports matching `dev` and passes on Node 22.19.0 and Node 24.21.0, so
this is a Node-version-dependent divergence rather than a Windows-wide one.

## Affected versions

- **REA:** all versions carrying the check, i.e. `6.5.0` – `6.7.0`. Not present in
  `6.4.0`.

  | Version | `sameArtifactSourceIdentity` present |
  |---|---|
  | 6.4.0 | no |
  | 6.5.0 | yes |
  | 6.7.0 | yes |

- **Node:** `23.x` only, as far as we measured. `22.19.0` and `24.21.0` are unaffected.
  Node 23 is not in REA's declared `engines` (`^22.19.0 || ^24.11.0 || >=26.0.0`), so
  this is reachable only when a caller overrides `nodeCommand` with an unsupported
  Node, or runs the CLI directly on Node 23.

## Platform

- OS: Windows (`win32`), Windows 11 build `10.0.26200`, NTFS
- Node: **`23.11.0` reproduces**; `22.19.0` and `24.21.0` do **not**

We did not test Linux/macOS on Node 23; on the supported lines the fields agree
everywhere we tested.

## Minimal reproduction

No plugin, no DSH, no MCP client. Plain Node plus the published package:

```js
// repro.mjs — writes a fixture, then asks REA to analyze it.
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const dir = mkdtempSync(join(tmpdir(), 'rea-repro-'))
writeFileSync(join(dir, 'index.js'), 'export const ok = 1\n')

const client = new Client({ name: 'repro', version: '1' }, { capabilities: {} })
await client.connect(new StdioClientTransport({
  command: process.execPath,
  args: ['node_modules/rea-agents/scripts/rea.mjs', 'mcp'],
  stderr: 'pipe',
}))

const result = await client.callTool({
  name: 'analyze_javascript_application',
  arguments: { input_path: dir, format: 'directory' },
}, undefined, { timeout: 300000 })

console.log('isError:', result.isError)
console.log(result.content.find(c => c.type === 'text').text)
await client.close()
```

Observed:

```json
{
  "error": {
    "code": "artifact_operation_failed",
    "category": "integrity_mismatch",
    "message": "Artifact bytes contradict declared integrity. If expected, rerun analyze_javascript_application with integrity_policy=record-and-continue (CLI: --integrity-policy record-and-continue) to retain observed bytes as untrusted; otherwise get a fresh copy.",
    "retryable": false,
    "details": {
      "operation": "analyze_javascript_application",
      "reason": "integrity",
      "detail": "Directory entry changed before open: index.js"
    }
  }
}
```

`isError: true` and no Evidence is produced.

Notes on the reproduction:

- The fixture is written **before** the client starts and is never written again, so no
  file is genuinely mutating. Waiting between the write and the call does not help.
- A single-file fixture and a realistic multi-file JS app (`package.json`, `src/*.js`)
  both fail identically.
- `integrity_policy: "record-and-continue"` **does not** avoid it — the same error is
  returned, so the documented escape hatch does not work either.
- `format: "directory"` is the failing path. (Separately, `format: "file"` is no longer
  a valid enum value; only `auto`, `asar` and `directory` are accepted in 6.7.0.)

## The field comparison we measured

The underlying divergence, with no REA code involved at all:

```js
import { lstatSync, openSync, fstatSync, constants } from 'node:fs'

const a = lstatSync(path, { bigint: true })
const h = openSync(path, constants.O_RDONLY)
const b = fstatSync(h, { bigint: true })
```

**Across Node versions on the same Windows 11 machine and the same file** — this is the
measurement that narrows the report:

| Node | `lstat().dev` | `fstat().dev` | Equal | REA `engines` |
|---|---:|---:|---|---|
| `23.11.0` | `0n` | `2385388047n` | **no** | not allowed |
| `22.19.0` | `2385388047n` | `2385388047n` | yes | lowest supported |
| `24.21.0` | `2385388047n` | `2385388047n` | yes | supported |

Under Node 23.11.0, `dev` is the **only** field that differs:

| Field | `lstat()` | `fstat()` on opened handle | Equal |
|---|---|---|---|
| `dev` | `0n` | `2385388047n` | **no** |
| `ino` | `6473924467985198n` | `6473924467985198n` | yes |
| `size` | `20n` | `20n` | yes |
| `mode` | `33206n` | `33206n` | yes |
| `mtimeNs` | `1792911131172399100n` | `1792911131172399100n` | yes |
| `ctimeNs` | `1792911131172399100n` | `1792911131172399100n` | yes |

On the supported lines every one of the six fields matches, `sameArtifactSourceIdentity`
returns true, and analysis succeeds.

This is a documented Node/libuv characteristic on Windows: `lstat()` may not obtain the
volume serial and reports `0`, whereas `fstat()` on a real handle reports it. The
`0`-vs-serial behaviour appears to have been corrected on the 22/24 lines.

## End-to-end result on supported Node

For completeness, since it is the more important finding: on the supported lines the
end-to-end verification suite passes with **no skips**:

| Node | `pnpm verify` result |
|---|---|
| `22.19.0` | exit 0 — 35/35 checks, 207 tools, 0 known-upstream failures |
| `24.21.0` | exit 0 — 35/35 checks, 207 tools, 0 known-upstream failures |

So this issue does **not** block any supported REA configuration, and the DSH adapter
correctly refuses Node 23 before analysis begins.

## Location in the code

`dist/artifacts/ArtifactReader.js`:

```js
export const sameArtifactSourceIdentity = (expected, observed) => expected !== undefined &&
    observed.dev === expected.device &&
    observed.ino === expected.inode &&
    observed.size === expected.size &&
    observed.mode === expected.mode &&
    observed.mtimeNs === expected.mtimeNs &&
    observed.ctimeNs === expected.ctimeNs;
```

The two sides are produced by different syscalls:

- **expected** — `dist/artifacts/DirectoryArtifactReader.js`, during directory traversal:

  ```js
  const metadata = await lstat(absolute, { bigint: true })
  // ...
  sourceIdentity: {
      device: metadata.dev,
      inode: metadata.ino,
      size: metadata.size,
      mode: metadata.mode,
      mtimeNs: metadata.mtimeNs,
      ctimeNs: metadata.ctimeNs,
  }
  ```

- **observed** — the same file, when the entry is opened:

  ```js
  const observed = await owner.handle.stat({ bigint: true })
  if (!observed.isFile() ||
      !sameArtifactSourceIdentity(entry.sourceIdentity, observed)) {
      throw new ArtifactReaderFailure("integrity", `Directory entry changed before open: ${entry.path}`);
  }
  ```

So the before/after comparison mixes an `lstat` observation with an `fstat` observation.
On POSIX those are interchangeable; on Windows they are not.

## Fix we validated

Treat a `0n` device as "unknown" rather than as a value to compare, i.e. accept the pair
when either side reports `0n`:

```js
const sameDevice = observed.dev === 0n || expected.device === 0n ||
                   observed.dev === expected.device
```

or equivalently compare the fields that actually identify a file on Windows
(`ino` + `size` + `mtimeNs` + `ctimeNs`, and `mode`) and only compare `dev` when both
sides are non-zero.

We validated this by patching the compiled `dist/` bundles in place
(`dist/mcp/ArtifactReader-*.js` and `dist/cli-runtime/ArtifactReader-*.js`) with that
one-line change and re-running the reproduction above:

- before: `isError: true`, `integrity_mismatch`
- after: `isError: undefined`, valid Evidence returned, e.g.
  `evidence_id: ev_89899df5de6c5d640529603a4dba915fdfdea75c5b8ffdcbf55bf45b00a3a145`

The patched package was then restored to pristine bytes; we do not ship this patch.

### Why not just skip `dev`

Dropping `dev` entirely would weaken the check on POSIX, where it legitimately guards
against a bind-mount or device swap. Gating the comparison on both sides being non-zero
keeps the POSIX behaviour identical and only relaxes the case that cannot be compared
meaningfully on Windows. The remaining five fields still detect a real
replace-during-traversal, which is the case this check exists for.

## Suggested resolution

1. Make the `dev` comparison tolerant of `0n` on either side (preferred), or
2. Capture both identities with the same syscall where possible, and only fall back to
   `lstat` where no handle exists yet, documenting that `dev` is unreliable on win32, or
3. Explicitly disable the `dev` field on `process.platform === 'win32'` with a comment
   explaining the libuv behaviour.

Whichever is chosen, it would be good for the error text to distinguish "the file really
changed" from "this platform cannot compare the field", because the current message
sends users looking for a concurrent writer that does not exist.

## Impact

Limited: only Windows **and** Node 23.x together. Every directory-format analysis fails
at the first file open under that combination. Because the check runs on each entry, the
fixture cannot be shaped to avoid it, and the documented `record-and-continue`
workaround does not bypass it. Tools that read artifacts through
`DirectoryArtifactReader` are affected.

No supported configuration is affected: Node 22.19.0 and Node 24.21.0 both pass the full
verification suite 35/35, and REA's `engines` excludes Node 23.

## Recommended upstream action

Given the narrowness, the pragmatic ask is **not** a structural change but a better
failure path: the current message tells the user the artifact "contradicts declared
integrity" and suggests re-running with `record-and-continue`, which sends them looking
for a concurrent writer that does not exist and for an escape hatch that does not work.
Both would be improved by:

1. Detecting the Node-23-on-Windows case explicitly and naming it, since REA already
   knows its own supported range and already refuses unsupported Node in the CLI path.
2. Keeping the `dev` comparison tolerant of `0n` on either side as a cheap safety net
   (the validated fix below), so an unsupported runtime degrades to a warning instead of
   a hard `integrity_mismatch`.