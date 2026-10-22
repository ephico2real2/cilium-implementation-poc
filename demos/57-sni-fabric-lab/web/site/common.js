// Shared by both pages: the API's address, retries with back-off, and safe DOM helpers.
"use strict";

// The API has its own hostname behind the same Envoy port the browser used for this page.
export const API = `https://api.fabric.localtest.me${location.port ? `:${location.port}` : ""}`;

const RETRYABLE_STATUS = new Set([429, 502, 503, 504]);

/**
 * fetch() with retries: exponential back-off with full jitter.
 * Retries network errors and 429/502/503/504. A non-idempotent request (POST) is retried only
 * when it carries an Idempotency-Key, so the server can recognise a repeat and not act twice.
 * Returns {response, attempts}; throws the last error once the attempts run out.
 */
export async function fetchWithRetry(url, options = {}, { attempts = 4, baseMs = 200, maxMs = 2000 } = {}) {
  const method = (options.method || "GET").toUpperCase();
  const headers = new Headers(options.headers || {});
  const retryable = ["GET", "HEAD", "PUT", "DELETE"].includes(method) || headers.has("Idempotency-Key");
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      const response = await fetch(url, { ...options, headers });
      if (!retryable || !RETRYABLE_STATUS.has(response.status) || attempt === attempts) {
        return { response, attempts: attempt };
      }
      lastError = new Error(`HTTP ${response.status}`);
    } catch (error) {
      lastError = error;
      if (!retryable || attempt === attempts) break;
    }
    const ceiling = Math.min(maxMs, baseMs * 2 ** (attempt - 1));
    await new Promise((resolve) => setTimeout(resolve, Math.random() * ceiling));
  }
  throw lastError;
}

/** Reads a JSON body, or throws an Error carrying the server's message and status. */
export async function jsonOrThrow(response) {
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(body.detail ? `${response.status}: ${JSON.stringify(body.detail)}` : `HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return body;
}

/** Creates an element with text content only; never parses HTML. */
export function el(tag, { text, className, attrs } = {}, children = []) {
  const node = document.createElement(tag);
  if (text !== undefined && text !== null) node.textContent = String(text);
  if (className) node.className = className;
  for (const [name, value] of Object.entries(attrs || {})) node.setAttribute(name, value);
  for (const child of children) node.append(child);
  return node;
}

export function chip(text, kind) {
  return el("span", { text, className: `chip ${kind}` });
}

export function setNotice(node, kind, text) {
  node.className = `notice ${kind}`;
  node.textContent = text || "";
}

export function formatTime(iso) {
  return iso ? new Date(iso).toLocaleTimeString() : "—";
}

export function showApiAddress() {
  const node = document.querySelector("[data-api]");
  if (node) node.textContent = API;
}
