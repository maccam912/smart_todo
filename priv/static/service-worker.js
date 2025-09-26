const CACHE_NAME = "smart-todo-cache-v1"
const OFFLINE_URLS = ["/", "/manifest.webmanifest"]

self.addEventListener("install", event => {
  event.waitUntil(
    caches
      .open(CACHE_NAME)
      .then(cache => cache.addAll(OFFLINE_URLS))
      .then(() => self.skipWaiting())
  )
})

self.addEventListener("activate", event => {
  event.waitUntil(
    caches
      .keys()
      .then(keys => Promise.all(keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key))))
      .then(() => self.clients.claim())
  )
})

self.addEventListener("fetch", event => {
  const {request} = event

  if (request.method !== "GET") {
    return
  }

  const url = new URL(request.url)

  if (url.origin !== self.location.origin) {
    return
  }

  if (url.pathname.startsWith("/phoenix/") || url.pathname.startsWith("/live")) {
    return
  }

  event.respondWith(
    caches.open(CACHE_NAME).then(async cache => {
      try {
        const networkResponse = await fetch(request)

        if (networkResponse.ok && networkResponse.type === "basic") {
          cache.put(request, networkResponse.clone())
        }

        return networkResponse
      } catch (error) {
        const cached = await cache.match(request)

        if (cached) {
          return cached
        }

        if (request.mode === "navigate") {
          const offlinePage = await cache.match("/")

          if (offlinePage) {
            return offlinePage
          }
        }

        throw error
      }
    })
  )
})
