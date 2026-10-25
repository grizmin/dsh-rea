# Changelog

Notable changes to `dsh-rea`, the DeepSeek Harness adapter for
[REA](https://github.com/morluto/rea). This adapter pins an exact REA release, so the
upstream version is part of every entry.

## 0.5.1 — fork tooling

Fork-only release. No upstream-bound changes; `rea-agents` stays pinned at **6.7.0**.

### Added

- `scripts/setup-rea-tools.ps1`, a Windows toolchain bootstrapper for this fork. It
  installs the Ghidra 12.1.4 / Temurin JDK 21 / JADX 0.7.1 / WABT 1.0.42 / Rizin /
  objdump providers REA drives into one self-contained root, reads the REA version from
  the `rea-agents` pin in `package.json`, and prints the plugin config block to paste.
- `test/toolchain.test.mjs`, which asserts the script's provider pins against the
  *installed* `rea-agents` release, so a REA bump fails the suite until the script is
  updated to match.

## 0.5.0 — REA 6.7.0

Pins `rea-agents` at **6.7.0**, up from `6.4.0`. REA 6.6.0 was tagged upstream but never
published to npm, so this release skips it and carries its changes.

### Added

- `upstreamVersion()` now reads the pinned version from the installed package instead of
  a hardcoded literal. The unsupported-Node error and the activation log lines use it, so
  they can no longer disagree with the dependency.
- `README.md` gained an "Upgrading the pinned REA release" section: change the pin,
  re-measure, re-verify, update the documented figures.
- `verification/upstream-issue-rea-integrity-mismatch.md`, a draft upstream report for an
  `integrity_mismatch` that reproduces on Windows under Node 23.x.

### Changed

- **Catalog: 170 → 207 tools.** Model-side schema grows 436,594 → **775,022 bytes** per
  request in native exposure. Prompts stay at 6 with 14 → **25** arguments; the bundled
  skill is `v42` with `tool_count=207` (was `v37`/`170`).
- Documentation figures in `README.md`, `README.zh.md` and `verification/README.md`
  updated to the re-measured values, with the 6.4.0 numbers kept as an explicit
  `previous` baseline in `verification/schema-measurement.json`.
- `verify/integration.mjs` and `verify/connection.mjs` derive the tool count from the
  server's own `tools/list` instead of asserting a literal `170`, so the next REA release
  does not need them edited.

### Fixed

- **Prompt title regression from the upstream rename.** REA renamed the comparison prompt
  to `compare_application_versions`; the `/` menu title map still keyed the old name, so
  `/rea:compare_versions` silently fell back to the English title. The map is corrected
  and `test/plugin.test.mjs` now fails if a key stops matching `prompts/list`, so the next
  upstream rename is caught instead of degrading quietly.
- **`/rea off` now hides the catalogue again.** Re-hiding was deliberately unsupported, so
  the only way back to a gated session was a new session. `ReaVisibilityGate.relock()`
  returns an agent to the gated set and re-installs the mask; `unlock()` stays one-way for
  everything else, so a mid-task re-sync still cannot take the tools away by itself.
- **Recorded `/rea` history is replayed instead of latched.** Any stored `command/run`
  named `rea` counted as an unlock — including `/rea status` and `/rea off` — so a session
  that had ever run one got the whole catalogue back on every reload (the
  `413 preflight_compress_failed` this started from). The last `/rea` or `/rea off` now
  decides, `/rea status` is not a state change, and an unreadable history fails closed.
- **`/rea` no longer crashes the host under `exposure: lazy`.** The unlock hook called
  `agent.ctx.skills.register(...)`, but `agent.ctx` has no `skills` inject on DSH
  0.2.1-rc.2, so it threw `cannot get property skills without inject`. The skill is
  registered once through the plugin context and released again once no agent has the
  catalogue revealed, so `/rea off` stops paying for the skill line too.
- **`applyMask()` disposes the mask it replaces.** `relock()` can walk an agent back
  through gated states more than once, and overwriting the map entry leaked a live
  restriction that nothing could release.
- **`pnpm verify` overwrote its own evidence artifact on failure.**
  `verification/integration-report.json` was written in a `finally` block even when the run
  had failed, replacing the committed 35-check report with a truncated one that stopped at
  the first failing assertion. A failed run now leaves the last good report in place and
  reports through the exit code.

### Known issues

- On **Windows under Node 23.x**, artifact reads fail with
  `integrity_mismatch: Directory entry changed before open`. `DirectoryArtifactReader`
  compares an `lstat()` observation against an `fstat()` one and that Node line reports
  `dev: 0n` for the former but the real volume serial for the latter; every other compared
  field matches. Node 22.19.0 and 24.21.0 — both inside REA's declared `engines` — agree,
  so no supported configuration is affected and the adapter refuses Node 23 before analysis
  begins. The affected differential check is reported as a known upstream skip with a
  reason string rather than failing, and re-enables itself automatically once the probe
  succeeds. Details and a validated one-line fix:
  `verification/upstream-issue-rea-integrity-mismatch.md`.

### Verification

`pnpm test` 68/68 and `pnpm verify:lazy` 7/7 on Node 22.19.0, 23.11.0 and 24.22.1.
`pnpm verify` 35/35 with zero skips on Node **22.19.0** and **24.22.1**. On Node 23.11.0
it reports one known upstream skip (the Windows issue above) and one environmental stop.

`verify:connection` and `check-bundle`/`live-host` were **not** re-run: the first needs
DSH modules that this install keeps inside `app.asar`, the second needs a live Host. See
`PR.md` for the full "not verified here" list.

## 0.4.0 — REA 6.4.0

- `/rea` reveals the REA catalog on demand instead of mounting all 170 tools for every
  session, cutting the gated case to a 2-byte schema. Lazy exposure has its own suite
  (`verify/lazy-exposure.mjs`).
- Public tool prefix moved from `rea__` to `mcp__rea__` to match DSH's official bridge.