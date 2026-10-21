import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it, onTestFinished } from 'vitest'
import {
  NEXT_WINDOW_STATE_FILENAME, fitWindowRect, parseWindowRect, pickWorkArea, readNextWindowState, writeNextWindowState,
} from '../src/window-state.ts'

async function temporaryUserData(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), 'dsh-next-window-state-'))
  onTestFinished(async () => { await rm(root, { recursive: true, force: true }) })
  return root
}

const WORK_AREA = { x: 0, y: 0, width: 2560, height: 1440 }
const MINIMUM = { width: 800, height: 580 }

it('round-trips the restored rectangle and the maximized flag', async () => {
  const userData = await temporaryUserData()
  expect(readNextWindowState(userData)).toBeUndefined()
  writeNextWindowState(userData, { bounds: { x: -120, y: 40, width: 1600, height: 1000 }, maximized: true })
  expect(readNextWindowState(userData)).toEqual({ bounds: { x: -120, y: 40, width: 1600, height: 1000 }, maximized: true })
  // A later normal-size session must replace, not merge, the previous geometry.
  writeNextWindowState(userData, { bounds: { x: 200, y: 120, width: 1024, height: 720 }, maximized: false })
  expect(readNextWindowState(userData)).toEqual({ bounds: { x: 200, y: 120, width: 1024, height: 720 }, maximized: false })
})

it('ignores a state file it cannot trust instead of failing the launch', async () => {
  const userData = await temporaryUserData()
  const path = join(userData, NEXT_WINDOW_STATE_FILENAME)
  const unusable = [
    'not json at all',
    JSON.stringify({ version: 2, bounds: { x: 0, y: 0, width: 800, height: 600 }, maximized: false }),
    JSON.stringify({ version: 1, bounds: { x: 0, y: 0, width: 0, height: 600 }, maximized: false }),
    JSON.stringify({ version: 1, bounds: { x: 0.5, y: 0, width: 800, height: 600 }, maximized: false }),
    JSON.stringify({ version: 1, bounds: { x: 0, y: 0, width: 800, height: 600 } }),
    JSON.stringify({ version: 1, bounds: 'fullscreen', maximized: false }),
  ]
  for (const content of unusable) {
    await writeFile(path, content, 'utf8')
    expect(readNextWindowState(userData)).toBeUndefined()
  }
  await writeFile(path, JSON.stringify({ version: 1, bounds: { x: 0, y: 0, width: 800, height: 600 }, maximized: false }).padEnd(8192, ' '), 'utf8')
  expect(readNextWindowState(userData)).toBeUndefined()
})

it('rejects rectangles and states a window cannot use', () => {
  expect(() => parseWindowRect({ x: 0, y: 0, width: 0, height: 600 })).toThrow()
  expect(() => parseWindowRect({ x: 0, y: 0, width: 800, height: -600 })).toThrow()
  expect(() => parseWindowRect({ x: Number.NaN, y: 0, width: 800, height: 600 })).toThrow()
  expect(parseWindowRect({ x: -1, y: -1, width: 1, height: 1 })).toEqual({ x: -1, y: -1, width: 1, height: 1 })
  const userData = 'X:/does-not-exist'
  expect(() => writeNextWindowState(userData, { bounds: { x: 0, y: 0, width: 0, height: 600 }, maximized: false })).toThrow()
})

it('keeps a rectangle that is still reachable on a connected display', () => {
  expect(fitWindowRect({ x: 100, y: 60, width: 1600, height: 1000 }, WORK_AREA, MINIMUM))
    .toEqual({ x: 100, y: 60, width: 1600, height: 1000 })
  // A monitor to the left of the primary produces negative coordinates.
  const left = { x: -1920, y: -200, width: 1920, height: 1080 }
  expect(fitWindowRect({ x: -1900, y: -10, width: 1200, height: 800 }, left, MINIMUM))
    .toEqual({ x: -1900, y: -10, width: 1200, height: 800 })
})

it('clamps an oversized, undersized or off-screen rectangle into the work area', () => {
  expect(fitWindowRect({ x: 0, y: 0, width: 4000, height: 3000 }, WORK_AREA, MINIMUM))
    .toEqual({ x: 0, y: 0, width: 2560, height: 1440 })
  expect(fitWindowRect({ x: 0, y: 0, width: 320, height: 200 }, WORK_AREA, MINIMUM))
    .toEqual({ x: 0, y: 0, width: 800, height: 580 })
  // The monitor that held this window is gone: pull it fully on screen.
  expect(fitWindowRect({ x: 4200, y: 900, width: 1000, height: 700 }, WORK_AREA, MINIMUM))
    .toEqual({ x: 1560, y: 740, width: 1000, height: 700 })
  // Only a sliver remains visible, which is below the reachable minimum.
  expect(fitWindowRect({ x: 2540, y: 100, width: 1000, height: 700 }, WORK_AREA, MINIMUM))
    .toEqual({ x: 1560, y: 100, width: 1000, height: 700 })
})

it('chooses the display with the largest overlap', () => {
  const right = { x: 2560, y: 0, width: 1920, height: 1080 }
  expect(pickWorkArea({ x: 200, y: 100, width: 900, height: 700 }, [WORK_AREA, right])).toEqual(WORK_AREA)
  expect(pickWorkArea({ x: 2600, y: 100, width: 900, height: 700 }, [WORK_AREA, right])).toEqual(right)
  // Straddling the seam: the display holding most of the window wins (840px right of the seam).
  expect(pickWorkArea({ x: 2400, y: 100, width: 1000, height: 700 }, [WORK_AREA, right])).toEqual(right)
  expect(pickWorkArea({ x: 9000, y: 9000, width: 900, height: 700 }, [WORK_AREA, right])).toBeUndefined()
  expect(pickWorkArea({ x: 0, y: 0, width: 900, height: 700 }, [])).toBeUndefined()
})
