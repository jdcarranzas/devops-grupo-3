// =============================================================================
// Generador de carga para Keycloak (k6)
//
//   setup()   : crea (si no existe) el realm "demo" con un cliente confidencial,
//               un cliente público y un usuario de prueba, usando la API de admin.
//   default() : simula el tráfico de un IdP real contra los endpoints OIDC:
//                 - 70 % client_credentials   (servicio a servicio, barato)
//                 - 20 % password grant        (login de usuario: hash de la clave;
//                                               1 de cada 20 con clave errada -> 401)
//                 - 10 % discovery + JWKS      (lo que consultan las aplicaciones)
//
// Perfiles (variable PERFIL):
//   nominal : tráfico estable y bajo (por defecto). Para las capturas del dashboard.
//   estres  : rampa hasta muchos usuarios concurrentes. Para degradar la latencia
//             y saturar CPU/pool de conexiones.
//
// Uso (desde la raíz del repositorio):
//   docker compose --env-file .env -f observability/docker-compose.yml \
//     run --rm k6 run /scripts/carga.js                      # nominal, 10 min
//   docker compose --env-file .env -f observability/docker-compose.yml \
//     run --rm -e PERFIL=estres k6 run /scripts/carga.js     # estrés
// =============================================================================
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.KC_URL || 'http://kc-app:8080';
const ADMIN_USER = __ENV.KC_BOOTSTRAP_ADMIN_USERNAME || 'admin';
const ADMIN_PASS = __ENV.KC_BOOTSTRAP_ADMIN_PASSWORD;
const PERFIL = __ENV.PERFIL || 'nominal';
const DURACION = __ENV.DURACION || '10m';
// Tasa máxima del perfil de estrés (iteraciones/s). Súbala si el equipo no se degrada.
const TASA_MAX = parseInt(__ENV.TASA_MAX || '60', 10);

const REALM = 'demo';
const CLIENT_ID = 'servicio-demo';
const CLIENT_SECRET = 'secreto-solo-para-pruebas-de-carga';
const PUBLIC_CLIENT = 'app-demo';
const USER = 'usuario-demo';
const USER_PASS = 'Clave-de-prueba-123';

const perfiles = {
  nominal: {
    executor: 'constant-arrival-rate',
    rate: 5, // 5 iteraciones por segundo (~5 req/s)
    timeUnit: '1s',
    duration: DURACION,
    preAllocatedVUs: 10,
    maxVUs: 30,
  },
  estres: {
    executor: 'ramping-arrival-rate',
    startRate: 5,
    timeUnit: '1s',
    preAllocatedVUs: 50,
    maxVUs: Math.max(300, TASA_MAX * 5),
    stages: [
      { target: Math.round(TASA_MAX / 3), duration: '2m' },
      { target: TASA_MAX, duration: '3m' },
      { target: TASA_MAX, duration: '5m' },
      { target: 5, duration: '1m' },
    ],
  },
};

export const options = {
  setupTimeout: '4m',
  scenarios: { trafico: perfiles[PERFIL] || perfiles.nominal },
  // No se aborta la prueba por errores: justamente se quiere observar la degradación.
  thresholds: {
    'http_req_duration{endpoint:token}': ['p(95)<250'],
    'checks': ['rate>0.99'],
  },
};

function form(obj) {
  return Object.keys(obj)
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(obj[k])}`)
    .join('&');
}

const FORM = { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } };

export function setup() {
  if (!ADMIN_PASS) {
    throw new Error('Defina KC_BOOTSTRAP_ADMIN_PASSWORD (se toma del archivo .env)');
  }
  // Espera hasta 3 minutos a que Keycloak responda (puede estar arrancando).
  let listo = null;
  for (let i = 0; i < 36; i++) {
    listo = http.get(`${BASE}/realms/master`, { timeout: '5s' });
    if (listo.status === 200) break;
    console.log(`Esperando a Keycloak en ${BASE} (intento ${i + 1}/36): ${listo.error || 'HTTP ' + listo.status}`);
    sleep(5);
  }
  if (listo.status !== 200) {
    throw new Error(
      `Keycloak no responde en ${BASE}: ${listo.error || 'HTTP ' + listo.status}. ` +
        'Verifique con "docker compose ps" que kc-app esté running/healthy y en la red keycloak-devops_backend.',
    );
  }
  const tok = http.post(
    `${BASE}/realms/master/protocol/openid-connect/token`,
    form({ grant_type: 'password', client_id: 'admin-cli', username: ADMIN_USER, password: ADMIN_PASS }),
    FORM,
  );
  if (tok.status !== 200) {
    throw new Error(
      `No se pudo autenticar como administrador (HTTP ${tok.status} ${tok.error || ''}). ` +
        'Revise KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD en .env: solo aplican en el PRIMER arranque con un volumen vacío.',
    );
  }
  const auth = { headers: { Authorization: `Bearer ${tok.json('access_token')}`, 'Content-Type': 'application/json' } };

  // Idempotente: solo crea el realm si no existe.
  if (http.get(`${BASE}/admin/realms/${REALM}`, auth).status === 404) {
    const realm = {
      realm: REALM,
      enabled: true,
      clients: [
        {
          clientId: CLIENT_ID,
          enabled: true,
          publicClient: false,
          secret: CLIENT_SECRET,
          serviceAccountsEnabled: true,
          standardFlowEnabled: false,
          directAccessGrantsEnabled: false,
        },
        {
          clientId: PUBLIC_CLIENT,
          enabled: true,
          publicClient: true,
          standardFlowEnabled: true,
          directAccessGrantsEnabled: true,
          redirectUris: ['http://localhost/*'],
        },
      ],
      users: [
        {
          username: USER,
          enabled: true,
          email: 'usuario-demo@example.org',
          emailVerified: true,
          firstName: 'Usuario',
          lastName: 'Demo',
          credentials: [{ type: 'password', value: USER_PASS, temporary: false }],
        },
      ],
    };
    const r = http.post(`${BASE}/admin/realms`, JSON.stringify(realm), auth);
    check(r, { 'realm demo creado': (x) => x.status === 201 });
  }
  return {};
}

export default function () {
  const p = Math.random();
  if (p < 0.7) {
    const r = http.post(
      `${BASE}/realms/${REALM}/protocol/openid-connect/token`,
      form({ grant_type: 'client_credentials', client_id: CLIENT_ID, client_secret: CLIENT_SECRET }),
      Object.assign({ tags: { endpoint: 'token' } }, FORM),
    );
    check(r, { 'token client_credentials 200': (x) => x.status === 200 });
  } else if (p < 0.9) {
    // Usuarios que se equivocan de clave: 4xx esperado, no consume presupuesto de error.
    const claveErrada = Math.random() < 0.05;
    const r = http.post(
      `${BASE}/realms/${REALM}/protocol/openid-connect/token`,
      form({
        grant_type: 'password',
        client_id: PUBLIC_CLIENT,
        username: USER,
        password: claveErrada ? 'clave-equivocada' : USER_PASS,
        scope: 'openid',
      }),
      Object.assign({ tags: { endpoint: 'token' } }, FORM),
    );
    if (claveErrada) {
      check(r, { 'clave errada rechazada (401)': (x) => x.status === 401 });
    } else {
      check(r, { 'token password 200': (x) => x.status === 200 });
    }
  } else {
    const d = http.get(`${BASE}/realms/${REALM}/.well-known/openid-configuration`, { tags: { endpoint: 'discovery' } });
    const c = http.get(`${BASE}/realms/${REALM}/protocol/openid-connect/certs`, { tags: { endpoint: 'certs' } });
    check(d, { 'discovery 200': (x) => x.status === 200 });
    check(c, { 'certs 200': (x) => x.status === 200 });
  }
  sleep(0.1);
}
