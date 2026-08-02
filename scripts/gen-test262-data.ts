#!/usr/bin/env bun
/**
 * Regenerate docs/.data/test262.json from the real test262 conformance run.
 *
 * Usage:
 *   bun scripts/gen-test262-data.ts              # runs `zig build test262` and parses it
 *   bun scripts/gen-test262-data.ts --from out.txt   # parse a saved run instead
 *
 * The owned Zig docs builder reads this file as `data.test262` when expanding
 * the homepage and conformance components.
 */
import { homedir } from 'node:os'
import { join } from 'node:path'

const ROOT = join(import.meta.dir, '..')
const OUT = join(ROOT, 'docs/.data/test262.json')

// Zig 0.17-dev is required (system 0.16 will not work). See project memory.
const ZIG = `${homedir()}/.local/share/zig-0.17-dev/zig`

async function getOutput(): Promise<string> {
  const fromIdx = process.argv.indexOf('--from')
  if (fromIdx !== -1 && process.argv[fromIdx + 1])
    return await Bun.file(process.argv[fromIdx + 1]).text()

  const zig = (await Bun.file(ZIG).exists()) ? ZIG : 'zig'
  console.error(`Running: ${zig} build test262 -Doptimize=ReleaseFast (this can take a while)…`)
  const proc = Bun.spawn([zig, 'build', 'test262', '-Doptimize=ReleaseFast'], {
    cwd: ROOT,
    stdout: 'pipe',
    stderr: 'pipe',
  })
  const [out, err] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ])
  await proc.exited
  // The runner prints the summary to stdout; some Zig builds route it to stderr.
  return `${out}\n${err}`
}

function parse(text: string) {
  const todayIso = new Date().toISOString().slice(0, 10)
  const pct = (passing: number, total: number) =>
    total === 0 ? 0 : Number(((passing / total) * 100).toFixed(2))

  const validLine = text.match(/VALID[^:]*:\s*(\d+)\/(\d+)\s*\(([\d.]+)%\)(?:[^\n]*parse-fail\s*(\d+)[^\n]*runtime-fail\s*(\d+)[^\n]*host-fail\s*(\d+))?/i)
  const negLine = text.match(/NEGATIVE[^:]*:\s*(\d+)\/(\d+)\s*\(([\d.]+)%\)/i)
  const skipLine = text.match(/skipped[^:]*:\s*(\d+)/i)

  if (!validLine)
    throw new Error('Could not find VALID summary line in test262 output. Pass --from <file> with the run output.')

  // Keep the exact path after `test/` so similarly named leaves in different
  // suites (`built-ins/Array`, `intl402/Array`) stay distinguishable.
  const suiteRe = /test\/(.+?):\s*valid\s*(\d+)\/(\d+)\s*\(([\d.]+)%\)(?:\s*\[parse-fail\s*(\d+)[^\]]*runtime-fail\s*(\d+)[^\]]*host-fail\s*(\d+)\])?/gi
  const suites: Array<Record<string, unknown>> = []
  for (const m of text.matchAll(suiteRe)) {
    const passing = Number(m[2])
    const total = Number(m[3])
    suites.push({
      name: m[1],
      passing,
      total,
      percentage: pct(passing, total),
      ...(m[5] !== undefined
        ? { parseFail: Number(m[5]), runtimeFail: Number(m[6]), hostFail: Number(m[7]) }
        : {}),
    })
  }

  const validPassing = Number(validLine[1])
  const validTotal = Number(validLine[2])
  const valid = {
    passing: validPassing,
    total: validTotal,
    percentage: pct(validPassing, validTotal),
    ...(validLine[4] !== undefined
      ? { parseFail: Number(validLine[4]), runtimeFail: Number(validLine[5]), hostFail: Number(validLine[6]) }
      : {}),
  }
  const negativePassing = negLine ? Number(negLine[1]) : 0
  const negativeTotal = negLine ? Number(negLine[2]) : 0

  return {
    valid,
    negative: negLine
      ? { passing: negativePassing, total: negativeTotal, percentage: pct(negativePassing, negativeTotal) }
      : { passing: 0, total: 0, percentage: 0 },
    skipped: skipLine ? Number(skipLine[1]) : 0,
    generatedAt: todayIso,
    harness: 'real (pinned tc39/test262 submodule)',
    suites,
  }
}

const data = parse(await getOutput())
await Bun.write(OUT, `${JSON.stringify(data, null, 2)}\n`)
console.error(`Wrote ${OUT}: VALID ${data.valid.passing}/${data.valid.total} (${data.valid.percentage}%), ${data.suites.length} suites.`)
