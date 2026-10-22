// The Admin portal: health, fabric metrics, MQ, chaos, and every order, behind a bearer token.
import { API, chip, el, fetchWithRetry, formatTime, jsonOrThrow, setNotice, showApiAddress } from "/common.js";

const REFRESH_MS = 3000;
const TOKEN_KEY = "fabric-admin-token";
const port = location.port ? `:${location.port}` : "";
const LINKS = [
  ["Swagger UI", `${API}/docs`],
  ["OpenAPI document", `${API}/openapi.json`],
  ["MQ web console", `https://mqconsole.fabric.localtest.me${port}/ibmmq/console`],
  ["Grafana", "http://grafana.fabric.localtest.me:8080"],
  ["Prometheus", "http://prometheus.fabric.localtest.me:8080"],
];

let timer = null;

function token() {
  return sessionStorage.getItem(TOKEN_KEY);
}

async function admin(path, options = {}) {
  const headers = { ...(options.headers || {}), Authorization: `Bearer ${token()}` };
  const { response } = await fetchWithRetry(`${API}${path}`, { ...options, headers }, { attempts: 2 });
  if (response.status === 401) {
    lock("The token was refused.");
    throw new Error("unauthorised");
  }
  return jsonOrThrow(response);
}

function lock(message) {
  sessionStorage.removeItem(TOKEN_KEY);
  clearInterval(timer);
  document.getElementById("portal").hidden = true;
  document.getElementById("gate").hidden = false;
  setNotice(document.getElementById("gate-notice"), message ? "bad" : "", message || "");
}

function unlock() {
  document.getElementById("gate").hidden = true;
  document.getElementById("portal").hidden = false;
  refresh();
  timer = setInterval(refresh, REFRESH_MS);
}

function kv(target, pairs) {
  const nodes = [];
  for (const [key, value] of pairs) nodes.push(el("dt", { text: key }), el("dd", { text: value }));
  target.replaceChildren(...nodes);
}

// ok is true or false for a checked component, null for one that is not configured.
function healthChip(ok) {
  if (ok === null) return chip("not set", "idle");
  return ok ? chip("up", "ok") : chip("down", "bad");
}

function renderOverview(o) {
  document.getElementById("health").replaceChildren(...o.health.map((h) => el("li", {}, [
    el("span", {}, [healthChip(h.ok), document.createTextNode(` ${h.name}`)]),
    el("span", { text: h.detail, className: "detail" }),
  ])));

  const f = o.fabric;
  kv(document.getElementById("fabric"), f.error ? [["error", f.error]] : [
    ...f.tenants.map((t) => [`${t.name} connections`, t.connections]),
    ["unknown or no SNI", f.rejected],
    ...f.retries.map((r) => [`${r.cluster} retries`, `${r.retries} (${r.retry_success} succeeded)`]),
  ]);

  const m = o.mq;
  kv(document.getElementById("mq"), m.error ? [["error", m.error]] : [
    ["DEV.QUEUE.1 waiting", m.queue_waiting],
    ["dead-letter waiting", m.dead_letter_waiting],
    ["queue manager puts", m.puts],
    ["queue manager gets", m.gets],
    ["worker's last event", m.worker_last_event ? formatTime(m.worker_last_event) : "—"],
  ]);

  kv(document.getElementById("order-counts"), Object.entries(o.orders.by_status));

  const form = document.getElementById("chaos-form");
  if (document.activeElement?.form !== form) {
    form.fail_rate.value = Math.round(o.chaos.fail_rate * 100);
    form.delay_ms.value = o.chaos.delay_ms;
    document.getElementById("fail-out").textContent = `${form.fail_rate.value} %`;
  }
}

async function republish(id, button) {
  button.disabled = true;
  try {
    await admin(`/admin/orders/${id}/republish`, { method: "POST" });
    setNotice(document.getElementById("portal-notice"), "ok", `Order #${id}: event sent again.`);
  } catch (error) {
    setNotice(document.getElementById("portal-notice"), "bad", `Republish failed: ${error.message}`);
  } finally {
    button.disabled = false;
  }
}

function renderOrders(orders) {
  document.getElementById("admin-orders").replaceChildren(...orders.map((o) => {
    const action = el("td");
    if (o.status === "created") {
      const button = el("button", { text: "Send event again", className: "ghost", attrs: { type: "button" } });
      button.addEventListener("click", () => republish(o.id, button));
      action.append(button);
    }
    return el("tr", {}, [
      el("td", { text: o.id, className: "mono" }),
      el("td", { text: o.item }),
      el("td", { text: o.quantity }),
      el("td", {}, [chip(o.status, o.status)]),
      el("td", { text: formatTime(o.created_at) }),
      el("td", { text: formatTime(o.processed_at) }),
      el("td", { text: o.events_sent }),
      action,
    ]);
  }));
}

async function refresh() {
  const notice = document.getElementById("portal-notice");
  try {
    const status = document.getElementById("filter-form").status.value;
    const query = status ? `?status=${encodeURIComponent(status)}&limit=50` : "?limit=50";
    const [overview, orders] = await Promise.all([admin("/admin/overview"), admin(`/admin/orders${query}`)]);
    renderOverview(overview);
    renderOrders(orders);
    if (notice.classList.contains("bad")) setNotice(notice, "", "");
  } catch (error) {
    if (error.message !== "unauthorised") setNotice(notice, "bad", `Cannot reach the API at ${API}: ${error.message}`);
  }
}

async function applyChaos(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const notice = document.getElementById("chaos-notice");
  try {
    const chaos = await admin("/admin/chaos", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ fail_rate: Number(form.fail_rate.value) / 100, delay_ms: Number(form.delay_ms.value) }),
    });
    setNotice(notice, "ok", `Now failing ${Math.round(chaos.fail_rate * 100)} % with ${chaos.delay_ms} ms added.`);
  } catch (error) {
    setNotice(notice, "bad", `Chaos not applied: ${error.message}`);
  }
}

showApiAddress();
document.getElementById("links").replaceChildren(
  ...LINKS.map(([text, href]) => el("a", { text, attrs: { href, target: "_blank", rel: "noopener" } })),
);
document.getElementById("gate-form").addEventListener("submit", (event) => {
  event.preventDefault();
  sessionStorage.setItem(TOKEN_KEY, event.currentTarget.token.value.trim());
  event.currentTarget.reset();
  unlock();
});
document.getElementById("chaos-form").addEventListener("submit", applyChaos);
document.getElementById("chaos-form").fail_rate.addEventListener("input", (event) => {
  document.getElementById("fail-out").textContent = `${event.currentTarget.value} %`;
});
document.getElementById("filter-form").addEventListener("change", refresh);
if (token()) unlock();
else lock();
