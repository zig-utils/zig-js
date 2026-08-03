declare const Home: {
  readonly engine: "zig-js" | "jsc";
  readTextFile(path: string): string;
  writeTextFile(path: string, contents: string): void;
  readFileHex(path: string): string;
  writeFileHex(path: string, contents: string): void;
  fileExists(path: string): boolean;
  spawnSync(argv: string[]): { exitCode: number | null; stdout: string; stderr: string };
};

export function readText(path: string): string {
  return Home.readTextFile(path);
}

export function writeText(path: string, contents: string): void {
  Home.writeTextFile(path, contents);
}

export function readHex(path: string): string {
  return Home.readFileHex(path);
}

export function writeHex(path: string, contents: string): void {
  Home.writeFileHex(path, contents);
}

export function run(argv: string[]): { exitCode: number | null; stdout: string; stderr: string } {
  return Home.spawnSync(argv);
}

export function checked(argv: string[], phase: string): string {
  const result = run(argv);
  if (result.exitCode !== 0) throw new Error(`${phase}: ${result.stderr.trim() || result.stdout.trim() || `exit ${result.exitCode}`}`);
  return result.stdout;
}

export function sha256File(path: string): string {
  return checked(["shasum", "-a", "256", path], `cannot hash ${path}`).trim().split(/\s+/)[0];
}

export function temporaryDirectory(prefix: string): string {
  if (!/^[a-z0-9-]+$/.test(prefix)) throw new Error(`invalid temporary-directory prefix: ${prefix}`);
  return checked(["mktemp", "-d", `/tmp/${prefix}.XXXXXX`], "create temporary directory").trim();
}

export function removeTemporaryDirectory(path: string): void {
  if (!path.startsWith("/tmp/zig-js-") || path.includes("..") || path.includes("\n")) throw new Error(`refusing unsafe temporary directory: ${path}`);
  checked(["rm", "-rf", path], `remove temporary directory ${path}`);
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
