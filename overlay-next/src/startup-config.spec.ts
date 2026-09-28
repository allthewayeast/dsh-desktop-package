import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  applyDesktopStartupConfig,
  DESKTOP_STARTUP_CONFIG_FILENAME,
  DESKTOP_STARTUP_CONFIG_MAX_BYTES,
  DesktopStartupConfigError,
  resolveStartupConfigPath,
} from '../src/startup-config.ts'

const roots: string[] = []

function fixture(): string {
  const root = mkdtempSync(join(tmpdir(), 'dsh-startup-config-'))
  roots.push(root)
  return root
}

function configPath(): string {
  return join(fixture(), DESKTOP_STARTUP_CONFIG_FILENAME)
}

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('resolveStartupConfigPath', () => {
  it('points at startup.json beside the executable', () => {
    const root = fixture()
    expect(resolveStartupConfigPath(root)).toBe(join(root, DESKTOP_STARTUP_CONFIG_FILENAME))
  })
})

describe('applyDesktopStartupConfig', () => {
  it('returns an empty result when no config file exists', () => {
    const result = applyDesktopStartupConfig({ configPath: configPath(), environment: {} })
    expect(result).toEqual({ envUpdates: [], switches: [] })
  })

  it('applies DSH_HOME, the telemetry opt-out, and ordinary env entries', () => {
    const path = configPath()
    writeFileSync(path, JSON.stringify({
      version: 1,
      env: {
        DSH_HOME: 'custom-home',
        DSH_TELEMETRY_DISABLED: '1',
        MY_CUSTOM_VALUE: 'hello',
      },
      electron: {
        switches: [
          { name: 'disable-gpu', value: null },
          { name: 'proxy-server', value: 'http://127.0.0.1:7890' },
        ],
      },
    }))

    const result = applyDesktopStartupConfig({ configPath: path, environment: {} })

    expect(result.envUpdates).toEqual([
      ['DSH_HOME', 'custom-home'],
      ['DSH_TELEMETRY_DISABLED', '1'],
      ['MY_CUSTOM_VALUE', 'hello'],
    ])
    expect(result.switches).toEqual([
      { name: 'disable-gpu', value: null },
      { name: 'proxy-server', value: 'http://127.0.0.1:7890' },
    ])
  })

  it('omits env entries already present in the environment', () => {
    const path = configPath()
    writeFileSync(path, JSON.stringify({
      version: 1,
      env: { DSH_HOME: 'custom-home', DSH_TELEMETRY_DISABLED: '1' },
    }))

    const result = applyDesktopStartupConfig({
      configPath: path,
      environment: { DSH_HOME: 'inherited-home' },
    })

    expect(result.envUpdates).toEqual([['DSH_TELEMETRY_DISABLED', '1']])
  })

  it('rejects bootstrap-only names that decide how the process starts', () => {
    const path = configPath()
    writeFileSync(path, JSON.stringify({
      version: 1,
      env: { NODE_OPTIONS: '--max-old-space-size=4096' },
    }))

    expect(() => applyDesktopStartupConfig({ configPath: path, environment: {} })).toThrow(DesktopStartupConfigError)
  })

  it('applies PATH even when present, expanding a %PATH% reference', () => {
    const path = configPath()
    writeFileSync(path, JSON.stringify({
      version: 1,
      env: { PATH: 'prepended;%PATH%' },
    }))

    const result = applyDesktopStartupConfig({
      configPath: path,
      environment: { PATH: 'inherited' },
    })

    expect(result.envUpdates).toEqual([['PATH', 'prepended;inherited']])
  })

  it('expands %NAME% references against the environment', () => {
    const path = configPath()
    writeFileSync(path, JSON.stringify({
      version: 1,
      env: { MY_JOINED: 'a;%MY_EXTRA%', EXISTING: 'x' },
    }))

    const result = applyDesktopStartupConfig({
      configPath: path,
      environment: { MY_EXTRA: 'b', EXISTING: 'kept' },
    })

    expect(result.envUpdates).toEqual([['MY_JOINED', 'a;b']])
  })

  it('rejects other DSH_* names beyond the Home and telemetry allowlist', () => {
    const path = configPath()
    writeFileSync(path, JSON.stringify({
      version: 1,
      env: { DSH_SNAPSHOT: 'replay' },
    }))

    expect(() => applyDesktopStartupConfig({ configPath: path, environment: {} })).toThrow(DesktopStartupConfigError)
  })

  it('rejects invalid JSON', () => {
    const path = configPath()
    writeFileSync(path, 'not json {')
    expect(() => applyDesktopStartupConfig({ configPath: path, environment: {} })).toThrow(DesktopStartupConfigError)
  })

  it('rejects a document without the supported version', () => {
    const path = configPath()
    writeFileSync(path, JSON.stringify({ version: 2 }))
    expect(() => applyDesktopStartupConfig({ configPath: path, environment: {} })).toThrow(DesktopStartupConfigError)
  })

  it('rejects a non-string env value', () => {
    const path = configPath()
    writeFileSync(path, JSON.stringify({
      version: 1,
      env: { DSH_HOME: 42 },
    }))
    expect(() => applyDesktopStartupConfig({ configPath: path, environment: {} })).toThrow(DesktopStartupConfigError)
  })

  it('rejects a malformed switch name', () => {
    const path = configPath()
    writeFileSync(path, JSON.stringify({
      version: 1,
      electron: { switches: [{ name: 'Disable_GPU' }] },
    }))
    expect(() => applyDesktopStartupConfig({ configPath: path, environment: {} })).toThrow(DesktopStartupConfigError)
  })

  it('rejects a startup.json that is not a regular file', () => {
    const path = configPath()
    mkdirSync(path)
    expect(() => applyDesktopStartupConfig({ configPath: path, environment: {} })).toThrow(DesktopStartupConfigError)
  })

  it('rejects an oversized startup config', () => {
    const path = configPath()
    writeFileSync(path, 'x'.repeat(DESKTOP_STARTUP_CONFIG_MAX_BYTES + 1))
    expect(() => applyDesktopStartupConfig({ configPath: path, environment: {} })).toThrow(DesktopStartupConfigError)
  })

  it('rejects non-UTF-8 content', () => {
    const path = configPath()
    writeFileSync(path, Buffer.from([0x7b, 0xff, 0x7d]))
    expect(() => applyDesktopStartupConfig({ configPath: path, environment: {} })).toThrow(DesktopStartupConfigError)
  })
})
