declare const Home: {
  readonly engine: "zig-js" | "jsc";
  readTextFile(path: string): string;
  writeTextFile(path: string, contents: string): void;
  fileExists(path: string): boolean;
  spawnSync(argv: string[]): { exitCode: number | null; stdout: string; stderr: string };
};

export function readText(path: string): string {
  return Home.readTextFile(path);
}

export function run(argv: string[]): { exitCode: number | null; stdout: string; stderr: string } {
  return Home.spawnSync(argv);
}

export function utf8Bytes(text: string): number[] {
  const bytes: number[] = [];
  for (let index = 0; index < text.length; index += 1) {
    let point = text.charCodeAt(index);
    if (point >= 0xd800 && point <= 0xdbff && index + 1 < text.length) {
      const low = text.charCodeAt(index + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        point = 0x10000 + ((point - 0xd800) << 10) + (low - 0xdc00);
        index += 1;
      }
    }
    if (point <= 0x7f) bytes.push(point);
    else if (point <= 0x7ff) bytes.push(0xc0 | (point >> 6), 0x80 | (point & 0x3f));
    else if (point <= 0xffff) bytes.push(0xe0 | (point >> 12), 0x80 | ((point >> 6) & 0x3f), 0x80 | (point & 0x3f));
    else bytes.push(0xf0 | (point >> 18), 0x80 | ((point >> 12) & 0x3f), 0x80 | ((point >> 6) & 0x3f), 0x80 | (point & 0x3f));
  }
  return bytes;
}
