#!/usr/bin/env node
// DSH 会话记录读取工具 —— 用于「改动到底丢了没有」的溯源取证。
//
// 背景：本仓库位于 X:（Romex Primo RamDisk），重启即丢。判断某次改动是否真的丢失，
// 唯一可靠的证据不是工作树（可能已被重新克隆），而是 DSH 落在 E: 上的会话记录。
// 会话文件是 .zstd 多帧拼接容器：Node 的 zstdDecompressSync 只解第一帧，
// 流式 createZstdDecompress 不支持拼接帧（会抛 "Unknown frame descriptor"）。
// 因此本工具按帧 magic 切分后逐帧解压再拼接。
//
// 用法：
//   node tools/dsh-session-read.mjs map    <plainDir>
//   node tools/dsh-session-read.mjs expand <sessionRoot> <outDir>
//   node tools/dsh-session-read.mjs edits  <plain.jsonl> [pathFilterRegex]
//   node tools/dsh-session-read.mjs find   <regex> <file...>
//
// 典型流程（见 BUILD_GUIDE.md「六、溯源与防丢」）：
//   node tools/dsh-session-read.mjs expand "%USERPROFILE%\..\..\AppData\YMZ\.dsh-desktop\sessions\--X-dsh-desktop-package--" tmp\plain
//   node tools/dsh-session-read.mjs map tmp\plain
//   node tools/dsh-session-read.mjs edits tmp\plain\session-<id>__session.v4.jsonl "build\.ps1|community-market"
import fs from 'node:fs'
import path from 'node:path'
import readline from 'node:readline'
import zlib from 'node:zlib'

const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])
const CST_OFFSET = 8 * 3600 * 1000

const stamp = (ms) => new Date(ms + CST_OFFSET).toISOString().replace('T', ' ').slice(0, 19)
const clip = (s, n) => (typeof s === 'string' ? s.replace(/\s+/g, ' ').slice(0, n) : '')
const walk = (dir) =>
  fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = path.join(dir, e.name)
    return e.isDirectory() ? walk(p) : e.name.endsWith('.zstd') ? [p] : []
  })

// ---- expand：逐帧解压 ----
function frameOffsets(buf) {
  const offs = [0]
  for (let p = 1; ; ) {
    const i = buf.indexOf(MAGIC, p)
    if (i < 0) break
    if (i > offs[offs.length - 1]) offs.push(i)
    p = i + 4
  }
  return offs
}

function expandBuffer(buf) {
  const offs = frameOffsets(buf)
  const parts = []
  let i = 0
  let bad = 0
  while (i < offs.length - 1) {
    let out = null
    let next = i + 1
    // magic 可能误命中压缩数据内部：失败就与后一段合并重试
    for (let j = i + 1; j <= offs.length; j++) {
      const end = j < offs.length ? offs[j] : buf.length
      try {
        out = zlib.zstdDecompressSync(buf.subarray(offs[i], end))
        next = j
        break
      } catch { /* 合并下一段 */ }
    }
    if (out === null) { bad++; break } // 末尾可能是在写入中的截断帧
    parts.push(out)
    i = next
  }
  return { parts, frames: offs.length, bad }
}

function cmdExpand([src, outDir]) {
  fs.mkdirSync(outDir, { recursive: true })
  for (const f of walk(src).sort()) {
    const rel = path.relative(src, f).split(/[\\/]/).join('__').replace(/\.zstd$/, '')
    const dest = path.join(outDir, rel)
    const buf = fs.readFileSync(f)
    const { parts, frames, bad } = expandBuffer(buf)
    fs.writeFileSync(dest, Buffer.concat(parts))
    const size = parts.reduce((n, b) => n + b.length, 0)
    console.log(`frames=${frames} bad=${bad} in=${buf.length} out=${size}  ${rel}`)
  }
}

// ---- map：覆盖地图 ----
async function cmdMap([dir]) {
  for (const name of fs.readdirSync(dir).filter((n) => n.endsWith('.jsonl')).sort()) {
    const rl = readline.createInterface({ input: fs.createReadStream(path.join(dir, name)), crlfDelay: Infinity })
    let lines = 0, seqMin = Infinity, seqMax = -Infinity, turnMin = Infinity, turnMax = -Infinity
    let tMin = Infinity, tMax = -Infinity
    for await (const line of rl) {
      if (!line.trim()) continue
      lines++
      let o
      try { o = JSON.parse(line) } catch { continue }
      if (typeof o.seq === 'number') { seqMin = Math.min(seqMin, o.seq); seqMax = Math.max(seqMax, o.seq) }
      if (typeof o.time === 'number') { tMin = Math.min(tMin, o.time); tMax = Math.max(tMax, o.time) }
      const t = o.data?.turn
      if (typeof t === 'number') { turnMin = Math.min(turnMin, t); turnMax = Math.max(turnMax, t) }
    }
    console.log(`${name}\n   lines=${lines} seq=${seqMin}..${seqMax} turn=${turnMin}..${turnMax}`)
    console.log(`   time=${Number.isFinite(tMin) ? stamp(tMin) : '-'} .. ${Number.isFinite(tMax) ? stamp(tMax) : '-'}`)
  }
}

// ---- edits：编辑操作年表 ----
const EDIT_TOOLS = ['edit', 'write', 'apply_patch', 'multi_edit', 'notebook_edit']
async function cmdEdits([file, filterSrc]) {
  const filter = filterSrc ? new RegExp(filterSrc, 'i') : null
  const counts = new Map()
  const hits = []
  const rl = readline.createInterface({ input: fs.createReadStream(file), crlfDelay: Infinity })
  for await (const line of rl) {
    if (!line.trim()) continue
    let o
    try { o = JSON.parse(line) } catch { continue }
    if (o.type !== 'tool/call' || !EDIT_TOOLS.includes(o.data?.name)) continue
    let a = {}
    try { a = JSON.parse(o.data.arguments ?? '{}') } catch { a = { _raw: o.data.arguments } }
    const p = a.file_path ?? a.path ?? '(unknown)'
    counts.set(p, (counts.get(p) ?? 0) + 1)
    if (filter && filter.test(p)) {
      hits.push({ time: stamp(o.time), turn: o.data.turn, step: o.data.step, path: p, old: a.old_string, neu: a.new_string, content: a.content })
    }
  }
  console.log('--- 各文件被编辑次数 ---')
  for (const [p, n] of [...counts.entries()].sort((a, b) => b[1] - a[1])) console.log(`${String(n).padStart(4)}  ${p}`)
  if (!filter) return
  console.log(`--- 匹配 ${filter} 的编辑 (${hits.length}) ---`)
  for (const h of hits) {
    console.log(`\n[${h.time}] turn${h.turn}/step${h.step}  ${h.path}`)
    if (h.old) console.log(`  old(${h.old.length}): ${clip(h.old, 220)}`)
    if (h.neu) console.log(`  new(${h.neu.length}): ${clip(h.neu, 220)}`)
    if (h.content) console.log(`  content(${h.content.length}): ${clip(h.content, 220)}`)
  }
}

// ---- find：任意记录检索 ----
async function cmdFind([regexSrc, ...files]) {
  const re = new RegExp(regexSrc, 'i')
  for (const file of files) {
    let n = 0
    const rl = readline.createInterface({ input: createReadStream0(file), crlfDelay: Infinity })
    for await (const line of rl) {
      if (!line.trim() || !re.test(line)) continue
      let o = null
      try { o = JSON.parse(line) } catch { /* raw */ }
      console.log(`\n=== [${o?.time ? stamp(o.time) : '?'}] turn${o?.data?.turn ?? '-'}/step${o?.data?.step ?? '-'} type=${o?.type ?? 'raw'}`)
      const text = o ? JSON.stringify(o) : line
      const scan = new RegExp(re.source, 'gi')
      let m, shown = 0
      while ((m = scan.exec(text)) !== null && shown < 2) {
        console.log(`   …${text.slice(Math.max(0, m.index - 300), m.index + 560).replace(/\s+/g, ' ')}…`)
        shown++
        if (scan.lastIndex <= m.index) scan.lastIndex = m.index + 1
      }
      if (++n >= 60) { console.log('[truncated at 60]'); break }
    }
    console.log(`\n--- ${path.basename(file)}: ${n} matching records ---`)
  }
}

function createReadStream0(f) { return fs.createReadStream(f) }

const [cmd, ...rest] = process.argv.slice(2)
const table = { expand: cmdExpand, map: cmdMap, edits: cmdEdits, find: cmdFind }
if (!table[cmd]) {
  console.error('usage: dsh-session-read.mjs <expand|map|edits|find> ...')
  process.exit(2)
}
await table[cmd](rest)
