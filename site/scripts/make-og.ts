#!/usr/bin/env bun
// Renders scripts/og.html to public/og.png, the link-preview card.
//
//   bun scripts/make-og.ts [output]
//
// Headless Chrome does the rasterising, so the card is written in the same
// CSS the site is written in and there is no image toolchain to install.
// Point CHROME at a binary if the ones guessed below aren't there.

import { existsSync } from "node:fs";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const WIDTH = 1200;
const HEIGHT = 630;

// Google serves woff2 only to browsers it recognises; asking as one keeps the
// font files small enough to inline.
const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

const source = resolve(import.meta.dir, "og.html");
const output = resolve(process.argv[2] ?? resolve(import.meta.dir, "../public/og.png"));

const candidates = [
  process.env.CHROME,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "google-chrome",
  "chromium",
].filter((path): path is string => Boolean(path));

const chrome =
  candidates.find((path) => path.includes("/") && existsSync(path)) ??
  candidates.find((path) => !path.includes("/") && Bun.which(path));

if (!chrome) {
  console.error("No Chrome found. Set CHROME to a Chrome or Chromium binary.");
  process.exit(1);
}

// curl rather than fetch: this is the only network call here, and curl already
// honours whatever proxy and certificate configuration the machine has.
const download = async (url: string): Promise<Buffer> => {
  const proc = Bun.spawn(["curl", "-sSfL", "-A", UA, url], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const [body, error, code] = await Promise.all([
    new Response(proc.stdout).arrayBuffer(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (code !== 0) throw new Error(`Fetching ${url} failed: ${error.trim()}`);
  return Buffer.from(body);
};

// The card is rendered from a copy with the webfonts inlined as data URIs.
// og.html keeps the ordinary <link> so it can be opened and edited straight
// from the filesystem, but a render that reaches the network is a render that
// can quietly fall back to Times — and the card is mostly Instrument Serif.
const html = await Bun.file(source).text();
const fontsHref = html.match(
  /<link[^>]*href="(https:\/\/fonts\.googleapis\.com\/[^"]+)"/,
)?.[1];

if (!fontsHref) {
  console.error(`No Google Fonts stylesheet linked in ${source}.`);
  process.exit(1);
}

let fontCss = (await download(fontsHref.replace(/&amp;/g, "&"))).toString("utf8");

for (const url of new Set(fontCss.match(/https:\/\/fonts\.gstatic\.com\/[^)]+/g) ?? [])) {
  const woff2 = await download(url);
  fontCss = fontCss.replaceAll(url, `data:font/woff2;base64,${woff2.toString("base64")}`);
}

const page = html
  .replace(/[ \t]*<link[^>]*rel="preconnect"[^>]*>\n?/g, "")
  .replace(/[ \t]*<link[^>]*fonts\.googleapis\.com[^>]*>/, `<style>\n${fontCss}</style>`);

// Chrome is driven over the DevTools protocol rather than with --screenshot,
// which sizes its capture from the *window* — browser chrome included — and so
// silently crops the bottom 80-odd pixels off a --window-size=1200,630 shot.
// Over CDP the viewport and the capture are both stated outright.
const profile = await mkdtemp(join(tmpdir(), "posture-og-"));
const browser = Bun.spawn(
  [
    chrome,
    "--headless",
    "--disable-gpu",
    // Chrome refuses to start its sandbox as root, which is how it runs in a
    // container. Rendering a local document needs no sandbox to be safe.
    ...(process.getuid?.() === 0 ? ["--no-sandbox"] : []),
    "--force-color-profile=srgb",
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "about:blank",
  ],
  { stdout: "ignore", stderr: "ignore" },
);

// Chrome writes the port it settled on into the profile once it's listening.
const endpoint = async () => {
  for (let attempt = 0; attempt < 100; attempt++) {
    const file = await readFile(join(profile, "DevToolsActivePort"), "utf8").catch(() => "");
    const [port, path] = file.trim().split("\n");
    if (port && path) return `ws://127.0.0.1:${port}${path}`;
    await Bun.sleep(100);
  }
  throw new Error("Chrome never opened a DevTools port.");
};

const socket = new WebSocket(await endpoint());
const pending = new Map<number, (result: any) => void>();
let lastId = 0;

socket.onmessage = (event) => {
  const message = JSON.parse(String(event.data));
  const settle = pending.get(message.id);
  if (!settle) return;
  pending.delete(message.id);
  if (message.error) throw new Error(`${message.error.message} (id ${message.id})`);
  settle(message.result);
};

await new Promise((ready, fail) => {
  socket.onopen = ready;
  socket.onerror = () => fail(new Error("Could not attach to Chrome."));
});

const send = (method: string, params: object = {}, sessionId?: string): Promise<any> =>
  new Promise((settle) => {
    const id = ++lastId;
    pending.set(id, settle);
    socket.send(JSON.stringify({ id, method, params, sessionId }));
  });

try {
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });

  await send(
    "Emulation.setDeviceMetricsOverride",
    { width: WIDTH, height: HEIGHT, deviceScaleFactor: 1, mobile: false },
    sessionId,
  );
  await send("Page.enable", {}, sessionId);

  const { frameTree } = await send("Page.getFrameTree", {}, sessionId);
  await send("Page.setDocumentContent", { frameId: frameTree.frame.id, html: page }, sessionId);

  // Waiting on the font set rather than on a timer: layout shifts when the
  // real faces land, and a screenshot taken mid-swap is subtly wrong.
  await send(
    "Runtime.evaluate",
    { expression: "document.fonts.ready.then(() => document.fonts.size)", awaitPromise: true },
    sessionId,
  );

  const shot = await send(
    "Page.captureScreenshot",
    { format: "png", clip: { x: 0, y: 0, width: WIDTH, height: HEIGHT, scale: 1 } },
    sessionId,
  );

  await Bun.write(output, Buffer.from(shot.data, "base64"));
} finally {
  socket.close();
  browser.kill();
  await browser.exited;
  await rm(profile, { recursive: true, force: true });
}

const bytes = (await Bun.file(output).arrayBuffer()).byteLength;
console.log(`Wrote ${output} (${WIDTH}x${HEIGHT}, ${Math.round(bytes / 1024)} KB)`);
