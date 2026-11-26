// Serves a throwaway Runlight install on this Mac for screenshots: five made-up sites with made-up
// traffic up to the current minute, built in memory from the Runlight source next door. Nothing
// here is a real site or a real visit, and nothing is saved.
//
//   cd ../runlight && node --import tsx ../runlight-mac/scripts/demo/serve.mts
//
// It prints a debug launch line for the app with the address and a read token made for this run.
// That token opens only this throwaway install and is gone when the script stops.
import { randomBytes } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runlight } from "../../../runlight/packages/sdk/src/index.ts";
import { sqlite } from "../../../runlight/packages/sdk/src/stores/sqlite.ts";

const PORT = Number(process.env.PORT ?? 4391);
const ORIGIN = `http://127.0.0.1:${PORT}`;
const ICONS = new URL("./icons/", import.meta.url).pathname;
const INSTALL_TOKEN = randomBytes(24).toString("hex");
const NOW = Date.now();
const DAYS = 35;
const MINUTE = 60_000;
const HOUR = 3_600_000;
const DAY = 86_400_000;
const ZONE = "America/Toronto";

// A seeded generator (mulberry32), so a run made at the same time of day looks the same.
let state = 0x7a1fa7e;
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

/** Midnight in Toronto on the day `ms` falls in. */
function midnight(ms: number): number {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: ZONE, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" }).formatToParts(ms);
  const get = (type: string) => Number(parts.find((p) => p.type === type)!.value);
  const sinceMidnight = ((get("hour") * 60 + get("minute")) * 60 + get("second")) * 1000 + (ms % 1000);
  return ms - sinceMidnight;
}

type Source = { ref: string; source: string; channel: string };
const SOURCES: Array<[Source, number]> = [
  [{ ref: "", source: "", channel: "Direct" }, 30],
  [{ ref: "google.com", source: "Google", channel: "Organic Search" }, 32],
  [{ ref: "bing.com", source: "Bing", channel: "Organic Search" }, 3],
  [{ ref: "duckduckgo.com", source: "DuckDuckGo", channel: "Organic Search" }, 4],
  [{ ref: "chatgpt.com", source: "ChatGPT", channel: "AI" }, 6],
  [{ ref: "perplexity.ai", source: "Perplexity", channel: "AI" }, 2],
  [{ ref: "linkedin.com", source: "LinkedIn", channel: "Social" }, 5],
  [{ ref: "reddit.com", source: "Reddit", channel: "Social" }, 4],
  [{ ref: "news.ycombinator.com", source: "Hacker News", channel: "Social" }, 2],
];
const HN = SOURCES[8]![0];
const PLACES: Array<[{ country: string; region: string; city: string; language: string }, number]> = [
  [{ country: "US", region: "US-NY", city: "New York", language: "en-US" }, 20],
  [{ country: "US", region: "US-CA", city: "San Francisco", language: "en-US" }, 14],
  [{ country: "CA", region: "CA-ON", city: "Toronto", language: "en-CA" }, 10],
  [{ country: "GB", region: "GB-ENG", city: "London", language: "en-GB" }, 12],
  [{ country: "DE", region: "DE-BE", city: "Berlin", language: "de-DE" }, 7],
  [{ country: "FR", region: "FR-IDF", city: "Paris", language: "fr-FR" }, 5],
  [{ country: "AU", region: "AU-NSW", city: "Sydney", language: "en-AU" }, 4],
];
const DEVICES: Array<[{ browser: string; os: string; device: string; screen: string }, number]> = [
  [{ browser: "Chrome", os: "macOS", device: "desktop", screen: "1512x982" }, 30],
  [{ browser: "Safari", os: "macOS", device: "desktop", screen: "1728x1117" }, 18],
  [{ browser: "Chrome", os: "Windows", device: "desktop", screen: "1920x1080" }, 22],
  [{ browser: "Safari", os: "iOS", device: "mobile", screen: "393x852" }, 20],
  [{ browser: "Chrome", os: "Android", device: "mobile", screen: "412x915" }, 10],
];

// The sites. `today` scales today's traffic against the days before, so the changes vary.
const SITES = [
  { name: "Tulvane", host: "tulvane.com", daily: 1250, today: 1.16, now: 14, goal: { name: "Trial started", event: "Trial", rate: 0.012 },
    pages: [["/", 30], ["/pricing", 16], ["/features/scheduling", 10], ["/blog/planning-a-quarter-without-spreadsheets", 12], ["/customers", 6], ["/docs/getting-started", 8], ["/signup", 4]] as Array<[string, number]> },
  { name: "Kettle & Pine", host: "kettleandpine.com", daily: 410, today: 0.91, now: 3, goal: { name: "Order placed", event: "Order", rate: 0.01 },
    pages: [["/", 28], ["/shop/cast-iron-kettle", 14], ["/shop", 18], ["/journal/brewing-loose-leaf", 9], ["/about", 5]] as Array<[string, number]> },
  { name: "Maplestack", host: "maplestack.dev", daily: 230, today: 1.38, now: 2, goal: null,
    pages: [["/", 24], ["/docs", 20], ["/docs/install", 14], ["/changelog", 8], ["/blog/v2", 6]] as Array<[string, number]> },
  { name: "Fieldnote", host: "fieldnote.blog", daily: 96, today: 0.78, now: 1, goal: null,
    pages: [["/", 30], ["/posts/a-year-of-morning-pages", 16], ["/posts/notebooks-i-have-loved", 12], ["/about", 6]] as Array<[string, number]> },
  { name: "Saltgrass Studio", host: "saltgrass.studio", daily: 38, today: 1.0, now: 0, goal: null,
    pages: [["/", 40], ["/work", 20], ["/contact", 8]] as Array<[string, number]> },
];

// Visits through the day, busiest in the early afternoon.
const HOURS: Array<[number, number]> = Array.from({ length: 24 }, (_, h) => [h, 0.6 + 4 * Math.exp(-((h - 13.5) ** 2) / 16)]);

const dir = mkdtempSync(join(tmpdir(), "runlight-mac-demo-"));
const rl = runlight({ store: sqlite({ path: join(dir, "demo.db") }), managedSites: true });
await rl.init();
const api = rl.routes({ basePath: "", token: INSTALL_TOKEN });

async function must(method: string, path: string, body?: unknown): Promise<Record<string, any>> {
  const headers: Record<string, string> = { authorization: `Bearer ${INSTALL_TOKEN}` };
  if (body !== undefined) headers["content-type"] = "application/json";
  const response = await api.handler(new Request(`${ORIGIN}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }));
  const json = await response.json().catch(() => null);
  if (response.status >= 300) throw new Error(`${method} ${path}: ${response.status} ${JSON.stringify(json)}`);
  return json as Record<string, any>;
}

const existing = (await must("GET", "/api/sites")).sites as Array<{ id: string }>;
const ids: string[] = [];
for (const [i, site] of SITES.entries()) {
  const fields = { name: site.name, hostnames: [site.host], timezone: ZONE };
  if (i === 0 && existing[0]) {
    await must("PATCH", `/api/sites/${existing[0].id}`, fields);
    ids.push(existing[0].id);
  } else {
    ids.push((await must("POST", "/api/sites", fields)).site.id);
  }
}

async function visit(site: string, host: string, pages: Array<[string, number]>, start: number, src: Source, goal: string | null, returning: string[] = []) {
  const id = hex(24);
  // Some people come back later the same day, so visits run a little ahead of visitors.
  const visitor = returning.length && random() < 0.08 ? returning[Math.floor(random() * returning.length)]! : hex(16);
  returning.push(visitor);
  const place = pick(PLACES);
  const device = pick(DEVICES);
  await rl.store.insertSession({
    id, site, visitor, startedAt: start, hostname: host,
    referrerHost: src.ref, referrerPath: src.ref ? "/" : "", source: src.source, channel: src.channel,
    utmSource: "", utmMedium: "", utmCampaign: "", utmTerm: "", utmContent: "",
    country: place.country, region: place.region, city: place.city, browser: device.browser, browserVersion: "", os: device.os, osVersion: "",
    device: device.device, screen: device.screen, language: place.language,
  });
  const views = Math.min(6, 1 + Math.floor(-Math.log(random()) * 0.9));
  let t = start;
  for (let v = 0; v < views; v++) {
    const path = pick(pages);
    const pv = hex(12);
    await rl.store.touchSession(id, t, "pageview", path);
    await rl.store.insertEvent({ site, ts: t, kind: "pageview", visitor, session: id, pageview: pv, path, hostname: host, title: path, name: "", props: null, engagedMs: 0, scroll: null, link: "" });
    const engaged = views === 1 && random() < 0.45 ? Math.floor(random() * 9000) : Math.floor(8000 + random() * 120_000);
    if (engaged >= 1000 && t + engaged < NOW) {
      await rl.store.addEngagement(id, engaged);
      await rl.store.insertEvent({ site, ts: t + engaged, kind: "engagement", visitor, session: id, pageview: pv, path, hostname: host, title: "", name: "", props: null, engagedMs: engaged, scroll: 60, link: "" });
    }
    if (goal && v === views - 1 && t + 1500 < NOW) {
      await rl.store.insertEvent({ site, ts: t + 1500, kind: "event", visitor, session: id, pageview: pv, path, hostname: host, title: "", name: goal, props: null, engagedMs: 0, scroll: null, link: "" });
    }
    t += Math.max(engaged, 5000);
    if (t >= NOW) break;
  }
}

const today = midnight(NOW);
await rl.store.db.run("BEGIN");
for (const [i, site] of SITES.entries()) {
  const id = ids[i]!;
  for (let day = DAYS; day >= 0; day--) {
    const dayStart = midnight(today - day * DAY + 12 * HOUR);
    const weekday = new Date(dayStart + 12 * HOUR).getUTCDay();
    const scale = (weekday === 0 || weekday === 6 ? 0.72 : 1) * (day === 0 ? site.today : 0.9 + random() * 0.2);
    const count = Math.round(site.daily * scale);
    const seen: string[] = [];
    for (let n = 0; n < count; n++) {
      const start = dayStart + pick(HOURS) * HOUR + Math.floor(random() * HOUR);
      if (start >= NOW) continue;
      const converts = site.goal && random() < site.goal.rate ? site.goal.event : null;
      await visit(id, site.host, site.pages, start, pick(SOURCES), converts, seen);
    }
  }
  // Tulvane was on Hacker News this morning.
  if (i === 0) {
    for (let n = 0; n < 170; n++) {
      const start = today + 9 * HOUR + Math.floor(random() * 2.5 * HOUR);
      if (start < NOW) await visit(id, site.host, [["/blog/planning-a-quarter-without-spreadsheets", 1]], start, HN, null);
    }
  }
  // People reading right now.
  for (let n = 0; n < site.now; n++) await visit(id, site.host, site.pages, NOW - Math.floor(random() * 3 * MINUTE), pick(SOURCES), null);
}
await rl.store.db.run("COMMIT");
while (await rl.buildRollups()) { /* Catch up before reading. */ }

for (const [i, site] of SITES.entries()) {
  if (site.goal) await must("POST", `/api/goals?site=${ids[i]}`, { name: site.goal.name, kind: "event", match: site.goal.event, valueMode: "none" });
}
const read = (await must("POST", "/api/tokens", { name: "Mac app demo", site: "", scope: "read" })).secret as string;

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? "/", ORIGIN);
    // Icons come from scripts/demo/icons rather than the made-up hosts, which may not exist.
    if (url.pathname === "/api/icon") {
      const host = SITES[ids.indexOf(url.searchParams.get("site") ?? "")]?.host;
      const file = host ? join(ICONS, `${host}.png`) : "";
      if (!file || !existsSync(file)) {
        res.writeHead(404, { "content-type": "application/json" });
        return res.end(JSON.stringify({ error: "No icon", code: "icon_none" }));
      }
      res.writeHead(200, { "content-type": "image/png" });
      return res.end(readFileSync(file));
    }
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
    const headers = new Headers();
    for (const [key, value] of Object.entries(req.headers)) if (typeof value === "string") headers.set(key, value);
    const method = req.method ?? "GET";
    const response = await api.handler(new Request(url, { method, headers, body: method === "GET" || method === "HEAD" || !chunks.length ? undefined : Buffer.concat(chunks) }));
    res.writeHead(response.status, Object.fromEntries(response.headers));
    res.end(Buffer.from(await response.arrayBuffer()));
  } catch (error) {
    res.writeHead(500);
    res.end(String(error));
  }
});
server.listen(PORT, "127.0.0.1", () => {
  console.log(`Demo Runlight at ${ORIGIN} with ${SITES.length} made-up sites. Launch the debug app with:\n`);
  console.log(`  build/Build/Products/Debug/Runlight.app/Contents/MacOS/Runlight -DemoAddress ${ORIGIN} -DemoToken ${read} -OpenPopover YES -KeepPopoverOpen YES\n`);
  console.log("Stop with Ctrl-C.");
});
const stop = () => {
  server.close();
  rmSync(dir, { recursive: true, force: true });
  process.exit(0);
};
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
