// Browser test: the Content Security Policy (CSP) Caddy sends does not break the web client
//
// Start dev/run.sh server and dev/run.sh web first, then:
//   node dev/browser-csp.mjs
//
// The script runs its own proxy on http://localhost:8443 that, like Caddy in a real install, serves the web client and /_matrix
// from one origin and adds the CSP from deploy/install.sh to every response; the web config is the element.json install.sh writes.
// It then signs in, sends text, an image and a file (in a plain and an encrypted room), shows avatars, opens the call lobby,
// turns on background blur, joins the call and signs out. Any CSP violation in any page or frame, or any request to another site, fails it.
//
// The local dev environment has no LiveKit, so calls are only tested up to the call UI; real audio and video need an installed server.
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import http from "node:http";
import net from "node:net";

const require = createRequire(new URL("../forks/element-web/apps/web/package.json", import.meta.url));
const { chromium } = require("@playwright/test");

const HS = "http://localhost:8008";
const DEV_WEB = { host: "localhost", port: 8080 };
const PORT = 8443;
const ORIGIN = `http://localhost:${PORT}`;
const TOKEN_REG = "freechat-dev";
const user = `csp${Date.now() % 1000000}`;
const password = `pw-${user}-long-enough`;

const installer = readFileSync(new URL("../deploy/install.sh", import.meta.url), "utf8");
const DOMAIN = `localhost:${PORT}`;
const csp = installer
    .match(/Content-Security-Policy "([^"]*default-src[^"]*)"/)[1]
    .replaceAll("$DOMAIN", DOMAIN);
const elementConfig = JSON.parse(
    installer
        .match(/cat > "\$DIR\/config\/element.json" <<EOF\n([\s\S]*?)\nEOF/)[1]
        .replaceAll("$DOMAIN", "localhost")
        .replaceAll("$BRAND", "FreeChat"),
);
elementConfig.default_server_config["m.homeserver"].base_url = ORIGIN;
elementConfig.setting_defaults.language = "en"; // English UI, so buttons can be found by their text

let pass = 0;
let fail = 0;
function check(name, ok, detail = "") {
    if (ok) pass++;
    else fail++;
    console.log(`  ${ok ? "✅" : "❌"} ${name}${!ok && detail ? `  (${detail})` : ""}`);
}

// ---- Same-origin proxy (stands in for Caddy) ----

// The dev config's server address is http://localhost:8008 (well_known in dev/tuwunel.toml), and the login response makes the client switch to it.
// In a real install that address is the site itself, so it is replaced by the proxy's; otherwise the CSP would block it and the test would not match a real install.
const REWRITE = /^\/(_matrix\/client\/v3\/login|\.well-known\/matrix\/client)(\?|$)/;

function forward(req, res, target) {
    const rewrite = REWRITE.test(req.url);
    const headers = { ...req.headers, host: `${target.host}:${target.port}` };
    if (rewrite) delete headers["accept-encoding"];
    const up = http.request({ ...target, path: req.url, method: req.method, headers }, (r) => {
        if (!rewrite) {
            res.writeHead(r.statusCode, { ...r.headers, "content-security-policy": csp });
            r.pipe(res);
            return;
        }
        const chunks = [];
        r.on("data", (c) => chunks.push(c));
        r.on("end", () => {
            const body = Buffer.concat(chunks).toString().replaceAll(HS, ORIGIN);
            const { "content-length": _, ...rest } = r.headers;
            res.writeHead(r.statusCode, { ...rest, "content-security-policy": csp });
            res.end(body);
        });
    });
    up.on("error", () => res.writeHead(502).end());
    req.pipe(up);
}

const proxy = http.createServer((req, res) => {
    if (req.url.split("?")[0] === "/config.json") {
        res.writeHead(200, { "content-type": "application/json", "content-security-policy": csp });
        res.end(JSON.stringify(elementConfig));
    } else if (req.url.startsWith("/_matrix/") || req.url.startsWith("/.well-known/matrix/")) {
        forward(req, res, { host: "localhost", port: 8008 });
    } else {
        forward(req, res, DEV_WEB);
    }
});
// The webpack dev server's hot-reload connection
proxy.on("upgrade", (req, socket, head) => {
    const up = net.connect(DEV_WEB.port, DEV_WEB.host, () => {
        up.write(`${req.method} ${req.url} HTTP/1.1\r\n`);
        for (let i = 0; i < req.rawHeaders.length; i += 2) up.write(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`);
        up.write("\r\n");
        up.write(head);
        up.pipe(socket).pipe(up);
    });
    up.on("error", () => socket.destroy());
    socket.on("error", () => up.destroy());
});
await new Promise((r) => proxy.listen(PORT, "localhost", r));

// ---- Account, rooms and avatars (through the API) ----

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

// A plain 64×64 PNG
const PNG = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkAAAgEsEtiTiMaywi+hcEKLNXzWgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQELgt9cOE8/JmApAAAAABJRU5ErkJggg==",
    "base64",
);

async function uploadAvatar(token) {
    const res = await fetch(`${HS}/_matrix/media/v3/upload?filename=avatar.png`, {
        method: "POST",
        headers: { "Content-Type": "image/png", Authorization: `Bearer ${token}` },
        body: PNG,
    });
    return (await res.json()).content_uri;
}

const token = await register();
const avatar = await uploadAvatar(token);
await api("PUT", `/profile/@${user}:localhost/avatar_url`, token, { avatar_url: avatar });
const rooms = {};
for (const [name, encrypted] of [
    ["plain", false],
    ["encrypted", true],
]) {
    const initial_state = [{ type: "m.room.avatar", state_key: "", content: { url: avatar } }];
    if (encrypted) initial_state.push({ type: "m.room.encryption", state_key: "", content: { algorithm: "m.megolm.v1.aes-sha2" } });
    const { json } = await api("POST", "/createRoom", token, { name: `CSP ${name}`, preset: "private_chat", initial_state });
    if (!json.room_id) throw new Error(`createRoom failed: ${JSON.stringify(json)}`);
    rooms[name] = json.room_id;
}

// ---- Browser ----

const browser = await chromium.launch({
    executablePath: process.env.CHROME || undefined,
    args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream"],
});
const context = await browser.newContext({ permissions: ["camera", "microphone"] });
// Every page and frame (the call iframe included) logs CSP violations to the console
await context.addInitScript(() => {
    document.addEventListener("securitypolicyviolation", (e) => {
        const from = e.originalPolicy.includes("frame-ancestors") ? "header" : "meta";
        console.error(`CSP-VIOLATION [${from}] ${e.effectiveDirective} ${e.blockedURI || "(inline)"} @ ${location.pathname}`);
    });
});
const page = await context.newPage();
const violations = [];
const seen = new Set();
page.on("console", (msg) => {
    const text = msg.text();
    // Addresses that only exist in the dev setup and are the site itself in a real install: the webpack hot reload talks to 8080 directly;
    // the dev server name is localhost, so after sign-in the client looks up https://localhost/.well-known, which is the site itself in a real install
    if (text.includes("ws://localhost:8080/ws") || text.includes("https://localhost/.well-known/")) return;
    if (text.startsWith("CSP-VIOLATION") || text.includes("Content Security Policy")) {
        // The browser reports each violation twice (event and console), so they are deduplicated by text
        const key = text.replace(/^CSP-VIOLATION \[\w+\] /, "");
        if (!seen.has(key)) {
            seen.add(key);
            violations.push(text);
        }
    }
});
// Requests the CSP blocks are never sent; as a second safety net, any request to another site counts as a violation too
context.on("request", (req) => {
    const url = req.url();
    if (/^(data|blob):/.test(url) || url.startsWith(ORIGIN) || url.startsWith("ws://localhost:8080/")) return;
    if (url.startsWith("https://localhost/.well-known/")) return; // see above
    violations.push(`EXTERNAL-REQUEST ${url}`);
});
let stepStart = 0;
function stepViolations() {
    const v = violations.slice(stepStart);
    stepStart = violations.length;
    return v;
}
async function step(name, fn) {
    try {
        await fn();
        const v = stepViolations();
        check(name, v.length === 0, v.join("; "));
    } catch (e) {
        if (process.env.SHOT_DIR) await page.screenshot({ path: `${process.env.SHOT_DIR}/${pass + fail + 1}.png` });
        check(name, false, [String(e).split("\n")[0], ...stepViolations()].join("; "));
    }
}

async function dismissDialogs() {
    const toast = page.getByRole("button", { name: "Dismiss" });
    if (await toast.count()) await toast.first().click();
    for (let i = 0; i < 3; i++) {
        if (!(await page.locator(".mx_Dialog").count())) return;
        await page.keyboard.press("Escape");
        await page.waitForTimeout(500);
    }
}

async function openRoom(roomId) {
    await page.goto(`${ORIGIN}/#/room/${roomId}`);
    await page.locator(".mx_BasicMessageComposer_input").waitFor({ timeout: 30_000 });
    await dismissDialogs();
}

async function sendText(text) {
    await page.locator(".mx_BasicMessageComposer_input").click();
    await page.keyboard.type(text);
    await page.keyboard.press("Enter");
    await page.locator(".mx_EventTile_body", { hasText: text }).last().waitFor({ timeout: 20_000 });
}

async function sendFile(name, mimeType, buffer) {
    const tiles = page.locator(".mx_EventTile");
    const before = await tiles.count();
    await page.locator("[data-testid=room-upload-context-input]").setInputFiles({ name, mimeType, buffer });
    await page.locator(".mx_UploadConfirmDialog .mx_Dialog_primary").click();
    await page.waitForFunction((n) => document.querySelectorAll(".mx_EventTile").length > n, before, { timeout: 30_000 });
    await page.getByText(/Uploading|Sending/).waitFor({ state: "detached", timeout: 30_000 }).catch(() => {});
}

console.log(`CSP: ${csp}\n`);

await step("sign in", async () => {
    await page.goto(`${ORIGIN}/#/login`);
    await page.locator("#mx_LoginForm_username").fill(user);
    await page.locator("#mx_LoginForm_password").fill(password);
    await page.locator("#mx_LoginForm_password").press("Enter");
    await page.locator(".mx_LoginForm, #mx_LoginForm_username").first().waitFor({ state: "detached", timeout: 60_000 });
    await page.waitForTimeout(8_000);
    await dismissDialogs();
});

for (const [name, roomId] of Object.entries(rooms)) {
    await step(`${name}: open the room, show avatars`, async () => {
        await openRoom(roomId);
        await page.locator(".mx_RoomHeader .mx_BaseAvatar img, .mx_RoomHeader img").first().waitFor({ timeout: 20_000 });
    });
    await step(`${name}: send text`, () => sendText(`hello ${name}`));
    await step(`${name}: send an image`, async () => {
        await sendFile("pic.png", "image/png", PNG);
        await page.waitForTimeout(2_000); // thumbnails, decrypted blob images
    });
    await step(`${name}: send a file`, () =>
        sendFile("note.txt", "text/plain", Buffer.from("csp test file\n")),
    );
}

const frame = page.frameLocator('iframe[src*="widgets/element-call"]');

await step("open the call lobby (Element Call)", async () => {
    await openRoom(rooms.plain);
    await page.locator('[aria-label="Video call"], [aria-label="Start a video call"]').first().click();
    const startNew = page.getByRole("menuitem", { name: /Element Call|Video call/ });
    if (await startNew.count()) await startNew.first().click();
    // The lobby showing up means the page's scripts ran, both inline scripts included
    await frame.getByRole("button", { name: "Join call" }).waitFor({ timeout: 30_000 });
});

// Background blur uses the model and wasm bundled with Element Call (served by the site); it overrides the library's Google and jsdelivr defaults
await step("turn on background blur (model loaded from the site)", async () => {
    const loaded = (part) =>
        page.waitForResponse((r) => r.url().startsWith(ORIGIN) && r.url().includes(part) && r.ok(), { timeout: 30_000 });
    const model = loaded("selfie_segmenter");
    const wasm = loaded("vision_wasm_internal");
    await frame.getByRole("button", { name: "Camera" }).click();
    await frame.getByText("Blur background").click();
    await Promise.all([model, wasm]);
    await page.waitForTimeout(5_000); // let the blur run for a few frames
    if (process.env.SHOT) await page.screenshot({ path: process.env.SHOT.replace(/(\.png)?$/, "-blur.png") });
    await page.keyboard.press("Escape");
});

await step("join the call", async () => {
    await frame.getByRole("button", { name: "Join call" }).click();
    // The local dev environment has no LiveKit, so joining fails, but the authorization request and signalling steps still run
    await page.waitForTimeout(15_000);
    if (process.env.SHOT) await page.screenshot({ path: process.env.SHOT });
});

await step("sign out", async () => {
    await page.goto(`${ORIGIN}/#/home`);
    await dismissDialogs();
    // The user menu no longer has "Sign out", so dispatch Element's own logout action (as the settings button does)
    await page.evaluate(() => window.mxDispatcher.dispatch({ action: "logout" }));
    await page.locator("#mx_LoginForm_username, .mx_Welcome, .mx_AuthPage").first().waitFor({ timeout: 30_000 });
});

await browser.close();
proxy.close();
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
