/*
 * Saci PWA service worker template (vendored, dependency-free).
 *
 * Cache-first for same-origin GET requests, versioned cache cleanup on
 * activate, and an offline fallback document for navigation requests.
 * Placeholders are substituted by `Saci::PWA.service_worker_source`.
 */
const VERSION = "__SACI_VERSION__";
const CACHE_NAME = "__SACI_CACHE__";
const PRECACHE_URLS = __SACI_PRECACHE__;
const OFFLINE_URL = "__SACI_OFFLINE_URL__";

self.addEventListener("install", function (event) {
  event.waitUntil(
    caches.open(CACHE_NAME).then(function (cache) {
      return cache.addAll(PRECACHE_URLS);
    }).then(function () {
      return self.skipWaiting();
    })
  );
});

self.addEventListener("activate", function (event) {
  event.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(keys.filter(function (key) {
        return key.indexOf("saci-pwa-") === 0 && key !== CACHE_NAME;
      }).map(function (key) {
        return caches.delete(key);
      }));
    }).then(function () {
      return self.clients.claim();
    })
  );
});

self.addEventListener("fetch", function (event) {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  event.respondWith(
    caches.open(CACHE_NAME).then(function (cache) {
      return cache.match(request, { ignoreSearch: request.mode === "navigate" }).then(function (cached) {
        if (cached) return cached;

        return fetch(request).then(function (response) {
          if (response && response.ok && (response.type === "basic" || response.type === "default")) {
            cache.put(request, response.clone());
          }
          return response;
        }).catch(function (error) {
          if (request.mode === "navigate") {
            return cache.match(OFFLINE_URL).then(function (offline) {
              if (offline) return offline;
              throw error;
            });
          }
          throw error;
        });
      });
    })
  );
});
