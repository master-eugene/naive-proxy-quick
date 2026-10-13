const $ = (selector) => document.querySelector(selector);
const loading = $("#loading"), auth = $("#auth"), app = $("#app"), users = $("#users");
let setup = false;
async function request(path, options = {}) {
  const response = await fetch(path, { credentials: "same-origin", headers: { accept: "application/json", ...(options.body ? { "content-type": "application/json" } : {}) }, ...options });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || "Request failed.");
  return data;
}
function showError(node, message = "") { node.textContent = message; node.hidden = !message; }
function smallButton(text, action, danger = false) { const el = document.createElement("button"); el.type = "button"; el.textContent = text; el.className = danger ? "small danger" : "small"; el.onclick = action; return el; }
async function loadUsers() {
  const data = await request("/api/users"); $("#server").textContent = `${data.server.domain}:${data.server.port}`; users.replaceChildren();
  for (const user of data.users) {
    const row = document.createElement("li"), info = document.createElement("div"), actions = document.createElement("div"), name = document.createElement("strong"), state = document.createElement("span");
    name.textContent = user.name; state.textContent = user.enabled ? "Enabled" : "Disabled"; state.className = user.enabled ? "on" : "off"; info.append(name, state); actions.className = "actions";
    actions.append(smallButton("Link", () => reveal(user)), smallButton(user.enabled ? "Disable" : "Enable", () => change(user.id, user.enabled ? "disable" : "enable")), smallButton("Rotate", () => change(user.id, "rotate", true)), smallButton("Remove", () => removeUser(user), true)); row.append(info, actions); users.append(row);
  }
}
function showLink(title, link) { $("#secret-title").textContent = title; $("#link").textContent = link; $("#secret").hidden = false; }
async function reveal(user) { try { const data = await request(`/api/users/${user.id}/show`); showLink(`${user.name} connection link`, data.user.link); } catch (e) { showError($("#error"), e.message); } }
async function change(id, action, revealAfter = false) { try { const data = await request(`/api/users/${id}/${action}`, { method: "POST" }); await loadUsers(); if (revealAfter) showLink("New connection link", data.user.link); } catch (e) { showError($("#error"), e.message); } }
async function removeUser(user) { if (!confirm(`Remove ${user.name}?`)) return; try { await request(`/api/users/${user.id}`, { method: "DELETE" }); await loadUsers(); } catch (e) { showError($("#error"), e.message); } }
auth.onsubmit = async (event) => { event.preventDefault(); showError($("#auth-error")); try { await request(setup ? "/api/setup" : "/api/login", { method: "POST", body: JSON.stringify({ username: $("#username").value.trim(), password: $("#password").value }) }); auth.hidden = true; app.hidden = false; await loadUsers(); } catch (e) { showError($("#auth-error"), e.message); } };
$("#add").onsubmit = async (event) => { event.preventDefault(); showError($("#error")); try { const data = await request("/api/users", { method: "POST", body: JSON.stringify({ name: $("#new-name").value.trim() }) }); $("#new-name").value = ""; await loadUsers(); showLink(`${data.user.name} connection link`, data.user.link); } catch (e) { showError($("#error"), e.message); } };
$("#logout").onclick = async () => { await request("/api/logout", { method: "POST" }); location.reload(); };
$("#close-secret").onclick = () => { $("#secret").hidden = true; $("#link").textContent = ""; };
$("#copy").onclick = async () => { await navigator.clipboard.writeText($("#link").textContent); $("#copy").textContent = "Copied"; setTimeout(() => $("#copy").textContent = "Copy link", 1200); };
request("/api/session").then(async data => { loading.hidden = true; if (data.user) { app.hidden = false; await loadUsers(); } else { setup = data.needsSetup; $("#auth-step").textContent = setup ? "First run" : "Sign in"; $("#auth-title").textContent = setup ? "Create admin" : "Welcome back"; auth.hidden = false; } }).catch(e => { loading.textContent = e.message; });
