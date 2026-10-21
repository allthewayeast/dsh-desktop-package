/**
 * Durable geometry for the Next main window, stored inside Electron's userData.
 *
 * The Next shell creates its main window with fixed dimensions, so every launch
 * re-centered a 1280x840 window on the primary display. This module keeps the
 * normal (restored) rectangle and the maximized flag across launches, and it is
 * deliberately free of Electron imports so the geometry rules stay unit-testable
 * and a corrupt state file can never keep the application from starting.
 */

import { randomUUID } from 'node:crypto'
import { lstatSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'

export const NEXT_WINDOW_STATE_FILENAME = 'main-window-state.json'

const STATE_VERSION = 1
const MAX_STATE_BYTES = 4 * 1024
const DIRECTORY_MODE = 0o700
const FILE_MODE = 0o600
/** A restored window keeps at least this much of its width on screen. */
const MIN_VISIBLE_WIDTH = 64
/** Tolerated overshoot above the work area, e.g. a window dragged onto a higher monitor. */
const TOLERATED_TOP_OVERHANG = 32
/** The caption must stay reachable so the user can always move the window again. */
const CAPTION_REACH = 36

/** Electron-compatible window rectangle in device-independent pixels. */
export interface WindowRect {
  readonly x: number
  readonly y: number
  readonly width: number
  readonly height: number
}

/** Persisted main-window geometry: the restored rectangle plus the maximized flag. */
export interface NextWindowState {
  readonly bounds: WindowRect
  readonly maximized: boolean
}

interface NextWindowStateV1 {
  readonly version: 1
  readonly bounds: WindowRect
  readonly maximized: boolean
}

function isCoordinate(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value)
}

function isDimension(value: unknown): value is number {
  return isCoordinate(value) && value > 0
}

/** Validate one rectangle, throwing on anything a window cannot actually use. */
export function parseWindowRect(value: unknown): WindowRect {
  if (value === null || typeof value !== 'object') throw new Error('window rectangle must be an object')
  const candidate = value as Partial<Record<keyof WindowRect, unknown>>
  if (!isCoordinate(candidate.x) || !isCoordinate(candidate.y)) {
    throw new Error('window coordinates must be safe integers')
  }
  if (!isDimension(candidate.width) || !isDimension(candidate.height)) {
    throw new Error('window dimensions must be positive safe integers')
  }
  return { x: candidate.x, y: candidate.y, width: candidate.width, height: candidate.height }
}

function parseState(value: unknown): NextWindowState {
  if (value === null || typeof value !== 'object') throw new Error('window state must be an object')
  const candidate = value as Partial<Record<keyof NextWindowStateV1, unknown>>
  if (candidate.version !== STATE_VERSION) throw new Error('window state has an unsupported version')
  if (typeof candidate.maximized !== 'boolean') throw new Error('window state must record a maximized flag')
  return { bounds: parseWindowRect(candidate.bounds), maximized: candidate.maximized }
}

function statePath(userData: string): string {
  return join(userData, NEXT_WINDOW_STATE_FILENAME)
}

/**
 * Read the saved geometry.
 * @param userData - Electron-owned userData directory.
 * @returns the saved state, or `undefined` when it is missing, unreadable or invalid.
 */
export function readNextWindowState(userData: string): NextWindowState | undefined {
  const path = statePath(userData)
  try {
    const info = lstatSync(path)
    if (!info.isFile() || info.isSymbolicLink() || info.size > MAX_STATE_BYTES) return undefined
    return parseState(JSON.parse(readFileSync(path, 'utf8')))
  } catch {
    // Geometry is a convenience: an unusable file must never block startup, and
    // the next successful save replaces it.
    return undefined
  }
}

/**
 * Persist the geometry with an atomic replacement.
 * @param userData - Electron-owned userData directory.
 * @param state - rectangle and maximized flag captured from the live window.
 */
export function writeNextWindowState(userData: string, state: NextWindowState): void {
  const validated: NextWindowStateV1 = {
    version: STATE_VERSION,
    bounds: parseWindowRect(state.bounds),
    maximized: state.maximized,
  }
  mkdirSync(userData, { recursive: true, mode: DIRECTORY_MODE })
  const directory = lstatSync(userData)
  if (!directory.isDirectory() || directory.isSymbolicLink()) {
    throw new Error('window state directory must be a real directory')
  }
  const path = statePath(userData)
  const temporary = join(userData, `.${basename(path)}.${String(process.pid)}.${randomUUID()}.tmp`)
  try {
    writeFileSync(temporary, `${JSON.stringify(validated, undefined, 2)}\n`, { encoding: 'utf8', flag: 'wx', mode: FILE_MODE })
    renameSync(temporary, path)
  } finally {
    try { unlinkSync(temporary) } catch (cause) {
      if ((cause as NodeJS.ErrnoException).code !== 'ENOENT') throw cause
    }
  }
}

/** Intersection area of two rectangles; zero when they do not overlap. */
function overlapArea(left: WindowRect, right: WindowRect): number {
  const width = Math.min(left.x + left.width, right.x + right.width) - Math.max(left.x, right.x)
  const height = Math.min(left.y + left.height, right.y + right.height) - Math.max(left.y, right.y)
  return width > 0 && height > 0 ? width * height : 0
}

/**
 * Pick the display whose work area overlaps the saved rectangle most.
 * @param rect - saved rectangle.
 * @param workAreas - work areas of every connected display.
 * @returns the best match, or `undefined` when the rectangle touches no display
 *   (monitor unplugged, layout changed, or a stale remote-desktop session).
 */
export function pickWorkArea(rect: WindowRect, workAreas: readonly WindowRect[]): WindowRect | undefined {
  let best: WindowRect | undefined
  let bestArea = 0
  for (const area of workAreas) {
    const area0 = overlapArea(rect, area)
    if (area0 > bestArea) { best = area; bestArea = area0 }
  }
  return best
}

/**
 * Keep a restored rectangle usable on the current work area.
 *
 * A rectangle that still shows enough of itself with a reachable caption is
 * returned unchanged, so a normal restore never nudges the window. Anything
 * else is clamped into the work area, which also re-centers a rectangle whose
 * display disappeared.
 * @param rect - saved rectangle.
 * @param workArea - target work area in device-independent pixels.
 * @param minimum - configured minimum window size.
 * @returns a rectangle that is fully observable on `workArea`.
 */
export function fitWindowRect(
  rect: WindowRect,
  workArea: WindowRect,
  minimum: Pick<WindowRect, 'width' | 'height'>,
): WindowRect {
  const restored = parseWindowRect(rect)
  const available = parseWindowRect(workArea)
  const minWidth = isDimension(minimum.width) ? minimum.width : 1
  const minHeight = isDimension(minimum.height) ? minimum.height : 1
  const width = Math.max(minWidth, Math.min(restored.width, available.width))
  const height = Math.max(minHeight, Math.min(restored.height, available.height))
  const visibleWidth = Math.max(0, Math.min(restored.x + width, available.x + available.width) - Math.max(restored.x, available.x))
  const captionReachable = restored.y >= available.y - TOLERATED_TOP_OVERHANG
    && restored.y < available.y + available.height - CAPTION_REACH
  if (width === restored.width && height === restored.height
    && visibleWidth >= Math.min(MIN_VISIBLE_WIDTH, width) && captionReachable) {
    return restored
  }
  return {
    x: Math.min(available.x + Math.max(0, available.width - width), Math.max(available.x, restored.x)),
    y: Math.min(available.y + Math.max(0, available.height - height), Math.max(available.y, restored.y)),
    width,
    height,
  }
}
