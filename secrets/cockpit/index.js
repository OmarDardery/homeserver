"use strict";
const $ = id => document.getElementById(id);
const required = new Set(["BASE_URL", "SECRET_KEY", "AIOSTREAMS_AUTH", "AIOSTREAMS_AUTH_REQUIRED"]);
let busy = false;
async function invoke(action, data) {
    const process = cockpit.spawn(["/run/current-system/sw/bin/homeserver-secrets", action],
                                  {superuser: "require", err: "message"});
    if (data !== undefined) process.input(JSON.stringify(data));
    return await process;
}
function button(text, fn) {
    const b = document.createElement("button");
    b.type = "button"; b.textContent = text; b.onclick = fn; return b;
}
async function load() {
    $("git-status").textContent = JSON.parse(await invoke("github-status"));
    const names = JSON.parse(await invoke("list"));
    $("rows").replaceChildren();
    for (const name of names) {
        const row = document.createElement("tr");
        const key = document.createElement("td"); key.textContent = name;
        const value = document.createElement("td"); value.textContent = "••••••••";
        const actions = document.createElement("td");
        const reveal = button("Reveal", () => perform(async () => {
            if (reveal.textContent === "Hide") {
                value.textContent = "••••••••"; reveal.textContent = "Reveal"; return;
            }
            value.textContent = JSON.parse(await invoke("reveal", {name})) ?? "Not configured";
            reveal.textContent = "Hide";
            setTimeout(() => { value.textContent = "••••••••"; reveal.textContent = "Reveal"; }, 15000);
        }));
        actions.append(reveal, button("Edit", () => {
            $("name").value = name; $("value").value = ""; $("value").focus();
        }));
        if (!required.has(name)) actions.append(button("Delete", () => {
            if (confirm(name === "CLOUDFLARE_TUNNEL_TOKEN" ?
                "Disconnect the tunnel? Remote Cockpit access may be interrupted." : "Delete this variable?"))
                perform(async () => { await invoke("delete", {name}); await load(); });
        }));
        row.append(key, value, actions); $("rows").append(row);
    }
}
async function perform(fn) {
    if (busy) return;
    busy = true; $("status").textContent = "Working…";
    try { await fn(); $("status").textContent = "Ready."; }
    catch (_) { $("status").textContent = "Operation failed or apply incomplete. Refresh GitHub status; check token permissions, administrative access and Services. If saved remotely, pull before retrying."; }
    finally { busy = false; }
}
$("editor").onsubmit = event => {
    event.preventDefault();
    const name = $("name").value, value = $("value").value;
    if (name === "SECRET_KEY" && !confirm("Changing this key can invalidate existing AIOStreams settings. Continue?")) return;
    if (name === "CLOUDFLARE_TUNNEL_TOKEN" && !confirm("Changing the tunnel token can briefly disconnect remote access. Continue?")) return;
    $("value").value = "";
    perform(async () => { await invoke("set", {name, value}); await load(); });
};
$("refresh").onclick = () => $("github").onsubmit = event => {
    event.preventDefault();
    const token = $("github-token").value;
    $("github-token").value = "";
    perform(async () => { await invoke("github-connect", {token}); await load(); });
};
$("pull").onclick = () => {
    if (confirm("Replace local secrets with the encrypted GitHub version and apply? Use local access if changing the tunnel."))
        perform(async () => { await invoke("github-pull"); await load(); });
};
perform(load);
$("apply").onclick = () => {
    if (confirm("Restart AIOStreams and the Cloudflare connector (if configured)?"))
        perform(async () => { await invoke("apply"); await load(); });
};
perform(load);
