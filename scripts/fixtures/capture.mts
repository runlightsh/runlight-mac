// Captures real Runlight API responses as test fixtures, from a throwaway hub built in memory
// from the Runlight source next door. Nothing touches a live install, and no token is saved.
//
//   cd ../runlight && node --import tsx ../runlight-mac/scripts/fixtures/capture.mts
//
// The clock is fixed and the made-up traffic comes from a seeded random generator, so the numbers
// are the same on every run; only the ids Runlight makes for goals, links, and tokens change. The hub has four sites, the way analytics.joncp.dev serves its own:
//   dailyphototips.com  busy, Toronto time, with a spike from photzy.com in the last hour
//   joncphillips.com    quieter, Toronto time
//   tulvane.com         small, London time
//   newsite.dev         no visits yet
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runlight } from "../../../runlight/packages/sdk/src/index.ts";
import { sqlite } from "../../../runlight/packages/sdk/src/stores/sqlite.ts";
import type { SessionRow } from "../../../runlight/packages/sdk/src/store.ts";

const OUT = new URL("../../Tests/Fixtures/", import.meta.url).pathname;
const ORIGIN = "https://hub.example";
const INSTALL_TOKEN = "install-secret-for-fixtures-only";
/** Wednesday, November 25, 2026, 3:30 pm in Toronto. */
const NOW = Date.parse("2026-11-25T20:30:00Z");
const DAYS = 35;
const HOUR = 3_600_000;
const DAY = 86_400_000;

// A small seeded generator (mulberry32), so the traffic is the same on every run.
let state = 0x5eed1e;
function random(): number {
  state = (state + 0x6d2b79f5) | 0;
  let t = Math.imul(state ^ (state >>> 15), 1 | state);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const hex = (n: number) => Array.from({ length: n }, () => Math.floor(random() * 16).toString(16)).join("");
function pick<T>(items: Array<[T, number]>): T {
  const total = items.reduce((sum, [, w]) => sum + w, 0);
  let r = random() * total;
  for (const [item, w] of items) if ((r -= w) <= 0) return item;
  return items[items.length - 1]![0];
}

const dir = mkdtempSync(join(tmpdir(), "runlight-mac-fixtures-"));
const rl = runlight({ store: sqlite({ path: join(dir, "hub.db") }), managedSites: true, now: () => NOW });
await rl.init();
const api = rl.routes({ basePath: "", token: INSTALL_TOKEN });

async function call(method: string, path: string, token: string | null, body?: unknown, contentType = "application/json") {
  const headers: Record<string, string> = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (body !== undefined && contentType) headers["content-type"] = contentType;
  const response = await api.handler(new Request(`${ORIGIN}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }));
  const text = await response.text();
  let json: unknown = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = null; }
  return { status: response.status, json, type: response.headers.get("content-type") ?? "" };
}

const manifest: Record<string, { method: string; path: string; token: string; status: number }> = {};
const secrets: string[] = [INSTALL_TOKEN];

/** Calls the API and saves the answer as `<name>.json`, refusing to write anything holding a token. */
async function capture(name: string, method: string, path: string, token: { label: string; value: string | null }, body?: unknown, contentType?: string) {
  const answer = await call(method, path, token.value, body, contentType);
  const text = JSON.stringify(answer.json, null, 2) + "\n";
  for (const secret of secrets) if (text.includes(secret)) throw new Error(`${name} contains a token`);
  writeFileSync(join(OUT, `${name}.json`), text);
  manifest[name] = { method, path, token: token.label, status: answer.status };
  return answer;
}

async function must(method: string, path: string, body?: unknown) {
  const answer = await call(method, path, INSTALL_TOKEN, body);
  if (answer.status >= 300) throw new Error(`${method} ${path}: ${answer.status} ${JSON.stringify(answer.json)}`);
  return answer.json as Record<string, any>;
}

// Sites. The first site of a managed install is "default"; rename it to the busy one.
const sites = [
  { name: "DailyPhotoTips", hostnames: ["dailyphototips.com"], timezone: "America/Toronto", daily: 900, spike: true },
  { name: "joncphillips.com", hostnames: ["joncphillips.com"], timezone: "America/Toronto", daily: 140, spike: false },
  { name: "Tulvane", hostnames: ["tulvane.com"], timezone: "Europe/London", daily: 40, spike: false },
  { name: "newsite.dev", hostnames: ["newsite.dev"], timezone: "America/Los_Angeles", daily: 0, spike: false },
];
const existing = (await must("GET", "/api/sites")).sites as Array<{ id: string }>;
const ids: string[] = [];
for (const [i, site] of sites.entries()) {
  if (i === 0 && existing[0]) {
    await must("PATCH", `/api/sites/${existing[0].id}`, { name: site.name, hostnames: site.hostnames, timezone: site.timezone });
    ids.push(existing[0].id);
  } else {
    ids.push((await must("POST", "/api/sites", { name: site.name, hostnames: site.hostnames, timezone: site.timezone })).site.id);
  }
}
const [dpt, jcp, tulvane, empty] = ids as [string, string, string, string];

// Traffic.
const pages: Record<string, Array<[string, number]>> = {
  [dpt]: [["/", 25], ["/tips/golden-hour", 14], ["/tips/long-exposure", 11], ["/tools/depth-of-field", 10], ["/tips/milky-way", 8], ["/newsletter", 6], ["/thanks", 2], ["/about", 3]],
  [jcp]: [["/", 30], ["/blog/building-runlight", 14], ["/blog/cronwatch", 9], ["/about", 8], ["/projects", 6], ["/uses", 4]],
  [tulvane]: [["/", 40], ["/pricing", 15], ["/about", 8], ["/contact", 4]],
};
const sources: Array<[{ ref: string; source: string; channel: string }, number]> = [
  [{ ref: "", source: "", channel: "Direct" }, 30],
  [{ ref: "google.com", source: "Google", channel: "Organic Search" }, 30],
  [{ ref: "bing.com", source: "Bing", channel: "Organic Search" }, 3],
  [{ ref: "duckduckgo.com", source: "DuckDuckGo", channel: "Organic Search" }, 3],
  [{ ref: "chatgpt.com", source: "ChatGPT", channel: "AI" }, 5],
  [{ ref: "news.ycombinator.com", source: "Hacker News", channel: "Social" }, 3],
  [{ ref: "pinterest.com", source: "Pinterest", channel: "Social" }, 6],
  [{ ref: "reddit.com", source: "Reddit", channel: "Social" }, 4],
  [{ ref: "photzy.com", source: "photzy.com", channel: "Referral" }, 2],
];
const photzy = sources[8]![0];
const hours: Array<[number, number]> = Array.from({ length: 24 }, (_, h) => [h, 1 + 4 * Math.exp(-((h - 14) ** 2) / 18)]);

async function visit(site: string, host: string, start: number, src: { ref: string; source: string; channel: string }, signup: boolean) {
  const id = hex(24);
  const visitor = hex(16);
  const row: SessionRow = {
    id, site, visitor, startedAt: start, hostname: host,
    referrerHost: src.ref, referrerPath: src.ref ? "/" : "", source: src.source, channel: src.channel,
    utmSource: "", utmMedium: "", utmCampaign: "", utmTerm: "", utmContent: "",
    country: "CA", region: "CA-ON", city: "Toronto", browser: "Safari", browserVersion: "18", os: "macOS", osVersion: "",
    device: "desktop", screen: "1512x982", language: "en-CA",
  };
  await rl.store.insertSession(row);
  const views = Math.min(6, 1 + Math.floor(-Math.log(random()) * 0.9));
  let t = start;
  for (let v = 0; v < views; v++) {
    const path = signup && v === views - 1 ? "/thanks" : pick(pages[site]!);
    const pv = hex(12);
    await rl.store.touchSession(id, t, "pageview", path);
    await rl.store.insertEvent({ site, ts: t, kind: "pageview", visitor, session: id, pageview: pv, path, hostname: host, title: path, name: "", props: null, engagedMs: 0, scroll: null, link: "" });
    const engaged = views === 1 && random() < 0.45 ? Math.floor(random() * 9000) : Math.floor(8000 + random() * 120_000);
    if (engaged >= 1000 && t + engaged < NOW) {
      await rl.store.addEngagement(id, engaged);
      await rl.store.insertEvent({ site, ts: t + engaged, kind: "engagement", visitor, session: id, pageview: pv, path, hostname: host, title: "", name: "", props: null, engagedMs: engaged, scroll: 60, link: "" });
    }
    if (signup && v === views - 1) {
      await rl.store.insertEvent({ site, ts: t + 1500, kind: "event", visitor, session: id, pageview: pv, path, hostname: host, title: "", name: "Signup", props: null, engagedMs: 0, scroll: null, link: "" });
    }
    t += Math.max(engaged, 5000);
    if (t >= NOW) break;
  }
}

await rl.store.db.run("BEGIN");
for (const [i, site] of sites.entries()) {
  if (!site.daily) continue;
  const id = ids[i]!;
  const host = site.hostnames[0]!;
  for (let day = DAYS; day >= 0; day--) {
    const dayStart = Math.floor((NOW - day * DAY) / DAY) * DAY;
    const weekday = new Date(dayStart).getUTCDay();
    const count = Math.round(site.daily * (weekday === 0 || weekday === 6 ? 0.7 : 1) * (0.85 + random() * 0.3));
    for (let n = 0; n < count; n++) {
      const start = dayStart + pick(hours) * HOUR + Math.floor(random() * HOUR);
      if (start >= NOW) continue;
      await visit(id, host, start, pick(sources), id === dpt && random() < 0.03);
    }
  }
  // The spike: photzy.com sends a burst over the last hour.
  if (site.spike) for (let n = 0; n < 420; n++) await visit(id, host, NOW - Math.floor(random() * HOUR), photzy, random() < 0.05);
  // People reading right now.
  for (let n = 0; n < Math.ceil(site.daily / 150); n++) await visit(id, host, NOW - Math.floor(random() * 240_000), pick(sources), false);
}
await rl.store.db.run("COMMIT");
while (await rl.buildRollups()) { /* Catch up before reading. */ }

// Tokens: a read token for every site, and a manage token for DailyPhotoTips.
const read = (await must("POST", "/api/tokens", { name: "Mac app (read)", site: "", scope: "read" })).secret as string;
const manage = (await must("POST", "/api/tokens", { name: "Mac app (manage)", site: dpt, scope: "manage" })).secret as string;
secrets.push(read, manage);
const R = { label: "read", value: read };
const M = { label: "manage", value: manage };
const NONE = { label: "none", value: null };
const BAD = { label: "wrong", value: "rl_0000000000000000000000000000000000000000" };

// Goals and a link to read back, made with the install token so they aren't fixtures themselves.
await must("POST", `/api/goals?site=${dpt}`, { name: "Newsletter signup", kind: "event", match: "Signup", valueMode: "fixed", value: 2 });
await must("POST", `/api/goals?site=${dpt}`, { name: "Thanks page", kind: "page", match: "/thanks*" });
await must("POST", `/api/goals?site=${dpt}`, { name: "Buy button", kind: "click", clickBy: "selector", match: "#buy" });
const youtube = (await must("POST", `/api/links?site=${dpt}`, { url: "https://dailyphototips.com/newsletter?utm_source=youtube", slug: "yt", name: "YouTube bio" })).link as { id: string };
// Clicks on it over the last month, each its own short visit, as the link handler records them.
await rl.store.db.run("BEGIN");
for (let n = 0; n < 180; n++) {
  const ts = NOW - Math.floor(random() * 30 * DAY);
  const session = hex(24);
  const visitor = hex(16);
  const src = pick(sources);
  await rl.store.insertSession({
    id: session, site: dpt, visitor, startedAt: ts, hostname: "hub.example",
    referrerHost: src.ref, referrerPath: src.ref ? "/" : "", source: src.source, channel: src.channel,
    utmSource: "", utmMedium: "", utmCampaign: "", utmTerm: "", utmContent: "",
    country: "US", region: "US-NY", city: "New York", browser: "Chrome", browserVersion: "129", os: "iOS", osVersion: "18",
    device: "mobile", screen: "393x852", language: "en-US",
  });
  await rl.store.insertEvent({ site: dpt, ts, kind: "click", visitor, session, pageview: "", path: "/", hostname: "hub.example", title: "", name: "", props: null, engagedMs: 0, scroll: null, link: youtube.id });
}
await rl.store.db.run("COMMIT");
while (await rl.buildRollups()) { /* Count the clicks too. */ }

rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });

// Connecting.
await capture("api", "GET", "/api", NONE);
await capture("token-read", "GET", "/api/token", R);
await capture("token-manage", "GET", "/api/token", M);
await capture("sites", "GET", "/api/sites", R);
await capture("icon-none", "GET", `/api/icon?site=${empty}`, R);

// Reading.
for (const period of ["today", "7d", "30d"]) await capture(`stats-${period}`, "GET", `/api/stats?site=${dpt}&period=${period}`, R);
await capture("stats-today-empty", "GET", `/api/stats?site=${empty}&period=today`, R);
await capture("stats-today-london", "GET", `/api/stats?site=${tulvane}&period=today`, R);
await capture("series-today", "GET", `/api/series?site=${dpt}&period=today&interval=hour&compare=previous`, R);
await capture("series-today-london", "GET", `/api/series?site=${tulvane}&period=today&interval=hour&compare=previous`, R);
await capture("series-today-empty", "GET", `/api/series?site=${empty}&period=today&interval=hour&compare=previous`, R);
await capture("series-7d-baseline", "GET", `/api/series?site=${dpt}&period=7d&interval=hour&compare=off`, R);
await capture("goals-today", "GET", `/api/goals?site=${dpt}&period=today`, R);
await capture("goals-30d", "GET", `/api/goals?site=${dpt}&period=30d`, R);
await capture("goals-empty", "GET", `/api/goals?site=${empty}&period=today`, R);
await capture("goals-definitions", "GET", `/api/goals?site=${dpt}&definitions=1`, R);
await capture("realtime", "GET", `/api/realtime?site=${dpt}`, R);
await capture("realtime-empty", "GET", `/api/realtime?site=${empty}`, R);
await capture("breakdown-page", "GET", `/api/breakdown?site=${dpt}&period=today&dimension=page&limit=5`, R);
await capture("breakdown-source", "GET", `/api/breakdown?site=${dpt}&period=today&dimension=source&limit=5`, R);
await capture("breakdown-source-50", "GET", `/api/breakdown?site=${dpt}&period=today&dimension=source&limit=50`, R);
await capture("links", "GET", `/api/links?site=${dpt}&period=30d`, R);
const linkId = ((await call("GET", `/api/links?site=${dpt}`, read)).json as any).links[0].id as string;
await capture("link", "GET", `/api/links/${linkId}?site=${dpt}&period=30d`, R);

// Editing with the manage token.
const created = await capture("goal-create", "POST", `/api/goals?site=${dpt}`, M, { name: "Download preset", kind: "event", match: "Download", valueMode: "none" });
const goalId = (created.json as any).goal.id as string;
await capture("goal-update", "PATCH", `/api/goals/${goalId}?site=${dpt}`, M, { name: "Download a preset", kind: "event", match: "Download", valueMode: "fixed", value: 5 });
await capture("goal-delete", "DELETE", `/api/goals/${goalId}?site=${dpt}`, M);
const link = await capture("link-create", "POST", `/api/links?site=${dpt}`, M, { url: "https://dailyphototips.com/tools/depth-of-field", slug: "dof", name: "DOF calculator" });
const newLinkId = (link.json as any).link.id as string;
await capture("link-update", "PATCH", `/api/links/${newLinkId}?site=${dpt}`, M, { name: "Depth of field calculator", slug: "depth" });
await capture("link-delete", "DELETE", `/api/links/${newLinkId}?site=${dpt}`, M);
await capture("site-update", "PATCH", `/api/sites/${dpt}`, M, { name: "Daily Photo Tips", timezone: "America/New_York", retentionMonths: 24 });

// Errors.
await capture("error-unauthorized", "GET", "/api/sites", BAD);
await capture("error-token-read-only", "POST", `/api/goals?site=${dpt}`, R, { name: "Nope", kind: "event", match: "Nope" });
await capture("error-token-manage-only", "PATCH", `/api/sites/${jcp}`, M, { name: "Not mine" });
await capture("error-unknown-site", "GET", "/api/stats?site=nosuchsite&period=today", R);
await capture("error-unknown-goal", "DELETE", `/api/goals/nosuchgoal?site=${dpt}`, M);
await capture("error-link-taken", "POST", `/api/links?site=${dpt}`, M, { url: "https://dailyphototips.com/", slug: "yt" });
await capture("error-goal-name", "POST", `/api/goals?site=${dpt}`, M, { name: "", kind: "event", match: "x" });
await capture("error-goal-page", "POST", `/api/goals?site=${dpt}`, M, { name: "Bad page", kind: "page", match: "" });
await capture("error-link-url", "POST", `/api/links?site=${dpt}`, M, { url: "not a url" });
await capture("error-retention", "PATCH", `/api/sites/${dpt}`, M, { retentionMonths: 7 });
await capture("error-timezone", "PATCH", `/api/sites/${dpt}`, M, { timezone: "Mars/Olympus" });
await capture("error-send-json", "POST", `/api/goals?site=${dpt}`, M, { name: "x", kind: "event", match: "x" }, "text/plain");

writeFileSync(join(OUT, "manifest.json"), JSON.stringify({ now: new Date(NOW).toISOString(), sites: { dpt, jcp, tulvane, empty }, fixtures: manifest }, null, 2) + "\n");
rmSync(dir, { recursive: true, force: true });
console.log(`Wrote ${Object.keys(manifest).length} fixtures to ${OUT}`);
