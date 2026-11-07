// The app's service worker: a phone with no signal still opens the dashboard's shell. Its data
// is never cached, so a figure on screen is never older than the page says. Hashed bundles under
// /static/ never change, so they are served from the cache once seen; a page comes from the
// network, falling back to the last copy, and every API call goes straight to the server.
const CACHE = "parallax-v1";
const SHELL = "/";
const API = /^\/(function|walker|user|sso|healthz|admin|docs|cl)(\/|$)/;

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      .then((cache) => cache.add(SHELL))
      .catch(() => undefined)
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((names) => Promise.all(names.filter((name) => name !== CACHE).map((name) => caches.delete(name))))
      .then(() => self.clients.claim()),
  );
});

async function page(request) {
  const cache = await caches.open(CACHE);
  try {
    const fresh = await fetch(request);
    if (fresh.ok) {
      await cache.put(SHELL, fresh.clone());
    }
    return fresh;
  } catch {
    const shell = await cache.match(SHELL);
    if (shell) {
      return shell;
    }
    throw new Error("offline, and the app has not been opened online yet");
  }
}

async function bundle(request) {
  const cache = await caches.open(CACHE);
  const seen = await cache.match(request);
  if (seen) {
    return seen;
  }
  const fresh = await fetch(request);
  if (fresh.ok) {
    await cache.put(request, fresh.clone());
  }
  return fresh;
}

self.addEventListener("fetch", (event) => {
  const { request } = event;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin || API.test(url.pathname)) {
    return;
  }
  if (request.mode === "navigate") {
    event.respondWith(page(request));
  } else if (url.pathname.startsWith("/static/")) {
    event.respondWith(bundle(request));
  }
});
