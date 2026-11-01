// Envía el recordatorio al celular a los maestros con asistencia atrasada.
// La programación en la base de datos la llama cada 5 horas; al ponerse al día, el maestro deja de recibirlo.
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2.118.0';

const DIAS_RETRASO = 7;
const ZONA = 'America/Lima';
const FIJOS = ['01-01', '05-01', '06-07', '06-29', '07-23', '07-28', '07-29', '08-06', '08-30', '10-08', '11-01', '12-08', '12-09', '12-25'];

const iso = (d: Date) => d.toISOString().slice(0, 10);
const utc = (s: string) => new Date(s + 'T00:00:00Z');
const hoy = () => new Intl.DateTimeFormat('en-CA', { timeZone: ZONA }).format(new Date());

function pascua(y: number) {
  const a = y % 19, b = Math.floor(y / 100), c = y % 100, d = Math.floor(b / 4), e = b % 4, f = Math.floor((b + 8) / 25), g = Math.floor((b - f + 1) / 3);
  const h = (19 * a + b - d - g + 15) % 30, i = Math.floor(c / 4), k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7, m = Math.floor((a + 11 * h + 22 * l) / 451);
  const mes = Math.floor((h + l - 7 * m + 114) / 31), dia = ((h + l - 7 * m + 114) % 31) + 1;
  return new Date(Date.UTC(y, mes - 1, dia));
}
function bloqueado(s: string) {
  const d = utc(s);
  if (d.getUTCDay() === 0) return true;
  const y = d.getUTCFullYear();
  if (FIJOS.includes(s.slice(5))) return true;
  const p = pascua(y).getTime();
  return d.getTime() === p - 3 * 864e5 || d.getTime() === p - 2 * 864e5;
}

type Clase = { usuario_id: string; dias: number[] | null; inicio: string | null; fin: string | null; fechas_extra: string[] | null; fechas_omitidas: string[] | null; ultima_fecha: string | null };

// Mismo criterio que la app: la primera sesión sin marcar tiene más de una semana.
function atrasada(c: Clase, t: string) {
  if (!c.inicio || !c.dias) return false;
  const tope = c.fin && c.fin < t ? c.fin : t;
  const fechas = new Set<string>();
  for (let d = utc(c.inicio); iso(d) <= tope; d = new Date(d.getTime() + 864e5)) {
    if (c.dias.includes(d.getUTCDay()) && !bloqueado(iso(d))) fechas.add(iso(d));
  }
  (c.fechas_extra || []).forEach((x) => { if (x <= t) fechas.add(x); });
  (c.fechas_omitidas || []).forEach((x) => fechas.delete(x));
  const pend = [...fechas].filter((x) => x > (c.ultima_fecha || '')).sort();
  if (!pend.length) return false;
  return Math.floor((utc(t).getTime() - utc(pend[0]).getTime()) / 864e5) > DIAS_RETRASO;
}

Deno.serve(async (req) => {
  if (req.headers.get('x-recordatorio') !== Deno.env.get('RECORDATORIO_SECRETO')) return new Response('No autorizado', { status: 401 });
  const opciones = await req.json().catch(() => ({}));
  webpush.setVapidDetails(Deno.env.get('VAPID_CONTACTO')!, Deno.env.get('VAPID_PUBLICA')!, Deno.env.get('VAPID_PRIVADA')!);
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

  const t = hoy();
  const conteo = new Map<string, number>();
  if (opciones.prueba_usuario) conteo.set(opciones.prueba_usuario, 1);
  else {
    const { data, error } = await db.rpc('clases_para_recordatorio');
    if (error) return Response.json({ error: error.message }, { status: 500 });
    for (const c of data as Clase[]) if (atrasada(c, t)) conteo.set(c.usuario_id, (conteo.get(c.usuario_id) || 0) + 1);
  }
  if (!conteo.size) return Response.json({ atrasados: 0, enviados: 0, fallidos: 0, borrados: 0 });

  const { data: subs, error } = await db.from('suscripciones_push').select('*').in('usuario_id', [...conteo.keys()]);
  if (error) return Response.json({ error: error.message }, { status: 500 });

  let enviados = 0, fallidos = 0, borrados = 0;
  for (const s of subs || []) {
    const n = conteo.get(s.usuario_id)!;
    const cuerpo = opciones.prueba_usuario
      ? 'Prueba: los recordatorios funcionan en este celular.'
      : n === 1 ? 'Tu clase tiene asistencia atrasada. Toca para ponerla al día.' : `Tienes ${n} clases con asistencia atrasada. Toca para ponerlas al día.`;
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify({ title: 'Asistencia pendiente', body: cuerpo, url: '/' }), { TTL: 4 * 3600 });
      enviados++;
      await db.from('suscripciones_push').update({ ultimo_envio: new Date().toISOString() }).eq('endpoint', s.endpoint);
    } catch (e) {
      const codigo = (e as { statusCode?: number }).statusCode;
      if (codigo === 404 || codigo === 410) { await db.from('suscripciones_push').delete().eq('endpoint', s.endpoint); borrados++; }
      else { fallidos++; console.error('push', codigo); }
    }
  }
  return Response.json({ atrasados: conteo.size, enviados, fallidos, borrados });
});
