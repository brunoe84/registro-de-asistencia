// Muestra los recordatorios de asistencia aunque la página esté cerrada.
self.addEventListener('push', e => {
  const d = e.data ? e.data.json() : {};
  e.waitUntil(self.registration.showNotification(d.title || 'Asistencia pendiente', {
    body: d.body || 'Tienes asistencia por marcar.',
    icon: '/icon-192.png',
    badge: '/icon-192.png',
    tag: 'asistencia-pendiente',
    renotify: true,
    data: { url: d.url || '/' }
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type:'window', includeUncontrolled:true }).then(list => {
    const abierta = list.find(c => 'focus' in c);
    return abierta ? abierta.focus() : self.clients.openWindow(e.notification.data.url);
  }));
});
