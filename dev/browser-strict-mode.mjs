// Browser test: web strict mode + messages kept in memory only
//
// Start dev/run.sh server and dev/run.sh web first, then:
//   node dev/browser-strict-mode.mjs
//
// 1. Normal sign-in: no sync database, log database or drafts on the device
// 2. Strict sign-in: no login details or keys on the device
// 3. Closing the page: the device is signed out on the server; only the strict-mode switch and UI preferences stay
import { createRequire } from "node:module";

const require = createRequire(new URL("../forks/element-web/apps/web/package.json", import.meta.url));
const { chromium } = require("@playwright/test");

const HS = "http://localhost:8008";
const WEB = process.env.WEB ?? "http://localhost:8080";
const TOKEN_REG = "freechat-dev";
const user = `strict${Date.now() % 1000000}`;
const password = `pw-${user}-long-enough`;

let pass = 0;
let fail = 0;
function check(name, ok, detail = "") {
    if (ok) pass++;
    else fail++;
    console.log(`  ${ok ? "✅" : "❌"} ${name}${!ok && detail ? `  (${detail})` : ""}`);
}

async function api(method, path, token, body) {
    const res = await fetch(`${HS}/_matrix/client/v3${path}`, {
        method,
        headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
        body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, json: await res.json().catch(() => ({})) };
}

async function register() {
    const first = await api("POST", "/register", null, { username: user, password });
    const done = await api("POST", "/register", null, {
        username: user,
        password,
        auth: { type: "m.login.registration_token", token: TOKEN_REG, session: first.json.session },
    });
    if (!done.json.access_token) throw new Error(`register failed: ${JSON.stringify(done.json)}`);
    return done.json.access_token;
}

/** Device IDs of the user other than the one `token` belongs to. */
async function otherDevices(token) {
    const me = await api("GET", "/account/whoami", token);
    const { json } = await api("GET", "/devices", token);
    return (json.devices ?? []).map((d) => d.device_id).filter((id) => id !== me.json.device_id);
}

async function localState(page) {
    return page.evaluate(async () => {
        const dbs = (await indexedDB.databases?.()) ?? [];
        return { keys: Object.keys(localStorage), dbs: dbs.map((d) => d.name) };
    });
}

async function login(page) {
    await page.goto(`${WEB}/#/login`);
    await page.locator("#mx_LoginForm_username").fill(user);
    await page.locator("#mx_LoginForm_password").fill(password);
    await page.locator("#mx_LoginForm_password").press("Enter");
    // Logged in once the login form is gone and the app chrome shows up.
    await page.locator(".mx_LoginForm, #mx_LoginForm_username").first().waitFor({ state: "detached", timeout: 60_000 });
    await page.waitForTimeout(8_000); // let the first sync and crypto setup finish
}

const apiToken = await register();
const browser = await chromium.launch({ executablePath: process.env.CHROME || undefined });

console.log("1. Normal sign-in...");
{
    const context = await browser.newContext();
    const page = await context.newPage();
    await login(page);
    const { keys, dbs } = await localState(page);
    check("no riot-web-sync sync database", !dbs.includes("riot-web-sync"), dbs.join(","));
    check("no logs database", !dbs.includes("logs"), dbs.join(","));
    check("no drafts", !keys.some((k) => k.startsWith("mx_cider_state_") || k.startsWith("mx_wysiwyg_state_")));
    check("in normal mode the login is stored locally (control)", keys.includes("mx_access_token") || keys.includes("mx_has_access_token"), keys.join(","));
    await context.close();
}

console.log("2. Strict sign-in...");
const context = await browser.newContext();
let page = await context.newPage();
await page.goto(`${WEB}/#/login`);
await page.evaluate(() => localStorage.setItem("freechat_strict_mode", JSON.stringify({ enabled: true, idleMinutes: 5 })));
const before = await otherDevices(apiToken);
await login(page);
const after = await otherDevices(apiToken);
const browserDevice = after.find((id) => !before.includes(id));
check("signed in, and the server has a new device for this browser", !!browserDevice);
check("the device ID has the strict format (the server deletes it once idle)", /^FCS5_[0-9a-f]{16}$/.test(browserDevice ?? ""), browserDevice);
{
    const { keys, dbs } = await localState(page);
    check("no login details stored locally", !keys.some((k) => /access_token|refresh_token|mx_user_id|mx_device_id/.test(k)), keys.join(","));
    check("no key database stored locally", !dbs.some((n) => n.includes("crypto")), dbs.join(","));
    check("no sync or log database", !dbs.includes("riot-web-sync") && !dbs.includes("logs"), dbs.join(","));
}

console.log("3. Closing the page...");
await page.close({ runBeforeUnload: true });
await new Promise((r) => setTimeout(r, 3_000));
const remaining = await otherDevices(apiToken);
check("this browser's device is signed out on the server", !!browserDevice && !remaining.includes(browserDevice), remaining.join(","));

page = await context.newPage();
await page.goto(`${WEB}/#/login`);
await page.waitForTimeout(5_000);
{
    const { keys, dbs } = await localState(page);
    const extra = keys.filter((k) => !["freechat_strict_mode", "mx_local_settings"].includes(k));
    check("reopening needs a new sign-in", (await page.locator("#mx_LoginForm_username").count()) === 1);
    check("only the strict-mode switch and UI preferences remain locally", extra.length === 0, extra.join(","));
    check("the strict-mode switch is still there", keys.includes("freechat_strict_mode"));
    check("no key database locally", !dbs.some((n) => n.includes("crypto")), dbs.join(","));
}

await browser.close();
console.log(`\npassed ${pass}, failed ${fail}`);
process.exit(fail ? 1 : 0);
