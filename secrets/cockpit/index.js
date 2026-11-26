"use strict";
const $ = id => document.getElementById(id);
const MASK = "••••••••";
const CLEAR_MS = 15000;
const NAME_RE = /^[A-Z_][A-Z0-9_]{0,127}$/;
const VALUE_RE = /^[A-Za-z0-9_:/@.%+=,!?~&*;()[\]{}-]{1,16384}$/;
const TOKEN = "CLOUDFLARE_TUNNEL_TOKEN";

const hex = bytes => Array.from(crypto.getRandomValues(new Uint8Array(bytes)),
                                b => b.toString(16).padStart(2, "0")).join("");
// Client-side hints mirror backend.validate(); the backend remains authoritative.
const KNOWN = {
    BASE_URL: { hint: "Public AIOStreams URL, e.g. https://aio.dardery.work." },
    SECRET_KEY: { hint: "64 hexadecimal characters. Changing it can invalidate saved addon settings.",
                  check: v => /^[0-9a-fA-F]{64}$/.test(v) || "Must be 64 hexadecimal characters.",
                  generate: () => hex(32), confirm: "Changing SECRET_KEY can invalidate existing AIOStreams settings. Continue?" },
    AIOSTREAMS_AUTH: { hint: "username:password for the AIOStreams admin.",
                       check: v => /^[^:]+:.+$/.test(v) || "Use username:password.",
                       generate: () => "admin:" + hex(24) },
    AIOSTREAMS_AUTH_REQUIRED: { hint: "Must remain true.", check: v => v === "true" || "Authentication must stay enabled.",
                                generate: () => "true" },
    [TOKEN]: { hint: "Cloudflare connector token for the homelab tunnel. Not passed to AIOStreams.",
               check: v => /^[A-Za-z0-9_+/=-]+$/.test(v) || "Enter only the tunnel token.",
               confirm: "Changing the tunnel token can briefly disconnect remote access. Prefer a local Cockpit session. Continue?" },
};
const SYNC = [
    [/^Synced/, "ok", "Synced"], [/^Remote differs/, "warn", "Remote differs"],
    [/^Local only/, "info", "Local only"], [/^GitHub unavailable/, "warn", "GitHub offline"],
    [/^Remote file missing/, "warn", "Remote missing"],
];

let busy = false;
let variables = [];
const timers = new Map();

/* Follow Cockpit's light/dark preference. */
function applyTheme() {
    let style = "auto";
    try { style = localStorage.getItem("shell:style") || "auto"; } catch (_) {}
    const dark = style === "dark" || (style === "auto" && matchMedia("(prefers-color-scheme: dark)").matches);
    document.documentElement.dataset.theme = dark ? "dark" : "light";
}
applyTheme();
addEventListener("storage", e => { if (e.key === "shell:style") applyTheme(); });
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", applyTheme);

async function invoke(action, data) {
    const proc = cockpit.spawn(["/run/current-system/sw/bin/homeserver-secrets", action],
                               { superuser: "require", err: "message" });
    if (data !== undefined) proc.input(JSON.stringify(data));
    return await proc;
}
function errorText(ex) {
    const msg = (ex && (ex.message || ex.problem) || "").toString().trim();
    if (!msg || msg === "not-authorized" || msg === "access-denied")
        return "Administrative access is required. Turn on administrative access and retry.";
    return msg.split("\n").filter(Boolean).pop();
}
function setStatus(text, kind = "info") {
    const s = $("status");
    s.hidden = !text; s.textContent = text || ""; s.dataset.kind = kind;
}
let updateRunning = false;
function setBusy(on) {
    busy = on;
    document.body.classList.toggle("busy", on);
    for (const b of document.querySelectorAll("button, input, textarea"))
        if (!b.matches("[data-close], #filter")) b.disabled = on;
    if (updateRunning) $("update").disabled = true;
}
async function perform(fn, done) {
    if (busy) return false;
    setBusy(true); setStatus("Working…");
    try {
        await fn();
        setStatus(done || "", "ok");
        return true;
    } catch (ex) {
        setStatus(errorText(ex), "error");
        throw ex;
    } finally { setBusy(false); }
}
const quiet = p => p.catch(() => {});

function el(tag, props = {}, ...children) {
    const e = Object.assign(document.createElement(tag), props);
    e.append(...children);
    return e;
}
function button(text, onclick, cls) {
    return el("button", { type: "button", textContent: text, onclick, className: cls || "" });
}

function hide(name, cell, btn) {
    clearTimeout(timers.get(name)); timers.delete(name);
    cell.textContent = MASK; cell.classList.add("masked"); btn.textContent = "Reveal";
}
function render() {
    const q = $("filter").value.trim().toUpperCase();
    const rows = variables.filter(v => v.name.includes(q));
    for (const t of timers.values()) clearTimeout(t);
    timers.clear();
    $("rows").replaceChildren(...rows.map(v => {
        const value = el("td", { className: "value masked", textContent: v.configured ? MASK : "Not configured" });
        const nameCell = el("td", { className: "name" }, el("code", { textContent: v.name }));
        if (v.required) nameCell.append(" ", el("span", { className: "tag", textContent: "required" }));
        const scope = el("td", {}, el("span", { className: "chip " + v.scope,
                                                textContent: v.scope === "cloudflared" ? "Cloudflare tunnel" : "AIOStreams" }));
        const actions = el("td", { className: "actions" });
        if (v.configured) {
            const reveal = button("Reveal", () => {
                if (reveal.textContent === "Hide") return hide(v.name, value, reveal);
                quiet(perform(async () => {
                    value.textContent = JSON.parse(await invoke("reveal", { name: v.name })) ?? "Not configured";
                    value.classList.remove("masked"); reveal.textContent = "Hide";
                    timers.set(v.name, setTimeout(() => hide(v.name, value, reveal), CLEAR_MS));
                }));
            });
            actions.append(reveal, button("Copy", () => quiet(perform(async () => {
                const secret = JSON.parse(await invoke("reveal", { name: v.name }));
                await navigator.clipboard.writeText(secret);
                setTimeout(() => navigator.clipboard.writeText("").catch(() => {}), CLEAR_MS);
            }, `${v.name} copied. Clipboard clears in 15 seconds.`))));
        }
        actions.append(button(v.configured ? "Edit" : "Set", () => openEditor(v.name)));
        if (!v.required && v.configured) actions.append(button("Delete", () => remove(v.name), "danger"));
        return el("tr", {}, nameCell, scope, value, actions);
    }));
    if (!rows.length)
        $("rows").append(el("tr", {}, el("td", { colSpan: 4, className: "muted", textContent: "No matching variables." })));
}

async function loadVariables() {
    variables = JSON.parse(await invoke("list"));
    render();
}
async function loadSync() {
    const text = JSON.parse(await invoke("github-status"));
    $("git-status").textContent = text;
    const [, state, label] = SYNC.find(([re]) => re.test(text)) || [null, "unknown", "Unknown"];
    Object.assign($("sync-badge"), { textContent: label }).dataset.state = state;
    $("pull").hidden = state === "info";
    const list = $("history");
    if (state === "info") return list.replaceChildren(el("li", { className: "muted", textContent: "Connect GitHub to see history." }));
    try {
        const commits = JSON.parse(await invoke("history"));
        list.replaceChildren(...(commits.length ? commits.map(c => el("li", {},
            el("span", { className: "msg", textContent: c.message }),
            el("span", { className: "muted small",
                         textContent: ` ${c.sha} · ${c.author} · ${new Date(c.date).toLocaleString()}` })))
            : [el("li", { className: "muted", textContent: "No commits yet." })]));
    } catch (ex) {
        list.replaceChildren(el("li", { className: "muted", textContent: "History unavailable: " + errorText(ex) }));
    }
}
const load = () => Promise.all([loadVariables(), loadSync()]);

/* Editor dialog */
function openEditor(name) {
    const existing = !!name && variables.some(v => v.name === name && v.configured);
    $("edit-title").textContent = existing ? `Edit ${name}` : name ? `Set ${name}` : "Add variable";
    $("name").value = name || ""; $("name").readOnly = !!name;
    $("value").value = ""; $("value").type = "password";
    $("toggle-value").textContent = "Show"; $("toggle-value").setAttribute("aria-pressed", "false");
    $("edit-error").textContent = "";
    updateHint();
    $("edit-dialog").showModal();
    (name ? $("value") : $("name")).focus();
}
function updateHint() {
    const name = $("name").value.trim();
    const k = KNOWN[name];
    $("hint").textContent = k ? k.hint : name === TOKEN ? "" :
        "Passed to AIOStreams as an environment variable. Literal values only: no spaces, quotes, $ or backslashes.";
    $("generate").hidden = !!k && !k.generate;
}
function checkValue(name, value) {
    if (!NAME_RE.test(name)) return "Name must be uppercase letters, digits and underscores, not starting with a digit.";
    if (["GITHUB_TOKEN", "HOMESERVER_GITHUB_TOKEN"].includes(name)) return "This name is reserved.";
    if (!VALUE_RE.test(value)) return "Value must be non-empty, without spaces, quotes, $ or backslashes.";
    const k = KNOWN[name];
    const res = k && k.check ? k.check(value) : true;
    return res === true ? "" : res;
}
$("name").addEventListener("input", () => { $("name").value = $("name").value.toUpperCase(); updateHint(); });
$("toggle-value").onclick = () => {
    const show = $("value").type === "password";
    $("value").type = show ? "text" : "password";
    $("toggle-value").textContent = show ? "Hide" : "Show";
    $("toggle-value").setAttribute("aria-pressed", String(show));
};
$("generate").onclick = () => {
    const k = KNOWN[$("name").value.trim()];
    $("value").value = k && k.generate ? k.generate() : hex(32);
    $("value").type = "text"; $("toggle-value").textContent = "Hide";
};
$("editor").onsubmit = event => {
    event.preventDefault();
    const name = $("name").value.trim(), value = $("value").value;
    const problem = checkValue(name, value);
    if (problem) { $("edit-error").textContent = problem; return; }
    const k = KNOWN[name];
    if (k && k.confirm && !confirm(k.confirm)) return;
    $("edit-error").textContent = "";
    perform(async () => {
        await invoke("set", { name, value });
        $("value").value = "";
        $("edit-dialog").close();
        await load();
    }, `${name} saved and applied.`).catch(ex => { $("edit-error").textContent = errorText(ex); });
};

function remove(name) {
    const msg = name === TOKEN ? "Remove the tunnel token? Remote access via Cloudflare will stop."
                               : `Delete ${name}? AIOStreams will restart.`;
    if (confirm(msg)) quiet(perform(async () => { await invoke("delete", { name }); await load(); }, `${name} deleted.`));
}

/* Import dialog */
$("import").onclick = () => {
    $("import-text").value = ""; $("import-error").textContent = "";
    $("import-dialog").showModal(); $("import-text").focus();
};
$("importer").onsubmit = event => {
    event.preventDefault();
    const text = $("import-text").value;
    perform(async () => {
        await invoke("import", { text });
        $("import-text").value = "";
        $("import-dialog").close();
        await load();
    }, "Variables imported and applied.").catch(ex => { $("import-error").textContent = errorText(ex); });
};

for (const b of document.querySelectorAll("[data-close]"))
    b.onclick = () => { const d = b.closest("dialog"); d.querySelectorAll("input, textarea").forEach(i => { i.value = ""; }); d.close(); };
for (const d of document.querySelectorAll("dialog"))
    d.addEventListener("close", () => d.querySelectorAll("input[type=text], input[type=password], textarea").forEach(i => { i.value = ""; }));

/* Toolbar and GitHub */
$("filter").addEventListener("input", render);
$("add").onclick = () => openEditor();
$("refresh").onclick = () => quiet(perform(load, "Refreshed."));
$("apply").onclick = () => {
    if (confirm("Restart AIOStreams and the Cloudflare connector (if configured)?"))
        quiet(perform(async () => { await invoke("apply"); await load(); }, "Services restarted."));
};
$("export").onclick = () => quiet(perform(async () => {
    const blob = new Blob([await invoke("export")], { type: "application/json" });
    const a = el("a", { href: URL.createObjectURL(blob), download: "homeserver-runtime.enc" });
    document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}, "Encrypted backup downloaded. Keep age.key backed up separately — it is required to decrypt this file."));
$("github").onsubmit = event => {
    event.preventDefault();
    const token = $("github-token").value.trim();
    $("github-token").value = "";
    if (!/^github_pat_[A-Za-z0-9_]{20,255}$/.test(token))
        return setStatus("Provide a fine-grained token (starts with github_pat_).", "error");
    quiet(perform(async () => { await invoke("github-connect", { token }); await load(); }, "GitHub connected."));
};
$("pull").onclick = () => {
    if (confirm("Replace local secrets with the encrypted GitHub version and apply? Use local access if the tunnel token changes."))
        quiet(perform(async () => { await invoke("github-pull"); await load(); }, "Pulled from GitHub and applied."));
};

$("push").onclick = () => {
    if (confirm("Replace the encrypted secrets file on GitHub with this server's version? GitHub keeps the old one in its history."))
        quiet(perform(async () => {
            const msg = JSON.parse(await invoke("github-push"));
            await load();
            setStatus(msg, "ok");
        }));
};

/* Server update: runs as homeserver-update.service so it survives Cockpit
   and service restarts during the switch; this page only starts and watches it. */
const UNIT = "homeserver-update.service";
let updateTimer = null;
const root = args => cockpit.spawn(args, { superuser: "require", err: "message" });
async function unitState() {
    const out = await root(["systemctl", "show", UNIT, "-p", "ActiveState", "-p", "Result", "-p", "InvocationID"]);
    return Object.fromEntries(out.trim().split("\n").map(l => l.split("=", 2)));
}
async function pollUpdate() {
    clearTimeout(updateTimer);
    let s;
    try { s = await unitState(); } catch (ex) {
        // Cockpit may be restarting during the switch; keep trying.
        updateTimer = setTimeout(pollUpdate, 3000);
        return;
    }
    const running = s.ActiveState === "activating" || s.ActiveState === "active";
    if (s.InvocationID) {
        try {
            const log = await root(["journalctl", "-o", "cat", "--no-pager", "_SYSTEMD_INVOCATION_ID=" + s.InvocationID]);
            const pre = $("update-log");
            const atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;
            pre.hidden = false; pre.textContent = log || "Starting…";
            if (atEnd) pre.scrollTop = pre.scrollHeight;
        } catch (_) {}
    }
    const [label, state] = running ? ["Updating…", "info"]
        : !s.InvocationID ? ["Idle", "unknown"]
        : s.Result === "success" ? ["Last update succeeded", "ok"] : ["Last update failed", "error"];
    Object.assign($("update-badge"), { textContent: label }).dataset.state = state;
    if (updateRunning && !running) quiet(loadUpdateInfo());
    updateRunning = running;
    $("update").disabled = running || busy;
    if (running) updateTimer = setTimeout(pollUpdate, 2000);
}
async function loadUpdateInfo() {
    try {
        const s = JSON.parse(await invoke("update-status"));
        const versions = s.deployed ? ` Deployed ${s.deployed}, GitHub ${s.latest}.` : "";
        Object.assign($("update-info"), { textContent: s.message + versions,
                                          className: s.state === "behind" ? "" : "muted" });
        const list = $("update-commits");
        list.hidden = !s.commits.length;
        list.replaceChildren(...s.commits.map(c => el("li", {},
            el("span", { className: "msg", textContent: c.message }),
            el("span", { className: "muted small", textContent: " " + c.sha }))));
    } catch (ex) {
        $("update-info").textContent = "Update check unavailable: " + errorText(ex);
    }
}
$("check-update").onclick = () => quiet(perform(loadUpdateInfo));
$("update").onclick = () => {
    if (!confirm("Update the server from GitHub now? Services may restart. Do not use while printing."))
        return;
    quiet(perform(async () => {
        await root(["systemctl", "start", "--no-block", UNIT]);
    }, "Update started. Follow the log below."));
    setTimeout(pollUpdate, 1000);
};

quiet(perform(load));
quiet(pollUpdate());
quiet(loadUpdateInfo());
