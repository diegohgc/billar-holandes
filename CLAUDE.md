# PuckSlide (Billar Holandés / Sjoelen) — App web + APK

Juego 3D de Billar Holandés (Sjoelen), un único archivo `index.html` (HTML + CSS + JS, sin build,
Three.js desde CDN). Modo local (hotseat) y modo online (login + rankings vía Supabase).

## Arquitectura
- **Todo el juego está en `index.html`** — un único IIFE gigante de JS. Ojo: cualquier `t()`
  (traducción) llamado FUERA de un manejador de eventos (en código que se ejecuta al cargar el
  script, antes de que `STR`/`LANG` estén definidos hacia la línea ~618) rompe TODO el script en
  silencio con `ReferenceError: Cannot access 'STR' before initialization`. Los textos iniciales
  van con `data-i18n="clave"` en el HTML (se aplican solos con `applyStaticI18n()` cuando toca);
  `t()` en JS solo dentro de callbacks (click, etc.).
- `auth-bridge.html`: página puente para el login de Google dentro de la app Android (ver abajo).
- `privacy.html`: política de privacidad (incluye sección de borrado de cuenta).
- `supabase-schema.sql`: copia versionada del esquema real ejecutado en Supabase (tablas +
  vistas de ranking). Si se cambia el esquema en Supabase, actualizar también este archivo.
- Se publica con **GitHub Pages**: https://diegohgc.github.io/billar-holandes/
- Backend online: **Supabase** (Postgres + Auth). Project URL y anon key están hardcodeados al
  principio del `<script>` de `index.html` (son claves públicas, seguras para el cliente).
- **APK Android** (repo aparte `diegohgc/billar-holandes-apk`): WebView que carga la URL de
  arriba con `?app=android`. Cambios solo en `index.html` no requieren tocar el APK ni Play Store.

## Modo online: estado (2026-07-15)
- Login con Google (OAuth) y con email+contraseña, ambos funcionando en web y en la app Android.
- Perfil (nombre + país), partidas en solitario guardadas en Supabase, clasificación (general
  /mensual/anual, jugadores/países) con reglas anti-inactividad (7 días sin jugar = fuera del
  ranking, sin penalización).
- **Login de Google dentro de la APK** (fue muy costoso de conseguir, no tocar sin motivo):
  WebView intercepta navegación a `accounts.google.com` → abre **Chrome Custom Tabs**
  (forzando `com.android.chrome`) → Supabase redirige a `auth-bridge.html` → esa página relanza
  la app con un `intent://...package=com.diegohgc.billarholandes;...` (el token viaja como query
  `authFragment`, no como fragmento, porque un `intent://` no admite un segundo `#`) →
  `MainActivity.kt` lo recoloca como fragmento real de la URL del juego. Ver detalle completo en
  el repo del APK y en la memoria de Claude Code de este proyecto (si trabajas desde el mismo
  ordenador de siempre).
- Formulario de "Contacto" y "Solicitar borrado de cuenta" en el juego: usan **Web3Forms**
  (servicio gratuito, sin backend propio) para mandar el mensaje por email sin exponer el email
  personal del desarrollador en ningún sitio público.
- Recuperación de contraseña ("¿Olvidaste tu contraseña?") con `resetPasswordForEmail`.
- Borrar una cuenta de verdad (cuando llega una solicitud): Supabase → Authentication → Users →
  buscar por email → "Delete user". Con eso basta, hay `on delete cascade` en las tablas
  relacionadas (perfil + historial de partidas se borran solos).

## Pendiente / ideas aparcadas
- Notificación automática por email cuando se registra un usuario nuevo (Database Webhook de
  Supabase en la tabla `profiles`, evento INSERT, apuntando a la API de Web3Forms).
- Duelos 1v1 asíncronos (fase 2 del roadmap online, no empezada).
- Subir los mínimos de partidas de las vistas de ranking (están bajados a 2 para pruebas; los
  valores de diseño original son 10/5/10 según la vista).

## Flujo de trabajo
- `git pull` al empezar, `git add -A && git commit -m "..." && git push` al terminar.
- Antes de dar por publicado un cambio de JS, comprobarlo con
  `node -e "new Function(js)"` (sintaxis) — pero eso NO detecta errores de orden de ejecución
  (como el de `t()` de arriba), así que ante dudas de comportamiento real, pedir al usuario que
  mire la consola de su propio navegador (F12), no fiarse de vistas previas con caché.
