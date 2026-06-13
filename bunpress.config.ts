import type { BunPressConfig } from '@stacksjs/bunpress'

/**
 * zig-js documentation — a modern, "terminal hacker" technical brand.
 * Dark canvas, monospace headings, neon-green / cyan / zig-amber accents.
 */
const css = /* css */ `
:root {
  --bp-bg: #05070a;
  --bp-panel: #0b0f15;
  --bp-panel-2: #0e141c;
  --bp-border: #1a2430;
  --bp-text: #c7d3e0;
  --bp-muted: #6c7c8d;
  --bp-green: #2bd576;
  --bp-green-bright: #41ffa3;
  --bp-cyan: #34e7e4;
  --bp-amber: #f7a41d;
  --bp-magenta: #ff5c8a;
  --bp-mono: 'JetBrains Mono', ui-monospace, 'SFMono-Regular', 'Menlo', monospace;
  --bp-sans: 'Inter', ui-sans-serif, system-ui, sans-serif;

  /* Recolour the bun theme to our dark brand (the theme ships light by default).
     These drive the doc layout: sidebar, TOC, content, code, containers. */
  --bp-c-bg: #05070a;
  --bp-c-bg-alt: #0b0f15;
  --bp-c-bg-soft: #0e141c;
  --bp-c-bg-elv: #0e141c;
  --bp-c-border: #1a2430;
  --bp-c-divider: #141c26;
  --bp-c-gutter: #0b0f15;
  --bp-c-text-1: #c7d3e0;
  --bp-c-text-2: #8a9bab;
  --bp-c-text-3: #5c6b7a;
  --bp-c-brand-1: #2bd576;
  --bp-c-brand-2: #41ffa3;
  --bp-c-brand-3: #34e7e4;
  --bp-c-brand-soft: rgba(43, 213, 118, 0.14);
  --bp-c-default-soft: rgba(140, 150, 170, 0.12);
  --bp-code-bg: #0e141c;
  --bp-code-block-bg: #0b0f15;
}

html, body {
  background: var(--bp-bg);
  color: var(--bp-text);
  font-family: var(--bp-sans);
  -webkit-font-smoothing: antialiased;
}

/* Subtle grid + glow backdrop on the home page */
.BPHome {
  position: relative;
  overflow: hidden;
}
.BPHome::before {
  content: '';
  position: absolute;
  inset: 0;
  background-image:
    linear-gradient(var(--bp-border) 1px, transparent 1px),
    linear-gradient(90deg, var(--bp-border) 1px, transparent 1px);
  background-size: 44px 44px;
  -webkit-mask-image: radial-gradient(ellipse 80% 55% at 50% 0%, #000 30%, transparent 75%);
  mask-image: radial-gradient(ellipse 80% 55% at 50% 0%, #000 30%, transparent 75%);
  opacity: 0.35;
  pointer-events: none;
}
.BPHome::after {
  content: '';
  position: absolute;
  top: -160px; left: 50%;
  width: 720px; height: 420px;
  transform: translateX(-50%);
  background: radial-gradient(closest-side, rgba(43,213,118,0.18), transparent 70%);
  filter: blur(20px);
  pointer-events: none;
}

/* Nav */
.BPNav { background: rgba(5,7,10,0.72); backdrop-filter: blur(10px); border-bottom: 1px solid var(--bp-border); }
.BPNavBar { max-width: 1180px; margin: 0 auto; }
.BPNavBarTitle, .BPNavBarTitle a { font-family: var(--bp-mono); font-weight: 700; letter-spacing: -0.02em; color: var(--bp-text); }
.BPNavBarMenu-link { color: var(--bp-muted); }
.BPNavBarMenu-link:hover { color: var(--bp-green-bright); }

/* Hero */
.BPHomeHero { position: relative; z-index: 1; padding: 90px 24px 28px; }
.BPHero-name {
  font-family: var(--bp-mono);
  font-size: clamp(56px, 11vw, 132px);
  line-height: 0.95;
  font-weight: 800;
  letter-spacing: -0.04em;
  margin: 0;
  background: linear-gradient(120deg, var(--bp-green-bright), var(--bp-cyan) 55%, var(--bp-amber));
  -webkit-background-clip: text; background-clip: text;
  -webkit-text-fill-color: transparent;
  filter: drop-shadow(0 0 28px rgba(43,213,118,0.25));
}
.BPHero-text { font-family: var(--bp-mono); font-size: clamp(18px, 2.4vw, 26px); color: var(--bp-text); font-weight: 500; margin: 18px 0 0; }
.BPHero-tagline { color: var(--bp-muted); font-size: clamp(15px, 1.6vw, 18px); max-width: 640px; margin: 16px auto 0; }
@media (min-width: 960px) { .BPHero-tagline { margin-left: 0; } }

.BPHero-actions { margin-top: 30px; gap: 14px; }
.BPButton { font-family: var(--bp-mono); font-weight: 600; border-radius: 8px; padding: 11px 22px; transition: transform .12s ease, box-shadow .2s ease; }
.BPButton-brand { background: var(--bp-green); color: #04130b; box-shadow: 0 0 0 1px rgba(65,255,163,0.4), 0 10px 30px -10px rgba(43,213,118,0.6); }
.BPButton-brand:hover { transform: translateY(-2px); box-shadow: 0 0 0 1px var(--bp-green-bright), 0 14px 36px -10px rgba(43,213,118,0.8); }
.BPButton-alt { background: var(--bp-panel-2); color: var(--bp-text); border: 1px solid var(--bp-border); }
.BPButton-alt:hover { border-color: var(--bp-green); color: var(--bp-green-bright); transform: translateY(-2px); }

/* Home body container */
.BPHome-content { position: relative; z-index: 1; max-width: 1080px; margin: 0 auto; padding: 8px 24px 80px; }
.BPHome-content h2 { font-family: var(--bp-mono); font-size: 13px; letter-spacing: 0.22em; text-transform: uppercase; color: var(--bp-green); border: 0; margin: 56px 0 20px; }
.BPHome-content h2::before { content: '// '; color: var(--bp-muted); }
.BPHome-content a { color: var(--bp-cyan); }

/* ---- terminal window ---- */
.term { background: var(--bp-panel); border: 1px solid var(--bp-border); border-radius: 12px; overflow: hidden; box-shadow: 0 40px 80px -40px rgba(0,0,0,0.8); }
.term-bar { display: flex; align-items: center; gap: 8px; padding: 12px 16px; background: var(--bp-panel-2); border-bottom: 1px solid var(--bp-border); }
.term-dot { width: 12px; height: 12px; border-radius: 50%; }
.term-dot.r { background: #ff5f57; } .term-dot.y { background: #febc2e; } .term-dot.g { background: #28c840; }
.term-title { margin-left: 8px; font-family: var(--bp-mono); font-size: 12px; color: var(--bp-muted); }
.term-body { padding: 18px 20px; font-family: var(--bp-mono); font-size: 13.5px; line-height: 1.8; white-space: pre-wrap; }
.term-body .pr { color: var(--bp-green); } .term-body .cm { color: var(--bp-muted); }
.term-body .ok { color: var(--bp-green-bright); } .term-body .hl { color: var(--bp-amber); } .term-body .cy { color: var(--bp-cyan); }

/* ---- test262 progress ---- */
.t262 { background: linear-gradient(180deg, var(--bp-panel), var(--bp-panel-2)); border: 1px solid var(--bp-border); border-radius: 14px; padding: 26px 28px; }
.t262-head { display: flex; justify-content: space-between; align-items: baseline; flex-wrap: wrap; gap: 8px; }
.t262-label { font-family: var(--bp-mono); font-size: 12px; letter-spacing: 0.2em; text-transform: uppercase; color: var(--bp-muted); }
.t262-pct { font-family: var(--bp-mono); font-size: clamp(40px, 7vw, 64px); font-weight: 800; line-height: 1; background: linear-gradient(120deg, var(--bp-green-bright), var(--bp-cyan)); -webkit-background-clip: text; background-clip: text; -webkit-text-fill-color: transparent; }
.t262-track { margin-top: 18px; height: 16px; border-radius: 999px; background: #060a0e; border: 1px solid var(--bp-border); overflow: hidden; }
.t262-fill { height: 100%; border-radius: 999px; background: linear-gradient(90deg, var(--bp-green), var(--bp-cyan)); box-shadow: 0 0 18px rgba(43,213,118,0.6); transform-origin: left center; animation: t262grow 1.4s cubic-bezier(.2,.8,.2,1) both; }
@keyframes t262grow { from { transform: scaleX(0); } }
.t262-sub { margin-top: 14px; font-family: var(--bp-mono); font-size: 13px; color: var(--bp-muted); }
.t262-sub b { color: var(--bp-text); }

.t262-stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; margin-top: 22px; }
.t262-stat { background: var(--bp-bg); border: 1px solid var(--bp-border); border-radius: 10px; padding: 14px 16px; }
.t262-stat .n { font-family: var(--bp-mono); font-size: 24px; font-weight: 700; color: var(--bp-text); }
.t262-stat .n.bad { color: var(--bp-magenta); } .t262-stat .n.good { color: var(--bp-green-bright); }
.t262-stat .k { font-family: var(--bp-mono); font-size: 11px; letter-spacing: 0.12em; text-transform: uppercase; color: var(--bp-muted); margin-top: 4px; }

/* ---- feature cards ---- */
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 16px; }
.card { background: var(--bp-panel); border: 1px solid var(--bp-border); border-radius: 12px; padding: 22px; transition: border-color .2s, transform .2s; }
.card:hover { border-color: var(--bp-green); transform: translateY(-3px); }
.card .ico { font-family: var(--bp-mono); color: var(--bp-green); font-size: 13px; }
.card h3 { font-family: var(--bp-mono); font-size: 16px; margin: 10px 0 6px; color: var(--bp-text); }
.card p { color: var(--bp-muted); font-size: 14px; margin: 0; line-height: 1.6; }

/* suites table */
.suites { width: 100%; border-collapse: collapse; font-family: var(--bp-mono); font-size: 13px; }
.suites th { text-align: left; color: var(--bp-muted); font-weight: 500; text-transform: uppercase; letter-spacing: 0.1em; font-size: 11px; padding: 8px 12px; border-bottom: 1px solid var(--bp-border); }
.suites td { padding: 10px 12px; border-bottom: 1px solid var(--bp-border); }
.suites .mini { display: inline-block; width: 90px; height: 8px; border-radius: 999px; background: #060a0e; overflow: hidden; vertical-align: middle; margin-left: 8px; }
.suites .mini > i { display: block; height: 100%; background: linear-gradient(90deg, var(--bp-green), var(--bp-cyan)); }

/* ---- doc layout: keep the chrome on-brand dark (backstops for theme vars) ---- */
.BPSidebar { background: var(--bp-c-bg-alt); border-right: 1px solid var(--bp-c-border); }
.BPDocAside, .BPContent--doc, .BPContent--page { background: var(--bp-c-bg); }
.BPNavBarSearch-input { background: var(--bp-c-bg-soft); border: 1px solid var(--bp-c-border); color: var(--bp-text); }
.BPSidebarItem-link.is-active { color: var(--bp-amber); }
.BPDoc h1, .BPDoc h2, .BPDoc h3 { font-family: var(--bp-mono); letter-spacing: -0.02em; }
.BPDoc a { color: var(--bp-cyan); }
.BPDoc code:not(pre code) { background: var(--bp-c-bg-soft); border: 1px solid var(--bp-border); border-radius: 5px; padding: 0.15em 0.4em; font-family: var(--bp-mono); }
`

export default {
  title: 'zig-js',
  description: 'A JavaScript engine written in pure Zig — tree-walking interpreter, tiered bytecode VM, and a JavaScriptCore C-API drop-in.',

  docsDir: './docs',
  outDir: './dist',
  theme: 'bun',

  // Load the brand fonts (referenced by --bp-sans / --bp-mono in the CSS above).
  fonts: {
    google: [
      'Inter:wght@400;500;600;700;800',
      'JetBrains Mono:wght@400;500;600;700;800',
    ],
    display: 'swap',
  },

  nav: [
    { text: 'Guide', link: '/guide/' },
    { text: 'Architecture', link: '/architecture' },
    { text: 'Conformance', link: '/conformance' },
    { text: 'C-API', link: '/api' },
    { text: 'GitHub', link: 'https://github.com/stacksjs/zig-js' },
  ],

  markdown: {
    title: 'zig-js',
    meta: {
      description: 'A JavaScript engine written in pure Zig.',
      generator: 'bunpress',
    },
    sidebar: {
      '/': [
        {
          text: 'Introduction',
          items: [
            { text: 'What is zig-js?', link: '/guide/' },
            { text: 'Building & Running', link: '/guide/building' },
          ],
        },
        {
          text: 'Internals',
          items: [
            { text: 'Architecture', link: '/architecture' },
            { text: 'Threading', link: '/threads/' },
            { text: 'Thread API Reference', link: '/threads/api' },
            { text: 'Thread Testing', link: '/threads/testing' },
            { text: 'Limits & Roadmap', link: '/threads/limits' },
            { text: 'Thread API Design', link: '/threads/P6-thread-api' },
            { text: 'Thread State Audit', link: '/threads/bindings' },
            { text: 'test262 Conformance', link: '/conformance' },
          ],
        },
        {
          text: 'Embedding',
          items: [
            { text: 'JavaScriptCore C-API', link: '/api' },
          ],
        },
      ],
    },
    css,
  },

  sitemap: {
    baseUrl: 'https://zig-js.dev',
  },
} satisfies BunPressConfig
