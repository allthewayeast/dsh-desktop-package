/** User-owned startup configuration: env overrides and Electron switches from a JSON file beside the executable. */

import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readSync,
} from 'node:fs'
import type { Stats } from 'node:fs'
import { join } from 'node:path'
import { DESKTOP_PACKAGE_NAME } from './product-identity.ts'

/** File name read from the executable directory. */
export const DESKTOP_STARTUP_CONFIG_FILENAME = 'startup.json'

/** Bounded size accepted for the user-owned startup configuration. */
export const DESKTOP_STARTUP_CONFIG_MAX_BYTES = 64 * 1024

/** A single Chromium/Electron switch to append before the app becomes ready. */
export interface DesktopStartupConfigSwitch {
  readonly name: string
  /** `null` appends a valueless switch. */
  readonly value: string | null
}

/** Applied startup configuration: env entries the caller may set and switches to append. */
export interface DesktopStartupConfigResult {
  /** Env entries to materialize; only names absent from the environment are included. */
  readonly envUpdates: ReadonlyArray<readonly [string, string]>
  readonly switches: ReadonlyArray<DesktopStartupConfigSwitch>
}

export interface DesktopStartupConfigOptions {
  readonly configPath: string
  readonly environment: NodeJS.ProcessEnv
}

export type DesktopStartupConfigErrorCode = 'invalid' | 'unsafe' | 'unreadable'

export class DesktopStartupConfigError extends Error {
  constructor(
    readonly code: DesktopStartupConfigErrorCode,
    message: string,
  ) {
    super(`${DESKTOP_PACKAGE_NAME}: ${message}`)
    this.name = 'DesktopStartupConfigError'
  }
}

/**
 * Names no startup config may set: they decide how the process, runtime,
 * VCS, or network bootstrap. `PATH` is the deliberate exception — see
 * `applyDesktopStartupConfig` — so a user can prepend directories with a
 * `%PATH%` reference without replacing the inherited search path.
 */
const BOOTSTRAP_NAMES = new Set([
  'HOME',
  'USERPROFILE',
  'SHELL',
  'NODE_OPTIONS',
  'NODE_PATH',
  'NODE_EXTRA_CA_CERTS',
  'LD_PRELOAD',
  'LD_LIBRARY_PATH',
  'LD_AUDIT',
  'BASH_ENV',
  'ENV',
  'SHELLOPTS',
  'BASHOPTS',
  'PERL5OPT',
  'PERL5LIB',
  'PYTHONSTARTUP',
  'PYTHONPATH',
  'RUBYOPT',
  'RUBYLIB',
  'JAVA_TOOL_OPTIONS',
  '_JAVA_OPTIONS',
  'JDK_JAVA_OPTIONS',
  'PYTHONHOME',
  'GIT_SSH',
  'GIT_SSH_COMMAND',
  'GIT_EXTERNAL_DIFF',
  'GIT_PAGER',
  'GIT_EDITOR',
  'GIT_ASKPASS',
  'SSH_ASKPASS',
  'GIT_CONFIG_GLOBAL',
  'GIT_CONFIG_SYSTEM',
  'GIT_CONFIG_COUNT',
  'EDITOR',
  'VISUAL',
  'PAGER',
  'BROWSER',
  'DEEPSEEK_BASE_URL',
  'DEEPSEEK_SEARCH_BASE_URL',
  'SSL_CERT_FILE',
  'SSL_CERT_DIR',
  'HTTP_PROXY',
  'HTTPS_PROXY',
  'ALL_PROXY',
  'NO_PROXY',
  'REQUESTS_CA_BUNDLE',
  'CURL_CA_BUNDLE',
  'NODE_TLS_REJECT_UNAUTHORIZED',
])

/** Name prefixes no startup config may set, mirroring the .env bootstrap-only rule. */
const BOOTSTRAP_PREFIXES = [
  'DSH_',
  'XDG_',
  'DYLD_',
  'BASH_FUNC_',
] as const

/**
 * `DSH_*` names a user-owned startup config may set. The file lives next to the
 * executable the user launched, so the Home override and the telemetry opt-out
 * are safe; every other `DSH_*` name keeps changing how the process starts and
 * stays refused.
 */
const DSH_ALLOWED_NAMES = new Set(['DSH_HOME', 'DSH_TELEMETRY_DISABLED'])

/** Whether a variable may come only from the inherited process environment. */
function isBootstrapOnly(name: string): boolean {
  const upper = name.toUpperCase()
  return BOOTSTRAP_NAMES.has(upper) || BOOTSTRAP_PREFIXES.some(prefix => upper.startsWith(prefix))
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

/** Parse and validate the JSON document into the supported version-one shape. */
function parseStartupConfig(text: string): DesktopStartupConfigResult {
  let value: unknown
  try {
    value = JSON.parse(text) as unknown
  } catch (cause) {
    throw new DesktopStartupConfigError('invalid', `startup config must contain valid JSON: ${cause instanceof Error ? cause.message : String(cause)}`)
  }
  if (!isPlainRecord(value) || value.version !== 1) {
    throw new DesktopStartupConfigError('invalid', 'startup config must be an object with "version": 1')
  }
  if (value.env !== undefined && !isPlainRecord(value.env)) {
    throw new DesktopStartupConfigError('invalid', 'startup config "env" must be an object of string values')
  }
  if (value.electron !== undefined && !isPlainRecord(value.electron)) {
    throw new DesktopStartupConfigError('invalid', 'startup config "electron" must be an object')
  }
  const env = value.env as Record<string, unknown> | undefined
  const electron = value.electron as Record<string, unknown> | undefined
  if (electron !== undefined && electron.switches !== undefined && !Array.isArray(electron.switches)) {
    throw new DesktopStartupConfigError('invalid', 'startup config "electron.switches" must be an array')
  }
  const switches: DesktopStartupConfigSwitch[] = []
  for (const raw of (electron?.switches ?? []) as unknown[]) {
    if (!isPlainRecord(raw) || typeof raw.name !== 'string' || !/^[a-z0-9][a-z0-9-]*$/u.test(raw.name)) {
      throw new DesktopStartupConfigError('invalid', 'each startup config switch needs a lowercase name like "disable-gpu"')
    }
    const valueOf = raw.value
    if (valueOf !== undefined && valueOf !== null && typeof valueOf !== 'string') {
      throw new DesktopStartupConfigError('invalid', `startup config switch "${raw.name}" value must be a string`)
    }
    switches.push({ name: raw.name, value: valueOf === undefined || valueOf === null ? null : valueOf })
  }
  const envUpdates: Array<readonly [string, string]> = []
  for (const [name, rawValue] of Object.entries(env ?? {})) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/u.test(name)) {
      throw new DesktopStartupConfigError('invalid', `startup config env name ${JSON.stringify(name)} is not a valid variable name`)
    }
    if (typeof rawValue !== 'string') {
      throw new DesktopStartupConfigError('invalid', `startup config env "${name}" must be a string`)
    }
    const upper = name.toUpperCase()
    if (isBootstrapOnly(name) && !DSH_ALLOWED_NAMES.has(upper)) {
      throw new DesktopStartupConfigError(
        'unsafe',
        `startup config sets "${name}", which only the launching environment may set (it decides how this process starts, where its code and instructions load from, or how it reaches the network)`,
      )
    }
    envUpdates.push([name, rawValue])
  }
  return { envUpdates, switches }
}

function existingFileInfo(path: string): Stats | undefined {
  try {
    return lstatSync(path)
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code === 'ENOENT') return undefined
    throw cause
  }
}

function readBoundedUtf8(path: string): string {
  const info = existingFileInfo(path)
  if (info === undefined) throw new DesktopStartupConfigError('unreadable', `startup config not found: ${path}`)
  if (!info.isFile() || info.isSymbolicLink()) {
    throw new DesktopStartupConfigError('unsafe', `startup config must be a real file: ${path}`)
  }
  if (info.size > DESKTOP_STARTUP_CONFIG_MAX_BYTES) {
    throw new DesktopStartupConfigError('invalid', `startup config exceeds ${String(DESKTOP_STARTUP_CONFIG_MAX_BYTES)} bytes: ${path}`)
  }
  let descriptor: number
  try {
    descriptor = openSync(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  } catch (cause) {
    throw new DesktopStartupConfigError('unreadable', `startup config is unreadable: ${cause instanceof Error ? cause.message : String(cause)}`)
  }
  try {
    const descriptorInfo = fstatSync(descriptor)
    if (!descriptorInfo.isFile() || descriptorInfo.size > DESKTOP_STARTUP_CONFIG_MAX_BYTES
      || descriptorInfo.dev !== info.dev || descriptorInfo.ino !== info.ino) {
      throw new DesktopStartupConfigError('unsafe', 'startup config changed while it was being opened')
    }
    const bytes = Buffer.alloc(DESKTOP_STARTUP_CONFIG_MAX_BYTES + 1)
    let offset = 0
    while (offset < bytes.byteLength) {
      const count = readSync(descriptor, bytes, offset, bytes.byteLength - offset, null)
      if (count === 0) break
      offset += count
    }
    if (offset > DESKTOP_STARTUP_CONFIG_MAX_BYTES) {
      throw new DesktopStartupConfigError('invalid', `startup config exceeds ${String(DESKTOP_STARTUP_CONFIG_MAX_BYTES)} bytes`)
    }
    try {
      return new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, offset))
    } catch {
      throw new DesktopStartupConfigError('invalid', 'startup config must contain valid UTF-8')
    }
  } finally {
    closeSync(descriptor)
  }
}

/**
 * Resolve the startup-config path: `startup.json` beside the executable.
 * @param executableDir - directory of the launched executable (`dirname(process.execPath)`).
 * @returns the absolute config path.
 */
export function resolveStartupConfigPath(executableDir: string): string {
  return join(executableDir, DESKTOP_STARTUP_CONFIG_FILENAME)
}

/**
 * Expand Windows-style `%NAME%` references against the current environment.
 * A missing variable expands to an empty string, matching `cmd.exe` semantics,
 * so values like `E:\tools;%PATH%` can append to (or preserve) existing
 * variables. Lookup is case-insensitive, as on Windows.
 */
function expandEnvironmentReferences(value: string, environment: NodeJS.ProcessEnv): string {
  return value.replace(/%([A-Za-z_][A-Za-z0-9_]*)%/gu, (_match, name: string) => {
    return environment[name] ?? environment[name.toUpperCase()] ?? environment[name.toLowerCase()] ?? ''
  })
}

/**
 * Load and apply the user-owned startup configuration. A missing file means
 * "no configuration"; a present file that cannot be read, parsed, or applied is
 * a misconfiguration and throws. Env entries already present in the
 * environment are left untouched, so a temporarily exported variable still
 * wins over the file — except `PATH`, which is always applied (after `%NAME%`
 * expansion) so a startup config can prepend directories to the inherited
 * search path.
 * @param options - resolved config path and the environment to consult.
 * @returns env entries to materialize and Electron switches to append.
 */
export function applyDesktopStartupConfig(options: DesktopStartupConfigOptions): DesktopStartupConfigResult {
  const info = existingFileInfo(options.configPath)
  if (info === undefined) return { envUpdates: [], switches: [] }
  const parsed = parseStartupConfig(readBoundedUtf8(options.configPath))
  const envUpdates = parsed.envUpdates
    .map(([name, value]) => [name, expandEnvironmentReferences(value, options.environment)] as const)
    .filter(([name]) => name.toUpperCase() === 'PATH' || options.environment[name] === undefined)
  return { envUpdates, switches: parsed.switches }
}
