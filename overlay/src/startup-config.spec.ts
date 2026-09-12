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

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('resolveStartupConfigPath', () => {
  it('defaults to startup.json beside the executable', () => {
    expect(resolveStartupConfigPath('C:\\Program Files\\DSH Desktop', {})).toBe(
      join('C:\\Program Files\\DSH Desktop', DESKTOP_STARTUP_CONFIG_FILENAME),
    )
  })

  it('uses an absolute DSH_STARTUP_CONFIG override', () => {
    expect(resolveStartupConfigPath('C:\\Program Files\\DSH Desktop', {
      DSH_STARTUP_CONFIG: 'E:\\AppData\\startup.json',
    })).toBe('E:\\AppData\\startup.json')
  })

  it('ignores a blank DSH_STARTUP_CONFIG override', () => {
    expect(resolveStartupConfigPath('C:\\Program Files\\DSH Desktop', {
      DSH_STARTUP_CONFIG: '   ',
    })).toBe(join('C:\\Program Files\\DSH Desktop', DESKTOP_STARTUP_CONFIG_FILENAME))
  })

  it('rejects a relative DSH_STARTUP_CONFIG override', () => {
    expect(() => resolveStartupConfigPath('C:\\Program Files\\DSH Desktop', {
      DSH_STARTUP_CONFIG: 'configs\\startup.json',
    })).toThrow(DesktopStartupConfigError)
  })
})

describe('applyDesktopStartupConfig', () => {
  it('returns an empty result when no config file exists', () => {
    const result = applyDesktopStartupConfig({
      configPath: join(fixture(), DESKTOP_STARTUP_CONFIG_FILENAME),
      environment: {},
    })
    expect(result).toEqual({ envUpdates: [], switches: [] })
  })

  it('applies DSH_HOME, the telemetry opt-out, and ordinary env entries', () => {
    const root = fixture()
    writeFileSync(join(root, DESKTOP_STARTUP_CONFIG_FILENAME), JSON.stringify({
      version: 1,
      env: {
        DSH_HOME: 'E:\\AppData\\YMZ\\.dsh-desktop',
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

    const result = applyDesktopStartupConfig({
      configPath: join(root, DESKTOP_STARTUP_CONFIG_FILENAME),
      environment: {},
    })

    expect(result.envUpdates).toEqual([
      ['DSH_HOME', 'E:\\AppData\\YMZ\\.dsh-desktop'],
      ['DSH_TELEMETRY_DISABLED', '1'],
      ['MY_CUSTOM_VALUE', 'hello'],
    ])
    expect(result.switches).toEqual([
      { name: 'disable-gpu', value: null },
      { name: 'proxy-server', value: 'http://127.0.0.1:7890' },
    ])
  })

  it('omits env entries already present in the environment', () => {
    const root = fixture()
    writeFileSync(join(root, DESKTOP_STARTUP_CONFIG_FILENAME), JSON.stringify({
      version: 1,
      env: { DSH_HOME: 'E:\\custom\\home', DSH_TELEMETRY_DISABLED: '1' },
    }))

    const result = applyDesktopStartupConfig({
      configPath: join(root, DESKTOP_STARTUP_CONFIG_FILENAME),
      environment: { DSH_HOME: 'E:\\inherited\\home' },
    })

    expect(result.envUpdates).toEqual([['DSH_TELEMETRY_DISABLED', '1']])
  })

  it('rejects bootstrap-only names that decide how the process starts', () => {
    const root = fixture()
    writeFileSync(join(root, DESKTOP_STARTUP_CONFIG_FILENAME), JSON.stringify({
      version: 1,
      env: { PATH: 'C:\\Windows' },
    }))

    expect(() => applyDesktopStartupConfig({
      configPath: join(root, DESKTOP_STARTUP_CONFIG_FILENAME),
      environment: {},
    })).toThrow(DesktopStartupConfigError)
  })

  it('rejects other DSH_* names beyond the Home and telemetry allowlist', () => {
    const root = fixture()
    writeFileSync(join(root, DESKTOP_STARTUP_CONFIG_FILENAME), JSON.stringify({
      version: 1,
      env: { DSH_SNAPSHOT: 'replay' },
    }))

    expect(() => applyDesktopStartupConfig({
      configPath: join(root, DESKTOP_STARTUP_CONFIG_FILENAME),
      environment: {},
    })).toThrow(DesktopStartupConfigError)
  })

  it('rejects invalid JSON', () => {
    const root = fixture()
    writeFileSync(join(root, DESKTOP_STARTUP_CONFIG_FILENAME), 'not json {')
    expect(() => applyDesktopStartupConfig({
      configPath: join(root, DESKTOP_STARTUP_CONFIG_FILENAME),
      environment: {},
    })).toThrow(DesktopStartupConfigError)
  })

  it('rejects a document without the supported version', () => {
    const root = fixture()
    writeFileSync(join(root, DESKTOP_STARTUP_CONFIG_FILENAME), JSON.stringify({ version: 2 }))
    expect(() => applyDesktopStartupConfig({
      configPath: join(root, DESKTOP_STARTUP_CONFIG_FILENAME),
      environment: {},
    })).toThrow(DesktopStartupConfigError)
  })

  it('rejects a non-string env value', () => {
    const root = fixture()
    writeFileSync(join(root, DESKTOP_STARTUP_CONFIG_FILENAME), JSON.stringify({
      version: 1,
      env: { DSH_HOME: 42 },
    }))
    expect(() => applyDesktopStartupConfig({
      configPath: join(root, DESKTOP_STARTUP_CONFIG_FILENAME),
      environment: {},
    })).toThrow(DesktopStartupConfigError)
  })

  it('rejects a malformed switch name', () => {
    const root = fixture()
    writeFileSync(join(root, DESKTOP_STARTUP_CONFIG_FILENAME), JSON.stringify({
      version: 1,
      electron: { switches: [{ name: 'Disable_GPU' }] },
    }))
    expect(() => applyDesktopStartupConfig({
      configPath: join(root, DESKTOP_STARTUP_CONFIG_FILENAME),
      environment: {},
    })).toThrow(DesktopStartupConfigError)
  })

  it('rejects a startup.json that is not a regular file', () => {
    const root = fixture()
    mkdirSync(join(root, DESKTOP_STARTUP_CONFIG_FILENAME))
    expect(() => applyDesktopStartupConfig({
      configPath: join(root, DESKTOP_STARTUP_CONFIG_FILENAME),
      environment: {},
    })).toThrow(DesktopStartupConfigError)
  })

  it('rejects an oversized startup config', () => {
    const root = fixture()
    writeFileSync(join(root, DESKTOP_STARTUP_CONFIG_FILENAME), 'x'.repeat(DESKTOP_STARTUP_CONFIG_MAX_BYTES + 1))
    expect(() => applyDesktopStartupConfig({
      configPath: join(root, DESKTOP_STARTUP_CONFIG_FILENAME),
      environment: {},
    })).toThrow(DesktopStartupConfigError)
  })

  it('rejects non-UTF-8 content', () => {
    const root = fixture()
    writeFileSync(join(root, DESKTOP_STARTUP_CONFIG_FILENAME), Buffer.from([0x7b, 0xff, 0x7d]))
    expect(() => applyDesktopStartupConfig({
      configPath: join(root, DESKTOP_STARTUP_CONFIG_FILENAME),
      environment: {},
    })).toThrow(DesktopStartupConfigError)
  })
})
