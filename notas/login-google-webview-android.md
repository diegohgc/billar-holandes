# Login con Google en una app Android que envuelve una web (WebView) — cómo hacerlo bien desde el principio

Nota para futuros proyectos: si vuelvo a crear una app Android que es básicamente un WebView
cargando una web (como PuckSlide), y esa web tiene login con Google vía Supabase (o Firebase,
o cualquier backend con OAuth), **no empieces por el camino del navegador**. Ve directo a la
opción nativa de abajo — ahorra días de depuración.

## El problema de fondo

Un WebView normal **no puede** hacer login de Google directamente: Google lo bloquea
(`disallowed_useragent`), por seguridad — no sabe si ese WebView está intentando robar la
contraseña.

## Camino 1 (el que probamos primero, y el que falló en producción)

Sacar el login fuera del WebView a un navegador de verdad:

1. La web detecta que la URL es de `accounts.google.com` y en vez de cargarla en el WebView,
   lanza una **Chrome Custom Tab** (`androidx.browser`).
2. Al terminar el login, el backend (Supabase) redirige a una página puente
   (`auth-bridge.html`) alojada en la misma web.
3. Esa página puente tiene un botón que el usuario debe pulsar de verdad (Chrome bloquea saltos
   automáticos sin gesto real del usuario) y que lanza un `intent://...package=com.tuapp...`
   para volver a abrir la app con el token en la URL.
4. La `MainActivity` recibe ese intent en `onNewIntent`, extrae el token y recarga el WebView
   con él en la URL para que el JS del login lo procese.

**Esto funcionó bien mucho tiempo, pero acabó fallando de forma intermitente en ciertos
dispositivos** (confirmado en un Vivo/OriginOS): justo al elegir la cuenta de Google, el propio
sistema operativo mataba la tarea de la Custom Tab a medio camino (`clear-task-stack` en el
log), sin llegar nunca a cargar la página puente. El usuario veía el selector de Google, elegía
su cuenta, y volvía a la pantalla de login sin más explicación — nunca un error visible.

### Cómo se diagnosticó (si vuelve a pasar)
- Conectar el móvil por USB con depuración USB activada (`adb devices` para confirmar).
- `adb logcat -c` (limpiar) y luego `adb logcat -b all -v time > log.txt` en segundo plano.
- Pedir al usuario que reproduzca el fallo UNA vez y avisar en cuanto vuelva a la pantalla de
  login (así se puede acotar el momento exacto).
- Buscar en el log: `wm_create_activity`, `wm_finish_activity`, `wm_new_intent`,
  `wm_task_to_front` — cuentan la vida entera de las Activities/tareas involucradas, con sus
  timestamps. Es mucho más fiable que adivinar, y no hace falta Android Studio para leerlo.
- La pista clave: el intent que finalmente volvía a `MainActivity` era un simple
  `android.intent.action.MAIN` con datos `NULL` — es decir, la app nunca recibía el token, solo
  un "vuelve a primer plano" genérico, como si se hubiera tocado el icono de la app.

## Camino 2 (la solución de verdad, la que se quedó)

**Login nativo con Credential Manager**, sin salir nunca de la app ni tocar un navegador:

- El selector de cuenta de Google es una hoja del propio sistema Android (como el de
  autocompletar contraseñas) — la app nunca pierde el foco, no hay nada que un fabricante
  (Vivo, Xiaomi, etc.) pueda interrumpir por el camino.

### Piezas necesarias

**1) Dependencias (Gradle):**
```kotlin
implementation("androidx.credentials:credentials:1.3.0")
implementation("androidx.credentials:credentials-play-services-auth:1.3.0") // compatibilidad con moviles mas antiguos
implementation("com.google.android.libraries.identity.googleid:googleid:1.1.1")
implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7") // para lifecycleScope
```

**2) El Client ID "Web" que ya tengas en Supabase/Firebase** (Authentication → Providers →
Google → Client ID) se reutiliza como `serverClientId` en el código Android — no hace falta
crear uno nuevo para esto.

**3) Registrar la huella SHA-1 de la app en Google Cloud Console** (mismo proyecto que el
Client ID Web) como un Client ID nuevo de **tipo Android**:
   - APIs & Services → Credentials → Crear credenciales → ID de cliente de OAuth → Android
   - Nombre del paquete + huella SHA-1
   - **Ojo, esto es lo que más tiempo costó**: hay que registrar la huella de **cada firma que
     realmente vaya a usarse**:
     - La del keystore de **debug** (para probar en el móvil sin publicar) —
       sacarla con: `keytool -list -v -keystore ~/.android/debug.keystore -alias
       androiddebugkey -storepass android -keypass android`
     - La del keystore de **subida/upload** (con el que firmas localmente antes de subir a
       Play Console) — `keytool -list -v -keystore tu-release.jks -alias tu-alias -storepass ...`
     - **Si tienes activado Play App Signing** (Google re-firma la app antes de repartirla a
       los usuarios — es el caso normal hoy en día), la huella que de verdad importa es la
       del **certificado de firma de la app**, que es DISTINTA a la de tu keystore de subida.
       Se saca desde Play Console → tu app → **Protegida con Play** → **Gestiona la firma de
       aplicaciones de Play** → sección **"Clave de firma de aplicación"** (arriba del todo,
       NO la de "Certificado de clave de subida" que aparece más abajo — esa es solo la que
       usas tú para subir, no la que llevan los usuarios).
   - Cada huella nueva puede tardar de 5 minutos a unas horas en activarse.

**4) Kotlin (MainActivity o donde tengas el WebView):**
```kotlin
private val credentialManager by lazy { CredentialManager.create(this) }

// puente para que el JS de la web pueda pedir el login
webView.addJavascriptInterface(object {
    @JavascriptInterface
    fun signInWithGoogle() {
        runOnUiThread { launchGoogleSignIn() }
    }
}, "AndroidAuth")

private fun launchGoogleSignIn() {
    val rawNonce = UUID.randomUUID().toString()
    val hashedNonce = MessageDigest.getInstance("SHA-256")
        .digest(rawNonce.toByteArray()).joinToString("") { "%02x".format(it) }

    val request = GetCredentialRequest.Builder()
        .addCredentialOption(
            GetGoogleIdOption.Builder()
                .setFilterByAuthorizedAccounts(false)
                .setServerClientId(GOOGLE_WEB_CLIENT_ID) // el Client ID "Web", no el Android
                .setNonce(hashedNonce)
                .build()
        ).build()

    lifecycleScope.launch {
        try {
            val result = credentialManager.getCredential(this@MainActivity, request)
            val cred = result.credential
            if (cred is CustomCredential && cred.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) {
                val idToken = GoogleIdTokenCredential.createFrom(cred.data).idToken
                webView.evaluateJavascript(
                    "window.onNativeGoogleIdToken('$idToken', '$rawNonce')", null
                )
            }
        } catch (e: GetCredentialException) {
            // el usuario cancelando (pulsar atrás) tambien cae aqui - no es un fallo real
        }
    }
}
```

**5) JS (la web dentro del WebView):**
```js
// si el puente nativo existe, usarlo en vez de abrir un navegador
if (window.AndroidAuth && window.AndroidAuth.signInWithGoogle) {
  window.AndroidAuth.signInWithGoogle();
} else {
  // fallback de siempre (redirectTo + signInWithOAuth) para web normal / apps antiguas
}

window.onNativeGoogleIdToken = async (idToken, nonce) => {
  const { error } = await supabase.auth.signInWithIdToken({ provider: 'google', token: idToken, nonce });
  // si no hay error, ya hay sesión iniciada - seguir el flujo normal de la app
};
```

### Ventajas sobre el camino 1
- No depende de que Chrome/el sistema devuelva bien el control a la app — elimina esa clase
  entera de fallos intermitentes por fabricante.
- Menos pasos, menos sitios donde algo puede romperse (nada de páginas puente, nada de
  `intent://`, nada de exigir un toque real del usuario para saltar de vuelta).
- El usuario nunca sale visualmente de la app.

### Lección general
Si una app-WebView necesita login de Google, **empezar directamente por Credential Manager**
en vez de por Custom Tabs + redirección — el camino del navegador parece más simple al
principio (menos dependencias, menos configuración en Google Cloud) pero es frágil a largo
plazo porque depende de cómo cada fabricante de Android gestione el ciclo de vida de tareas
entre apps, y eso está fuera de nuestro control.
