// The Orders page: place orders, watch them move from created to processed, ping the TCP service.
import { API, chip, el, fetchWithRetry, formatTime, jsonOrThrow, setNotice, showApiAddress } from "/common.js";

const REFRESH_MS = 2000;

async function placeOrder(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const button = form.querySelector("button");
  const notice = document.getElementById("order-notice");
  const payload = { item: form.item.value, quantity: Number(form.quantity.value) };
  // One key per order, reused on every retry: the API stores it, so a retried POST cannot
  // create a second order.
  const key = crypto.randomUUID();
  button.disabled = true;
  try {
    const { response, attempts } = await fetchWithRetry(`${API}/orders`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Idempotency-Key": key },
      body: JSON.stringify(payload),
    });
    const order = await jsonOrThrow(response);
    const replay = response.headers.get("Idempotent-Replayed") === "true" ? ", replayed" : "";
    setNotice(notice, "ok", `Order #${order.id} created (${attempts} attempt${attempts > 1 ? "s" : ""}${replay}).`);
    await refreshOrders();
  } catch (error) {
    setNotice(notice, "bad", `Order failed: ${error.message}`);
  } finally {
    button.disabled = false;
  }
}

async function refreshOrders() {
  const notice = document.getElementById("list-notice");
  try {
    const { response } = await fetchWithRetry(`${API}/orders?limit=20`, {}, { attempts: 2 });
    const orders = await jsonOrThrow(response);
    const rows = orders.map((o) => el("tr", {}, [
      el("td", { text: o.id, className: "mono" }),
      el("td", { text: o.item }),
      el("td", { text: o.quantity }),
      el("td", {}, [chip(o.status, o.status)]),
      el("td", { text: formatTime(o.created_at) }),
      el("td", { text: formatTime(o.processed_at) }),
    ]));
    document.getElementById("orders").replaceChildren(...rows);
    setNotice(notice, "", orders.length ? "" : "No orders yet.");
  } catch (error) {
    setNotice(notice, "bad", `Cannot reach the API at ${API}: ${error.message}`);
  }
}

async function ping() {
  const notice = document.getElementById("ping-notice");
  const button = document.getElementById("ping");
  button.disabled = true;
  try {
    const { response } = await fetchWithRetry(`${API}/tcp/ping`);
    const result = await jsonOrThrow(response);
    setNotice(notice, "ok", `${result.reply} in ${result.latency_ms} ms`);
  } catch (error) {
    setNotice(notice, "bad", `Ping failed: ${error.message}`);
  } finally {
    button.disabled = false;
  }
}

showApiAddress();
document.getElementById("order-form").addEventListener("submit", placeOrder);
document.getElementById("ping").addEventListener("click", ping);
refreshOrders();
setInterval(refreshOrders, REFRESH_MS);
