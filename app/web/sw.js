// Keep API and snapshot data live. The service worker supplies PWA installation.
self.addEventListener('install',()=>self.skipWaiting());
self.addEventListener('activate',event=>event.waitUntil(self.clients.claim()));
