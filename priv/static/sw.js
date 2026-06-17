self.addEventListener("install", event => {
  self.skipWaiting()
})

self.addEventListener("activate", event => {
  event.waitUntil(
    self.registration.unregister().then(() => self.clients.matchAll()).then(clients => {
      clients.forEach(client => client.navigate(client.url))
    })
  )
})
