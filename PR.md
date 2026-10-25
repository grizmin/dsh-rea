# Update to REA 6.7.0

Branch `rea-6.7.0` · base `56268df` · version `0.4.0` → `0.5.0`

## Summary

Moves the pinned `rea-agents` dependency from **6.4.0** to **6.7.0** and removes the
hardcoded version and catalogue figures that made the previous pin change a
multi-file edit.

The adapter needed no functional change for this release — it reads the version and the
catalogue size from the installed package, and the transport, gating and prompt layers
worked unchanged across the jump. REA **6.6.0 was tagged upstream but never published to
npm**, so this branch skips it and carries its changes.

Two real defects were found and fixed along the way, plus one upstream issue documented
but not patched around.

The lazy-exposure gate also gains the three fixes this deployment had been carrying as a
local patch against the installed `node_modules` copy — `/rea off`, ordered history
replay, and the skill-registration crash. They are folded into the source here so no
downstream installation needs to re-apply them after an update.

## Catalogue delta

Measured from the live server with `node verify/measure.mjs`:

| | 6.4.0 | 6.7.0 |
|---|---:|---:|
| Tools | 170 | **207** |
| Prompts / arguments | 6 / 14 | 6 / **25** |
| Bundled skill | `v37`, `tool_count=170` | **`v42`, `tool_count=207`** |
| Native wire schema | 436,594 B | **775,022 B** |
| PTC prompt (SDK text) | 86,633 B | 126,045 B |

The native-exposure figure is the schema that rides along with every model request once
the catalogue is revealed; the PTC path stays at one wire tool. Both are re-measured in
`README.md`, `README.zh.md` and `verification/schema-measurement.json`, which keeps the
6.4.0 numbers as an explicit `previous` baseline rather than overwriting them.

## Changes

**Pin and de-hardcoding** (`De-hardcode the upstream version and catalog size`, `Pin rea-agents 6.7.0`)

- `upstreamVersion()` reads the pinned version from the installed package instead of a
  literal, so the unsupported-Node error and the activation logs cannot drift from the
  dependency.
- `verify/integration.mjs` and `verify/connection.mjs` derive the tool count from the
  server's own `tools/list` instead of asserting a literal `170`.
- `lib/gate.js`'s rationale comment states the measured 6.4.0 baseline explicitly instead
  of repeating a number that reads as current.
- `package.json`: `rea-agents` pinned to `6.7.0`; `@deepseek-ai/dsh-commands` and
  `dsh-scope` added as devDependencies so `verify:lazy` can run.

**Lazy-gate fixes** (`Support /rea off, replay /rea history in order, and fail closed`)

Three defects in the lazy catalogue gate, all of them observable in normal use:

1. **`/rea off` refused.** Re-hiding was deliberately unsupported, so the only way back to
   a gated session was a new session. `ReaVisibilityGate` gains `relock()`, which returns
   an agent to the gated set and re-installs the mask. `unlock()` stays one-way for
   everything else, so a mid-task `tools/change` re-sync still never takes the tools away
   on its own — only an explicit `/rea off` does.
2. **History replay was a latch.** `historyUnlocks()` treated *any* recorded
   `command/run` named `rea` as an unlock, including `/rea status` and `/rea off`. A
   session that had ever run one therefore got the whole catalogue back on **every
   reload** — the `413 preflight_compress_failed` this work started from. Records are now
   replayed in order (last `/rea` or `/rea off` wins, `/rea status` is not a state
   change), and an unreadable history fails **closed**.
3. **Skill registration crashed the host.** Under `exposure: lazy`, the unlock hook called
   `agent.ctx.skills.register(...)`. On DSH 0.2.1-rc.2 `agent.ctx` has no `skills` inject,
   so `/rea` threw `cannot get property skills without inject` and took the host down. The
   skill is now registered once through the plugin context and released again when no agent
   has the catalogue revealed, so `/rea off` stops paying for the skill line too. That
   lifecycle lives in `createSkillLifespan()` and is unit-testable without launching REA.

`applyMask()` also now disposes any mask already installed for an agent before installing
the new one; `relock()` can walk an agent back through gated states more than once, and
overwriting the map entry blindly leaked a live restriction that nothing could release.
The mask bookkeeping is shared with `unlock()` and the re-sync pass through a private
`#disposeMask()`.

**Comparison prompt title fix** (`Fix comparison prompt title after upstream rename`)

REA renamed the comparison prompt to `compare_application_versions`. The `/` menu title
map still keyed the old name, so `/rea:compare_versions` **silently fell back to the
English title** — a user-visible regression that no test caught. The map is corrected and
`test/plugin.test.mjs` now asserts every title key matches `prompts/list`, so the next
upstream rename fails the suite instead of degrading quietly.

**Verification harness fixes** (`Stop pnpm verify overwriting its evidence artifact, and gate the Node 23 skip`)

1. `verification/integration-report.json` was written in a `finally` block **even when the
   run had failed**. A failing run replaced the committed 35-check evidence artifact with
   a truncated one that stopped at the first failing assertion — the artifact claimed less
   than the project had actually verified, and the loss was invisible because the run's
   exit code was already non-zero. A failed run now leaves the last good report in place
   and reports through the exit code.
2. The check blocked by the upstream issue below is now an explicit, recorded skip rather
   than a hard failure. It gates on a **live probe of the actual error**, not on a version
   string, so it re-enables itself automatically once upstream hardens the check. There
   are no silent skips: the skip lands in `knownUpstreamFailures` in the report, in the
   report's `limitations`, and on stderr. On a supported Node there is no skip at all.

**Documentation** (`Update documentation for REA 6.7.0 and record the upstream Node 23 issue`)

- Both READMEs re-measured; `README.md` gained an "Upgrading the pinned REA release"
  section describing the four-step adopt-a-release procedure.
- `verification/README.md` records the 0.3.0 report as historical rather than rewriting it
  to current figures; `verification/codex-mapping.md` points at the 6.7.0 catalogue.
- `verification/upstream-issue-rea-integrity-mismatch.md` — new upstream issue draft.
- `CHANGELOG.md` — new, and added to the published `files` list.

**Line endings** (`Pin line endings so the mcp-bridge CRLF manifests stay stable`)

`.gitattributes` forces LF for the two files this repository compares byte-for-byte
(`lib/vendor/mcp-bridge.js` and its renderer), because `core.autocrlf` rewrote them in a
Windows working tree and made that comparison fail locally while passing in CI.
`pnpm-workspace.yaml` records the workspace root.

## Known upstream issue (documented, not patched around)

On **Windows under Node 23.x**, every directory-format artifact read fails:

```
integrity_mismatch: Directory entry changed before open
```

`DirectoryArtifactReader` compares a filesystem identity captured with `lstat()` against
one observed with `fstat()` on the opened handle. That Node line reports `dev: 0n` from
`lstat()` but the real volume serial from `fstat()`; the other five compared fields match
exactly. Measured across Node lines on the same machine and file:

| Node | `lstat().dev` | `fstat().dev` | Equal | In REA `engines` |
|---|---:|---:|---|---|
| `23.11.0` | `0n` | `2385388047n` | **no** | no |
| `22.19.0` | `2385388047n` | `2385388047n` | yes | yes (lowest) |
| `24.21.0` / `24.22.1` | `2385388047n` | `2385388047n` | yes | yes |

Node 23 is an odd-numbered, never-LTS line that REA's own `engines`
(`^22.19.0 || ^24.11.0 || >=26.0.0`) excludes, and the adapter already refuses it before
analysis begins. **No supported configuration is affected**, and this is not a Windows bug
or an REA 6.5.0+ regression in the sense the error text suggests.

We deliberately **do not** patch around it in the plugin: the check is upstream policy and
the adapter's job is to refuse an unsupported runtime, which it already does. The draft
carries a minimal reproduction with no plugin involved, the field comparison above, the
exact `DirectoryArtifactReader` location, and a one-line fix we validated by patching the
compiled `dist/` bundles and then restoring them to pristine bytes.

The user-visible complaint worth upstream attention is the error text: it tells the user
the artifact "contradicts declared integrity" and suggests
`integrity_policy=record-and-continue`, which sends them looking for a concurrent writer
that does not exist and for an escape hatch that does not work.

## Verification

Run on Windows 11, branch `rea-6.7.0`, working tree clean.

| Command | Node | Result |
|---|---|---|
| `pnpm test` | `23.11.0` | **68/68 pass**, 0 fail, 0 skipped |
| `pnpm test` | `24.22.1` | **68/68 pass**, 0 fail, 0 skipped |
| `pnpm verify:lazy` | `24.22.1` | **7/7 pass** |
| `pnpm verify` | `24.22.1` | **exit 0 — 35/35 checks, 0 fail, 0 known-upstream skips** |
| `pnpm verify` | `22.19.0` | **exit 0 — 35/35 checks, 0 fail, 0 known-upstream skips** |
| `pnpm verify` | `23.11.0` | 1 known-upstream skip (the Windows issue above), then stops on the environment limitation below |

`pnpm verify` on Node 24.22.1 reports:

```
upstream 6.7.0   node 24.22.1   toolCount 207
checks: 35   pass: 35   fail: 0   knownUpstreamFailures: 0   failure: none
modes: native {wireToolCount 207, toolSchemaBytes 775022, sdkTextBytes 0,    totalPromptBytes 775254}
       ptc    {wireToolCount 1,   toolSchemaBytes 944,    sdkTextBytes 126045, totalPromptBytes 128785}
```

The committed `verification/integration-report.json` is the Node 24.22.1 run above.

The lazy-gate commits are the ones that touch `lib/gate.js`, `lib/index.js` and
`lib/command.js`. Re-verified on `24.22.1` at the tip of this branch: `pnpm test` 68/68,
`pnpm verify:lazy` 7/7, `pnpm verify` exit 0 with 35/35 checks. Each new assertion was
mutation-checked — dropping the register-once guard, ignoring `unlockedCount` on relock,
treating any `/rea` record as an unlock, and failing open each fail the suite.

`verify:lazy` covers the 7 lazy-exposure checks: synthetic generation registers through
the real registry, the bridge generation stays globally registered, a gated agent carries
zero REA schemas before any reverse-engineering prompt, `/rea` is discoverable by the real
command service, the requesting agent gains all 12 bridge schemas while a concurrent
session stays gated, scope lookup mirrors the assembly, and a re-sync re-masks gated
agents while leaving unlocked agents alone.

Independently spot-checked rather than trusted from the suite:

- `upstreamVersion()` → `6.7.0`; bundled skill metadata → `v42`, `tool_count=207`
- Prompt count/arguments from the live server → 6 prompts, 25 arguments
- `verification/schema-measurement.json` parses and matches the report's byte figures
- The report-preservation fix, by re-running a failing verification and confirming
  `verification/integration-report.json` was left byte-identical (`git status` clean)

## Not verified here

Stated explicitly so this branch does not overclaim:

- **`pnpm verify:connection`** — fails at
  `Error: Cannot find module '@deepseek-ai/dsh-host-webserver'`. It needs a DSH module
  root resolving `dsh-host-webserver`/`dsh-client-connection`/`cordis`; this install keeps
  those inside `app.asar`, so no resolvable module root exists on this machine. The
  untested area is the HTTP route behind the Connection fence.
- **`verify/check-bundle.mjs`** and **`verify/live-host.mjs`** — fail at
  `connect ECONNREFUSED 127.0.0.1:19387`. Both need a live DSH Host listening on that
  port. Not started, per the instruction not to run a replacement server.
- Neither of the above is wired into `pnpm test` or `pnpm verify`, and neither is
  documented in the README as a standard script.

Environment limitations encountered, recorded so a reviewer can reproduce or dismiss them:

- This machine's Node was upgraded from `23.11.0` to `24.22.1` partway through the work.
  `23.11.0` is outside REA's `engines`, so on it the adapter correctly refuses to activate
  and `pnpm verify` cannot complete past that point. The `22.19.0` and `24.22.1` numbers
  above are the ones that represent a supported configuration.
- The Node upgrade left the corepack `pnpm` shim pointing at the removed
  `...\corepack\v1\pnpm\12.15.0\bin\pnpm.cjs`; pnpm 12.15.0's entrypoint is now
  `...\corepack\v1\pnpm\12.15.0\bin\pnpm.mjs`. Commands above were run via that entrypoint.
  This is a local toolchain
  issue, unrelated to the branch and nothing in this PR depends on it.
- `pnpm verify` was not run on Linux/macOS. The lazy-exposure and integration suites are
  platform-neutral in design, but that is an expectation, not a measurement.

## Not done

- **No commits were pushed.** The branch is local.
- **No npm publish.** Version bumped to `0.5.0` for the release; publishing is a separate
  decision.
- **No upstream issue filed.** `verification/upstream-issue-rea-integrity-mismatch.md` is
  a draft.