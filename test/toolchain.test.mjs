import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { pathToFileURL } from 'node:url'
import * as plugin from '../lib/index.js'

/**
 * scripts/setup-rea-tools.ps1 installs the Ghidra / JADX / WABT / JDK toolchain
 * that upstream REA requires. Those pins are also asserted here against the
 * *installed* rea-agents release, so a REA bump that changes a pin fails this
 * test until the script is updated to match. Without this the script would
 * silently install a toolchain the bridged REA refuses to use.
 */

const scriptPath = join(import.meta.dirname, '..', 'scripts', 'setup-rea-tools.ps1')

/** Read the script once; every assertion below works off the same text. */
async function readScript() {
  return readFile(scriptPath, 'utf8')
}

/**
 * Extract `$NAME = 'value'` or `$NAME = "value"` from the PowerShell script.
 * Double quotes are accepted because the script interpolates some pins.
 * @param {string} source script text
 * @param {string} name variable name without the leading $
 * @returns the pinned literal, or undefined when the variable is absent
 */
function pin(source, name) {
  const match = source.match(new RegExp(`\\$${name}\\s*=\\s*['"]([^'"]*)['"]`))
  return match?.[1]
}

/**
 * Import a module from the installed upstream package. The upstream modules are
 * plain ESM, so the package root reported by the plugin is enough to resolve them.
 * @param {string} relativePath path under the rea-agents package root
 */
async function importUpstream(relativePath) {
  const url = pathToFileURL(join(plugin.upstreamPaths().root, relativePath)).href
  return import(url)
}

test('toolchain script pins match the installed rea-agents requirements', async () => {
  const source = await readScript()

  const ghidra = await importUpstream('dist/ghidra/GhidraReleasePolicy.js')
  const jadx = await importUpstream('dist/android/JadxRelease.js')
  const wabt = await importUpstream('dist/wasm/WabtRelease.js')

  assert.equal(
    pin(source, 'GHIDRA_VER'),
    ghidra.SUPPORTED_GHIDRA_VERSION,
    'setup-rea-tools.ps1 Ghidra pin differs from the installed rea-agents requirement',
  )
  assert.equal(
    pin(source, 'JDK_MAJOR'),
    String(ghidra.SUPPORTED_GHIDRA_JAVA_MAJOR),
    'setup-rea-tools.ps1 JDK pin differs from the JDK rea-agents requires for Ghidra',
  )
  assert.equal(
    pin(source, 'JADX_VER'),
    jadx.JADX_RELEASE.version,
    'setup-rea-tools.ps1 JADX pin differs from the installed rea-agents requirement',
  )
  assert.equal(
    pin(source, 'JADX_SHA256'),
    jadx.JADX_RELEASE.sha256,
    'setup-rea-tools.ps1 JADX checksum differs from the one rea-agents verifies against',
  )
  assert.equal(
    pin(source, 'WABT_VER'),
    String(wabt.WABT_PROVIDER_IDENTITY.version).replace(/^wabt@/, ''),
    'setup-rea-tools.ps1 WABT pin differs from the installed rea-agents requirement',
  )
})

test('toolchain script derives its REA version from the package pin', async () => {
  const source = await readScript()
  const pkg = JSON.parse(await readFile(join(import.meta.dirname, '..', 'package.json'), 'utf8'))

  // The script must not hardcode a REA version: it reads package.json so the
  // Cutter bridge plugin it fetches always matches the REA the plugin bridges.
  assert.equal(
    pin(source, 'REA_PKG'),
    `rea-agents@$REA_VER`,
    'the script should build the REA package spec from the derived $REA_VER',
  )
  assert.ok(
    /dependencies\.'rea-agents'/.test(source),
    'the script should read the rea-agents pin out of package.json',
  )
  assert.ok(
    /\[string\]\$ReaVersion/.test(source),
    'the script should expose a -ReaVersion override',
  )
  assert.match(pkg.dependencies['rea-agents'], /^\d+\.\d+\.\d+$/, 'the package must pin an exact rea-agents version')
  assert.equal(
    plugin.upstreamVersion(),
    pkg.dependencies['rea-agents'],
    'the installed rea-agents must match the declared pin',
  )
})

test('toolchain script covers the providers Windows REA can actually drive', async () => {
  const source = await readScript()
  for (const marker of [
    'GHIDRA_INSTALL_DIR',
    'JAVA_HOME',
    'REA_OBJDUMP_COMMAND',
    'REA_RIZIN_COMMAND',
    'REA_WABT_BIN_DIRECTORY',
    'REA_JADX_MCP_JAR',
    'rea_bridge.py',
  ]) {
    assert.ok(source.includes(marker), `setup-rea-tools.ps1 no longer exports ${marker}`)
  }
})