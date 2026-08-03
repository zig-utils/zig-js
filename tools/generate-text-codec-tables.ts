/** Pack revision-pinned WebKit TextCodec decoder indexes. */
import { readText, run, writeHex } from "./lib/home";

const expected = [
  "ec3ec297dd8b52a64ac3065206d26ab186b9f59349790d7e6bfcda297051ad60",
  "6abca8d12653ab4dde31ad3eae0e089b392b793d7a9bc04c68081fb6536b8552",
  "d178f1c382a2c590f7d812ff317d9b20e5085358604eeb4eb4b40f3697704508",
];
const names = ["iso88593", "iso88596", "iso88597", "iso88598", "windows874", "windows1253", "windows1255", "windows1257", "koi8u", "ibm866"];
const args = process.argv.slice(2);
if (args.length !== 4) throw new Error("usage: generate-text-codec-tables.ts ENCODING_TABLES SINGLE_BYTE CJK OUTPUT");
function checkedSource(path: string, digest: string): string {
  const result = run(["shasum", "-a", "256", path]);
  if (result.exitCode !== 0) throw new Error(result.stderr || "cannot checksum " + path);
  const actual = result.stdout.trim().split(/\s+/)[0];
  if (actual !== digest) throw new Error(`${path}: expected SHA-256 ${digest}, got ${actual}`);
  return readText(path);
}
const encoding = checkedSource(args[0], expected[0]);
const single = checkedSource(args[1], expected[1]);
const cjk = checkedSource(args[2], expected[2]);
function initializer(source: string, marker: string): string {
  let start = source.indexOf(marker);
  if (start < 0) throw new Error("missing initializer: " + marker);
  start = source.indexOf("{", start) + 1;
  const end = source.indexOf("};", start);
  if (end < 0) throw new Error("unterminated initializer: " + marker);
  return source.slice(start, end);
}
function pairs(source: string, marker: string, count: number): number[][] {
  const rows: number[][] = [], regex = /\{\s*(\d+)\s*,\s*(0x[0-9a-fA-F]+)\s*\}/g;
  const body = initializer(source, marker);
  let match: RegExpExecArray | null;
  while ((match = regex.exec(body)) !== null) rows.push([Number(match[1]), Number.parseInt(match[2], 16)]);
  if (rows.length !== count) throw new Error(`${marker}: expected ${count} entries, got ${rows.length}`);
  return rows;
}
function hexValues(source: string, marker: string, count: number): number[] {
  const values: number[] = [], regex = /0x[0-9a-fA-F]+/g;
  const body = initializer(source, marker);
  let match: RegExpExecArray | null;
  while ((match = regex.exec(body)) !== null) values.push(Number.parseInt(match[0], 16));
  if (values.length !== count) throw new Error(`${marker}: expected ${count} entries, got ${values.length}`);
  return values;
}
function dense(entries: number[][], count: number): number[] {
  const values = new Array(count).fill(0);
  for (const [pointer, point] of entries) {
    if (pointer >= count || values[pointer] !== 0) throw new Error("invalid or duplicate pointer " + pointer);
    values[pointer] = point;
  }
  return values;
}
const bytes: number[] = [0x5a, 0x4a, 0x54, 0x43, 0x30, 0x30, 0x30, 0x31];
const u16 = (values: number[]) => { for (const value of values) bytes.push(value & 255, (value >>> 8) & 255); };
const u32 = (values: number[]) => { for (const value of values) bytes.push(value & 255, (value >>> 8) & 255, (value >>> 16) & 255, (value >>> 24) & 255); };
for (const name of names) u16(hexValues(single, "SingleByteDecodeTable " + name, 128));
u16(dense(pairs(encoding, "jis0208Data", 7724), 11104));
u16(dense(pairs(encoding, "jis0212Data", 6067), 7211));
u32(dense(pairs(encoding, "big5Data", 18590), 19782));
u16(dense(pairs(encoding, "eucKRData", 17048), 23750));
u16(hexValues(encoding, "gb18030Data", 23940));
u32(pairs(cjk, "gb18030Ranges", 207).reduce((all: number[], pair: number[]) => all.concat(pair), []));
const slash = args[3].lastIndexOf("/");
if (slash > 0) {
  const made = run(["mkdir", "-p", args[3].slice(0, slash)]);
  if (made.exitCode !== 0) throw new Error(made.stderr || "cannot create output directory");
}
writeHex(args[3], bytes.map(byte => byte.toString(16).padStart(2, "0")).join(""));
console.log(`wrote ${bytes.length} bytes to ${args[3]}`);
