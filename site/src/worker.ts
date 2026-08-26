// Counts visits and downloads server-side, so the page ships no analytics
// script and the CSP can stay at `script-src 'none'`.
//
// This is why the Worker exists at all — the previous assets-only setup had no
// script to invoke, which was the right call until there was something to
// measure. `run_worker_first` in wrangler.jsonc limits invocations to the two
// pages and the two download files; CSS, images and favicons still come
// straight from asset storage without waking this up.

interface AnalyticsEngineDataset {
  writeDataPoint(event: {
    blobs?: (string | null)[];
    doubles?: number[];
    indexes?: string[];
  }): void;
}

interface Env {
  ASSETS: { fetch: (request: Request) => Promise<Response> };
  ANALYTICS: AnalyticsEngineDataset;
  // Rotates the visitor hash so it can't be reversed by guessing IP + UA.
  // Set once with `wrangler secret put VISITOR_SALT`; counting still works
  // without it, the hashes are just weaker.
  VISITOR_SALT?: string;
}

// Clicks are counted on /download, which redirects, rather than on
// /Posture.dmg itself. Two reasons. One request for the file is not one
// download: a resumed or retried transfer issues several, so counting the file
// would inflate the number, while counting the redirect counts the intent
// once. And it keeps an 882 KB transfer off the Worker entirely — no
// invocation, and nothing of ours between the browser and asset storage that
// could affect ranges or caching.
const DOWNLOAD_PATH = "/download";
const DOWNLOAD_TARGET = "/Posture.dmg";

// Deliberately crude. Real bot classification needs Cloudflare's paid Bot
// Management, so this only catches the self-identifying ones and the numbers
// should be read as "requests from things that didn't announce themselves".
const BOT = /bot|crawler|crawl|spider|slurp|curl|wget|headless|preview|fetch|monitor|scan|python-requests|go-http/i;

/** Truncated so the stored value is a bucket, not an identifier. */
const fingerprint = async (request: Request, salt: string, day: string) => {
  const ip = request.headers.get("cf-connecting-ip") ?? "";
  const ua = request.headers.get("user-agent") ?? "";
  const bytes = new TextEncoder().encode(`${day}:${salt}:${ip}:${ua}`);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)]
    .slice(0, 8)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
};

// Hostname only. Full referrer URLs carry query strings, which is more than is
// needed to answer "where did they come from" and more than worth storing.
const referrerHost = (request: Request) => {
  const referrer = request.headers.get("referer");
  if (!referrer) return "direct";
  try {
    const host = new URL(referrer).hostname;
    return host === new URL(request.url).hostname ? "internal" : host;
  } catch {
    return "unparseable";
  }
};

const record = async (request: Request, env: Env, path: string, kind: string) => {
  const day = new Date().toISOString().slice(0, 10);
  const visitor = await fingerprint(request, env.VISITOR_SALT ?? "unsalted", day);

  env.ANALYTICS.writeDataPoint({
    blobs: [
      kind,
      path,
      (request as { cf?: { country?: string } }).cf?.country ?? "unknown",
      referrerHost(request),
      visitor,
      BOT.test(request.headers.get("user-agent") ?? "") ? "bot" : "human",
    ],
    doubles: [1],
    // Sampling groups by index, so keying on kind keeps downloads — the rarer
    // and more interesting event — from being sampled away alongside views.
    indexes: [kind],
  });
};

export default {
  async fetch(
    request: Request,
    env: Env,
    ctx: { waitUntil: (p: Promise<unknown>) => void },
  ) {
    const path = new URL(request.url).pathname;
    const isDownload = path === DOWNLOAD_PATH;

    // GET only. A HEAD from a link unfurler isn't a visit.
    if (request.method === "GET") {
      // waitUntil, so hashing and the write never sit in front of the response.
      ctx.waitUntil(record(request, env, path, isDownload ? "download" : "view"));
    }

    if (isDownload) {
      // 302 and no-store, deliberately. A cacheable redirect would be served
      // from the browser or the edge on the second click and never reach this
      // Worker, silently under-counting every repeat download.
      return new Response(null, {
        status: 302,
        headers: { Location: DOWNLOAD_TARGET, "Cache-Control": "no-store" },
      });
    }

    return env.ASSETS.fetch(request);
  },
};
