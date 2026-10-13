import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const publicDir = path.resolve(here, "../public");
const dataDir = process.env.DATA_DIR || "/data";
const adminPath = path.join(dataDir, "admin.json");
const port = Number(process.env.PORT || 51821);
const host = process.env.HOST || "127.0.0.1";
const sessions = new Map();
const failures = new Map();
fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });

function json(res, status, value, headers = {}) {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers });
  res.end(JSON.stringify(value));
}
function readAdmin() { try { return JSON.parse(fs.readFileSync(adminPath, "utf8")); } catch { return null; } }
function hashPassword(password, salt = crypto.randomBytes(16).toString("hex")) { return { salt, hash: crypto.scryptSync(password, salt, 64).toString("hex") }; }
function validPassword(password, admin) {
  const calculated = Buffer.from(hashPassword(password, admin.salt).hash, "hex");
  const expected = Buffer.from(admin.hash, "hex");
  return calculated.length === expected.length && crypto.timingSafeEqual(calculated, expected);
}
function cookies(req) { return Object.fromEntries(String(req.headers.cookie || "").split(";").map(v => v.trim().split("=")).filter(v => v.length === 2)); }
function currentUser(req) { const item = sessions.get(cookies(req).npq_session); return item && item.expires >= Date.now() ? item.username : null; }
function sameOrigin(req) { const origin = req.headers.origin; if (!origin) return true; try { return new URL(origin).host === req.headers.host; } catch { return false; } }
async function body(req) {
  let text = "";
  for await (const chunk of req) { text += chunk; if (text.length > 16384) throw new Error("Request is too large."); }
  try { return JSON.parse(text || "{}"); } catch { throw new Error("Send a JSON body."); }
}
function npq(args) {
  const result = spawnSync("npq", ["--json", ...args], { encoding: "utf8", timeout: 20000 });
  let value = {};
  try { value = JSON.parse(result.stdout || "{}"); } catch { throw new Error(result.stderr || "npq returned an invalid response."); }
  if (result.status !== 0) throw new Error(value.error || result.stderr || "Could not update users.");
  return value;
}
function sessionCookie(token, maxAge = 43200) { return `npq_session=${token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${maxAge}`; }
function clientIp(req) { return String(req.socket.remoteAddress || "unknown"); }
function blocked(ip) {
  const item = failures.get(ip);
  if (!item || item.until < Date.now()) { failures.delete(ip); return false; }
  return true;
}
function recordFailure(ip) {
  const previous = failures.get(ip), count = previous && previous.until >= Date.now() ? previous.count + 1 : 1;
  failures.set(ip, { count, until: Date.now() + Math.min(300000, 1000 * 2 ** Math.min(count, 8)) });
}

async function api(req, res, url) {
  if (url.pathname === "/api/health" && req.method === "GET") return json(res, 200, { ok: true });
  if (url.pathname === "/api/session" && req.method === "GET") return json(res, 200, { needsSetup: !readAdmin(), user: currentUser(req) });
  if (["POST", "PATCH", "DELETE"].includes(req.method) && !sameOrigin(req)) return json(res, 403, { error: "Request origin was rejected." });
  if (url.pathname === "/api/setup" && req.method === "POST") {
    if (readAdmin()) return json(res, 409, { error: "An admin account already exists." });
    const input = await body(req), username = String(input.username || "").trim(), password = String(input.password || "");
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]{2,31}$/.test(username)) return json(res, 400, { error: "Use 3-32 safe characters for the username." });
    if (password.length < 10 || !/[A-Za-z]/.test(password) || !/[0-9]/.test(password)) return json(res, 400, { error: "Password needs 10 characters, a letter, and a number." });
    const passwordData = hashPassword(password);
    fs.writeFileSync(adminPath, JSON.stringify({ username, ...passwordData }), { mode: 0o600, flag: "wx" });
    const token = crypto.randomBytes(32).toString("hex"); sessions.set(token, { username, expires: Date.now() + 43200000 });
    return json(res, 201, { user: username }, { "set-cookie": sessionCookie(token) });
  }
  if (url.pathname === "/api/login" && req.method === "POST") {
    const ip = clientIp(req);
    if (blocked(ip)) return json(res, 429, { error: "Too many attempts. Wait before trying again." });
    const input = await body(req), admin = readAdmin();
    if (!admin || input.username !== admin.username || !validPassword(String(input.password || ""), admin)) { recordFailure(ip); return json(res, 401, { error: "Invalid username or password." }); }
    failures.delete(ip);
    const token = crypto.randomBytes(32).toString("hex"); sessions.set(token, { username: admin.username, expires: Date.now() + 43200000 });
    return json(res, 200, { user: admin.username }, { "set-cookie": sessionCookie(token) });
  }
  if (url.pathname === "/api/logout" && req.method === "POST") { sessions.delete(cookies(req).npq_session); return json(res, 200, { ok: true }, { "set-cookie": sessionCookie("", 0) }); }
  if (!currentUser(req)) return json(res, 401, { error: "Sign in to continue." });
  if (url.pathname === "/api/users" && req.method === "GET") return json(res, 200, npq(["user", "list"]));
  if (url.pathname === "/api/users" && req.method === "POST") { const input = await body(req); return json(res, 201, npq(["user", "add", "--name", String(input.name || "")])); }
  const match = url.pathname.match(/^\/api\/users\/(\d+)(?:\/(show|enable|disable|rotate))?$/);
  if (match) {
    const id = match[1], action = match[2];
    if (req.method === "GET" && action === "show") return json(res, 200, npq(["user", "show", "--id", id]));
    if (req.method === "POST" && ["enable", "disable", "rotate"].includes(action)) return json(res, 200, npq(["user", action, "--id", id]));
    if (req.method === "DELETE" && !action) return json(res, 200, npq(["user", "remove", "--id", id]));
  }
  return json(res, 404, { error: "Not found." });
}

const types = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8" };
function staticFile(res, pathname) {
  const requested = pathname === "/" ? "/index.html" : pathname, file = path.resolve(publicDir, `.${requested}`);
  if (!file.startsWith(`${publicDir}${path.sep}`)) return json(res, 404, { error: "Not found." });
  fs.readFile(file, (error, data) => {
    if (error) return json(res, 404, { error: "Not found." });
    res.writeHead(200, { "content-type": types[path.extname(file)] || "application/octet-stream", "x-content-type-options": "nosniff", "referrer-policy": "same-origin", "x-frame-options": "DENY", "content-security-policy": "default-src 'self'; style-src 'self'; script-src 'self'; img-src 'self' data:; frame-ancestors 'none'" });
    res.end(data);
  });
}
http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  try { if (url.pathname.startsWith("/api/")) await api(req, res, url); else staticFile(res, url.pathname); }
  catch (error) { json(res, /too large/i.test(error.message) ? 413 : 400, { error: String(error.message || "Unexpected error").slice(0, 240) }); }
}).listen(port, host, () => console.log(`NaiveProxy Quick panel listening on ${host}:${port}`));
