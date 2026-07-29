/* Service worker: app shell offline + soporte de notificaciones */
const CACHE = "alerta-sismica-v1";
const SHELL = ["./", "./index.html", "./manifest.json", "./icon.svg"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  // Datos del USGS: siempre red primero (datos en vivo), sin cache de respaldo
  if (url.hostname.includes("earthquake.usgs.gov")) return;
  // App shell: cache primero, red de respaldo
  e.respondWith(
    caches.match(e.request).then(hit => hit || fetch(e.request))
  );
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  e.waitUntil(clients.matchAll({ type: "window" }).then(list => {
    if (list.length) return list[0].focus();
    return clients.openWindow("./index.html");
  }));
});
