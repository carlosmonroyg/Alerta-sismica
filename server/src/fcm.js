// Envío de notificaciones por Firebase Cloud Messaging (HTTP v1).
//
// FCM no cobra por mensaje ni por dispositivo: el envío es gratuito sin
// límite. Lo que cuidamos es el número de PETICIONES, agrupando hasta 5 temas
// por condición para respetar el límite de sub-peticiones del plan gratuito.
//
// Credenciales (secretos del Worker, nunca en el código):
//   FCM_PROJECT_ID · FCM_CLIENT_EMAIL · FCM_PRIVATE_KEY
// Sin ellas el módulo entra en MODO PRUEBA: no envía nada y devuelve lo que
// habría enviado, para poder verificar todo el flujo sin cuenta de Firebase.

const MAX_TEMAS_POR_CONDICION = 5;
let cacheToken = { valor: null, expira: 0 };

function pemABytes(pem) {
  // La clave llega de distintas formas según cómo se cargue el secreto: con
  // saltos de línea reales, o con la secuencia literal barra-n si vino de un
  // archivo .env. En vez de contemplar cada caso, se descarta TODO lo que no
  // sea un carácter válido de base64: cabeceras, espacios, saltos y barras.
  // Ojo: hay que quitar la secuencia COMPLETA barra-n. Si solo se filtran los
  // caracteres no válidos de base64, las barras se van pero las "n" se quedan
  // —la "n" es base64 válido— y la clave queda corrupta en silencio.
  const barraN = String.fromCharCode(92) + "n";
  const soloBase64 = new RegExp("[^A-Za-z0-9+/=]", "g");
  const limpio = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .split(barraN)
    .join("")
    .replace(soloBase64, "");
  const bin = atob(limpio);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

const b64url = (bytes) => {
  const bin = String.fromCharCode(...new Uint8Array(bytes));
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const b64urlTexto = (txt) =>
  b64url(new TextEncoder().encode(txt));

/** Token OAuth2 de la cuenta de servicio (se reutiliza ~55 minutos). */
async function accessToken(env) {
  const ahora = Math.floor(Date.now() / 1000);
  if (cacheToken.valor && cacheToken.expira > ahora + 60) return cacheToken.valor;

  const encabezado = b64urlTexto(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64urlTexto(JSON.stringify({
    iss: env.FCM_CLIENT_EMAIL,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: ahora,
    exp: ahora + 3600,
  }));
  const sinFirma = `${encabezado}.${claims}`;

  const llave = await crypto.subtle.importKey(
    "pkcs8",
    pemABytes(env.FCM_PRIVATE_KEY),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const firma = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    llave,
    new TextEncoder().encode(sinFirma)
  );
  const jwt = `${sinFirma}.${b64url(firma)}`;

  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!r.ok) throw new Error(`OAuth ${r.status}: ${await r.text()}`);
  const j = await r.json();
  cacheToken = { valor: j.access_token, expira: ahora + (j.expires_in ?? 3600) };
  return cacheToken.valor;
}

const hayCredenciales = (env) =>
  Boolean(env.FCM_PROJECT_ID && env.FCM_CLIENT_EMAIL && env.FCM_PRIVATE_KEY);

/**
 * Envía un mensaje a un conjunto de zonas (temas).
 * @returns {{enviados:number, condiciones:number, simulado:boolean, errores:string[]}}
 */
export async function enviarAZonas(env, zonas, { datos, notificacion, urgente }) {
  const grupos = [];
  for (let i = 0; i < zonas.length; i += MAX_TEMAS_POR_CONDICION) {
    grupos.push(zonas.slice(i, i + MAX_TEMAS_POR_CONDICION));
  }

  if (!hayCredenciales(env)) {
    return {
      enviados: 0, condiciones: grupos.length, simulado: true, errores: [],
      muestra: { condicion: condicionDe(grupos[0] ?? []), datos, notificacion },
    };
  }

  const token = await accessToken(env);
  const url = `https://fcm.googleapis.com/v1/projects/${env.FCM_PROJECT_ID}/messages:send`;
  const errores = [];
  let enviados = 0;

  // En paralelo: enviados uno tras otro, ocho grupos tardaban más de seis
  // segundos. En una alerta sísmica ese tiempo es el que la gente pierde.
  const respuestas = await Promise.all(
    grupos.map(async (grupo) => {
      const mensaje = {
        condition: condicionDe(grupo),
        // Datos siempre: la app decide si mostrar la alerta según el radio y
        // la magnitud mínima que configuró el usuario. Añadir carga de
        // "notificación" le quita esa decisión —Android la dibuja solo—, así
        // que se reserva para lo que no depende de un umbral de magnitud: el
        // consenso comunitario y los simulacros.
        data: Object.fromEntries(
          Object.entries(datos).map(([k, v]) => [k, String(v)])
        ),
        android: {
          priority: urgente ? "high" : "normal",
          // Debe existir en el teléfono: lo declara crearCanalesDeSismo()
          // en app_flutter/lib/quake_notify.dart. Un canal desconocido hace
          // que Android descarte el aviso sin mostrarlo.
          ...(notificacion
            ? { notification: { channel_id: "sismos_sentidos" } }
            : {}),
        },
        ...(notificacion ? { notification: notificacion } : {}),
      };
      try {
        const r = await fetch(url, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ message: mensaje }),
        });
        if (r.ok) return { ok: true };
        return { ok: false, error: `${r.status}: ${(await r.text()).slice(0, 160)}` };
      } catch (e) {
        return { ok: false, error: e.message };
      }
    })
  );

  for (const r of respuestas) {
    if (r.ok) enviados++;
    else errores.push(r.error);
  }
  return { enviados, condiciones: grupos.length, simulado: false, errores };
}

/**
 * Vía rápida: envía directo a los teléfonos, uno por uno.
 *
 * El reparto por temas está pensado para difusión masiva y Firebase lo entrega
 * con calma —medimos hasta 80 s—. Para un sismo eso es demasiado: el envío
 * directo por token llega en segundos. Se reserva para las alertas graves y
 * para los dispositivos más cercanos al epicentro, que son los que menos
 * tiempo tienen para reaccionar.
 *
 * El plan gratuito de Cloudflare limita las peticiones salientes por
 * invocación, de ahí el tope: primero los más cercanos, y el resto queda
 * cubierto por el envío por zonas que va en paralelo.
 *
 * @returns {{enviados:number, fallidos:number, invalidos:string[], simulado:boolean}}
 */
export async function enviarADispositivos(env, tokens, { datos, urgente }) {
  if (!tokens.length) {
    return { enviados: 0, fallidos: 0, invalidos: [], simulado: false };
  }
  if (!hayCredenciales(env)) {
    return {
      enviados: 0, fallidos: 0, invalidos: [], simulado: true,
      alcance: tokens.length,
    };
  }

  const token = await accessToken(env);
  const url = `https://fcm.googleapis.com/v1/projects/${env.FCM_PROJECT_ID}/messages:send`;
  const cuerpo = {
    data: Object.fromEntries(Object.entries(datos).map(([k, v]) => [k, String(v)])),
    android: { priority: urgente ? "high" : "normal" },
  };

  // Las peticiones van en paralelo: en una emergencia, esperar la respuesta de
  // un teléfono antes de avisar al siguiente cuesta segundos que importan.
  const respuestas = await Promise.all(
    tokens.map(async (t) => {
      try {
        const r = await fetch(url, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ message: { ...cuerpo, token: t } }),
        });
        if (r.ok) return { ok: true };
        const texto = await r.text();
        // Token muerto (app desinstalada o reinstalada): hay que darlo de baja.
        const invalido =
          r.status === 404 ||
          texto.includes("UNREGISTERED") ||
          texto.includes("INVALID_ARGUMENT");
        return { ok: false, invalido, token: t };
      } catch (_) {
        return { ok: false, invalido: false, token: t };
      }
    })
  );

  return {
    enviados: respuestas.filter((r) => r.ok).length,
    fallidos: respuestas.filter((r) => !r.ok).length,
    invalidos: respuestas.filter((r) => r.invalido).map((r) => r.token),
    simulado: false,
  };
}

export function condicionDe(zonas) {
  return zonas.map((z) => `'${z}' in topics`).join(" || ");
}
