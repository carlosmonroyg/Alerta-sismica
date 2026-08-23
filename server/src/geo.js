// Geometría, cuadrícula difusa y estimación de intensidad.
//
// Se usan DOS granularidades a propósito:
//   · CELDA (0,25° ≈ 28 km) — la que se almacena. Difumina la ubicación del
//     usuario (nunca se guardan coordenadas exactas) y sirve para los mapas
//     de calor del municipio.
//   · ZONA  (1° ≈ 111 km) — el "tema" (topic) de FCM al que se suscribe el
//     teléfono. Al ser gruesa, una alerta regional se despacha en pocas
//     llamadas, respetando el límite de sub-peticiones del plan gratuito.
// El push lleva el epicentro y es la app la que decide si mostrarlo, según el
// radio y la magnitud mínima que configuró cada usuario.

export function haversineKm(la1, lo1, la2, lo2) {
  const R = 6371, d = Math.PI / 180;
  const a = Math.sin(((la2 - la1) * d) / 2) ** 2 +
    Math.cos(la1 * d) * Math.cos(la2 * d) * Math.sin(((lo2 - lo1) * d) / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

// Intensidad Mercalli aproximada (misma fórmula que la app, para que el
// servidor y el teléfono coincidan en el criterio).
export function intensidad(mag, distKm) {
  return 1.5 * mag - 3.0 * Math.log10(Math.max(distKm, 5) + 10) + 3.0;
}

export const GRADO_CELDA = 0.25;
export const GRADO_ZONA = 1.0;

const idx = (v, g) => Math.floor(v / g);

export function celdaDe(lat, lon) {
  return `k_${idx(lat, GRADO_CELDA)}_${idx(lon, GRADO_CELDA)}`;
}

export function zonaDe(lat, lon) {
  return `z_${idx(lat, GRADO_ZONA)}_${idx(lon, GRADO_ZONA)}`;
}

export function centroDeCelda(celda) {
  const [tipo, i, j] = celda.split("_");
  const g = tipo === "z" ? GRADO_ZONA : GRADO_CELDA;
  return { lat: (Number(i) + 0.5) * g, lon: (Number(j) + 0.5) * g };
}

/** Zonas (temas FCM) cuyo centro cae dentro de `radioKm` del epicentro. */
export function zonasEnRadio(lat, lon, radioKm) {
  const pasos = Math.ceil(radioKm / 111 / GRADO_ZONA) + 1;
  const i0 = idx(lat, GRADO_ZONA), j0 = idx(lon, GRADO_ZONA);
  const out = [];
  for (let di = -pasos; di <= pasos; di++) {
    for (let dj = -pasos; dj <= pasos; dj++) {
      const i = i0 + di, j = j0 + dj;
      const cLat = (i + 0.5) * GRADO_ZONA, cLon = (j + 0.5) * GRADO_ZONA;
      // Media diagonal de celda (~78 km) de tolerancia: así ninguna zona
      // parcialmente dentro del radio se queda sin aviso.
      if (haversineKm(lat, lon, cLat, cLon) <= radioKm + 78) out.push(`z_${i}_${j}`);
    }
  }
  return out;
}
