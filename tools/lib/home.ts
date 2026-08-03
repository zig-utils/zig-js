declare const Home: {
  readonly engine: "zig-js" | "jsc";
  readTextFile(path: string): string;
  writeTextFile(path: string, contents: string): void;
  readFileHex(path: string): string;
  writeFileHex(path: string, contents: string): void;
  fileExists(path: string): boolean;
  spawnSync(
    argv: string[],
    options?: RunOptions,
  ): {
    exitCode: number | null;
    stdout: string;
    stderr: string;
    timedOut: boolean;
  };
};

export type RunOptions = {
  cwd?: string;
  timeoutMs?: number;
  env?: Record<string, string>;
  inheritEnv?: boolean;
};

export function readText(path: string): string {
  return Home.readTextFile(path);
}

export function writeText(path: string, contents: string): void {
  Home.writeTextFile(path, contents);
}

export function fileExists(path: string): boolean {
  return Home.fileExists(path);
}

export function readHex(path: string): string {
  return Home.readFileHex(path);
}

export function writeHex(path: string, contents: string): void {
  Home.writeFileHex(path, contents);
}

export function run(
  argv: string[],
  options?: RunOptions,
): {
  exitCode: number | null;
  stdout: string;
  stderr: string;
  timedOut: boolean;
} {
  return Home.spawnSync(argv, options);
}

export function checked(argv: string[], phase: string): string {
  const result = run(argv);
  if (result.exitCode !== 0)
    throw new Error(
      `${phase}: ${result.stderr.trim() || result.stdout.trim() || `exit ${result.exitCode}`}`,
    );
  return result.stdout;
}

export function sha256File(path: string): string {
  return checked(["shasum", "-a", "256", path], `cannot hash ${path}`)
    .trim()
    .split(/\s+/)[0];
}

export function sha256Text(text: string): string {
  const bytes = utf8Bytes(text),
    bitLength = bytes.length * 8;
  bytes.push(0x80);
  while (bytes.length % 64 !== 56) bytes.push(0);
  for (let shift = 56; shift >= 0; shift -= 8)
    bytes.push(shift >= 32 ? 0 : Math.floor(bitLength / 2 ** shift) & 255);
  const constants = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  const h = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c,
      0x1f83d9ab, 0x5be0cd19,
    ],
    rotate = (value: number, amount: number): number =>
      (value >>> amount) | (value << (32 - amount));
  for (let offset = 0; offset < bytes.length; offset += 64) {
    const words: number[] = [];
    for (let index = 0; index < 16; index += 1)
      words[index] =
        (bytes[offset + index * 4] << 24) |
        (bytes[offset + index * 4 + 1] << 16) |
        (bytes[offset + index * 4 + 2] << 8) |
        bytes[offset + index * 4 + 3];
    for (let index = 16; index < 64; index += 1) {
      const x = words[index - 15],
        y = words[index - 2],
        s0 = rotate(x, 7) ^ rotate(x, 18) ^ (x >>> 3),
        s1 = rotate(y, 17) ^ rotate(y, 19) ^ (y >>> 10);
      words[index] = (words[index - 16] + s0 + words[index - 7] + s1) | 0;
    }
    let a = h[0],
      b = h[1],
      c = h[2],
      d = h[3],
      e = h[4],
      f = h[5],
      g = h[6],
      hh = h[7];
    for (let index = 0; index < 64; index += 1) {
      const s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25),
        ch = (e & f) ^ (~e & g),
        t1 = (hh + s1 + ch + constants[index] + words[index]) | 0,
        s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22),
        maj = (a & b) ^ (a & c) ^ (b & c),
        t2 = (s0 + maj) | 0;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) | 0;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) | 0;
    }
    h[0] = (h[0] + a) | 0;
    h[1] = (h[1] + b) | 0;
    h[2] = (h[2] + c) | 0;
    h[3] = (h[3] + d) | 0;
    h[4] = (h[4] + e) | 0;
    h[5] = (h[5] + f) | 0;
    h[6] = (h[6] + g) | 0;
    h[7] = (h[7] + hh) | 0;
  }
  return h.map((value) => (value >>> 0).toString(16).padStart(8, "0")).join("");
}

export function temporaryDirectory(prefix: string): string {
  if (!/^[a-z0-9-]+$/.test(prefix))
    throw new Error(`invalid temporary-directory prefix: ${prefix}`);
  return checked(
    ["mktemp", "-d", `/tmp/${prefix}.XXXXXX`],
    "create temporary directory",
  ).trim();
}

export function removeTemporaryDirectory(path: string): void {
  if (
    !path.startsWith("/tmp/zig-js-") ||
    path.includes("..") ||
    path.includes("\n")
  )
    throw new Error(`refusing unsafe temporary directory: ${path}`);
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
    else if (point <= 0x7ff)
      bytes.push(0xc0 | (point >> 6), 0x80 | (point & 0x3f));
    else if (point <= 0xffff)
      bytes.push(
        0xe0 | (point >> 12),
        0x80 | ((point >> 6) & 0x3f),
        0x80 | (point & 0x3f),
      );
    else
      bytes.push(
        0xf0 | (point >> 18),
        0x80 | ((point >> 12) & 0x3f),
        0x80 | ((point >> 6) & 0x3f),
        0x80 | (point & 0x3f),
      );
  }
  return bytes;
}
