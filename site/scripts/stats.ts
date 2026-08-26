#!/usr/bin/env bun
// Reads the site's visit and download counts out of Analytics Engine.
//
//   bun scripts/stats.ts [days]
//
// Needs CLOUDFLARE_API_TOKEN with Account Analytics: Read, and
// CLOUDFLARE_ACCOUNT_ID. Free plan allows 10k of these queries a day.

const token = process.env.CLOUDFLARE_API_TOKEN;
const account = process.env.CLOUDFLARE_ACCOUNT_ID;

if (!token || !account) {
  console.error(
    "Set CLOUDFLARE_API_TOKEN (Account Analytics: Read) and CLOUDFLARE_ACCOUNT_ID.",
  );
  process.exit(1);
}

const days = Number(process.argv[2] ?? 30);
const DATASET = "posture_site";

// Everything below counts humans only. blob6 is the bot flag the Worker sets
// from the user agent — crude, but the alternative is paid Bot Management.
const HUMAN = "blob6 = 'human'";
const WINDOW = `timestamp > NOW() - INTERVAL '${days}' DAY`;

const query = async (sql: string) => {
  const res = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${account}/analytics_engine/sql`,
    { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: sql },
  );
  if (!res.ok) {
    console.error(`Query failed (${res.status}): ${await res.text()}`);
    process.exit(1);
  }
  const body = (await res.json()) as { data: Record<string, string>[] };
  return body.data;
};

const table = (rows: Record<string, string>[], label: string, value: string) => {
  if (rows.length === 0) return "  (nothing yet)";
  const width = Math.max(...rows.map((r) => String(r[label]).length));
  return rows
    .map((r) => `  ${String(r[label]).padEnd(width)}  ${r[value]}`)
    .join("\n");
};

const [totals, paths, referrers, countries, bots] = await Promise.all([
  query(`SELECT blob1 AS kind, count() AS events, count(DISTINCT blob5) AS people
         FROM ${DATASET} WHERE ${WINDOW} AND ${HUMAN}
         GROUP BY kind ORDER BY events DESC`),
  query(`SELECT blob2 AS path, count() AS hits
         FROM ${DATASET} WHERE ${WINDOW} AND ${HUMAN}
         GROUP BY path ORDER BY hits DESC LIMIT 10`),
  query(`SELECT blob4 AS referrer, count() AS hits
         FROM ${DATASET} WHERE ${WINDOW} AND ${HUMAN}
         GROUP BY referrer ORDER BY hits DESC LIMIT 8`),
  query(`SELECT blob3 AS country, count() AS hits
         FROM ${DATASET} WHERE ${WINDOW} AND ${HUMAN}
         GROUP BY country ORDER BY hits DESC LIMIT 8`),
  query(`SELECT blob6 AS agent, count() AS hits
         FROM ${DATASET} WHERE ${WINDOW}
         GROUP BY agent ORDER BY hits DESC`),
]);

const find = (kind: string) => totals.find((r) => r.kind === kind);
const views = find("view");
const downloads = find("download");

console.log(`\nPosture — last ${days} days\n`);
console.log(`  Visits      ${views?.events ?? 0} from ${views?.people ?? 0} people`);
console.log(
  `  Downloads   ${downloads?.events ?? 0} from ${downloads?.people ?? 0} people`,
);

// The number he'll actually care about, and the one that's easy to get wrong by
// dividing the raw counts instead of the deduplicated ones.
const people = Number(views?.people ?? 0);
const downloaders = Number(downloads?.people ?? 0);
if (people > 0) {
  console.log(`  Conversion  ${((downloaders / people) * 100).toFixed(1)}%`);
}

console.log(`\nPaths\n${table(paths, "path", "hits")}`);
console.log(`\nReferrers\n${table(referrers, "referrer", "hits")}`);
console.log(`\nCountries\n${table(countries, "country", "hits")}`);
console.log(`\nAgents (unfiltered)\n${table(bots, "agent", "hits")}\n`);
