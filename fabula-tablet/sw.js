const CACHE = 'perla-v45';
const SHELL = ['./', './index.html', './app.js', './config.js', './brand.js', './perm.js', './ui.js', './ui.css', './manifest.json', './icon.svg', './labels.html',
  './vendor/supabase.js', './vendor/html5-qrcode.min.js', './vendor/qrcode.min.js'];
// v0.48b: a new version takes over at once (skipWaiting + clients.claim) instead of waiting for every app tab to close,
// and app files are network-first: online you always get the deployed code, offline (or > 3 s) the cached copy.
self.addEventListener('install', e => { self.skipWaiting(); e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL))); });
self.addEventListener('activate', e => e.waitUntil(caches.keys()
  .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
  .then(() => self.clients.claim())));
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET' || !e.request.url.startsWith(self.location.origin)) return;
  e.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const net = fetch(e.request, { cache: 'no-cache' }).then(r => { if (r.ok && r.type === 'basic') cache.put(e.request, r.clone()); return r; });
    const timeout = new Promise(res => setTimeout(res, 3000));
    try { const r = await Promise.race([net, timeout]); if (r) return r; } catch {}
    return (await cache.match(e.request, { ignoreSearch: true })) || net;
  })());
});
