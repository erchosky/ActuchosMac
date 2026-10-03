# Arquitectura

```text
SwiftUI (ContentView, Ajustes)
  └─ UpdateStore (@MainActor)
       ├─ [AnyUpdateProvider]   detect → check → update → verify
       ├─ InventoryReconciler   una entrada por instalación (índices, no búsquedas lineales)
       ├─ PlanBuilder           selección o «todo» + prioridad + deduplicación + grupos por gestor
       ├─ UpdateVerifier        decide el resultado con un inventario nuevo
       ├─ AppInstaller          descarga verificada y reemplazo de .app
       ├─ InventoryCache / HistoryStore / ReportBuilder
       └─ ProviderContext (uno por escaneo)
            ├─ ProcessRunner        ejecutable + argumentos, sin shell, timeout, stdin cerrado
            ├─ CommandCache         un mismo comando de solo lectura se ejecuta una vez por escaneo
            ├─ LoginShellResolver   qué ejecutable usaría tu shell de inicio
            ├─ HTTPFetching         solo HTTPS: feeds, redirecciones de releases y descargas
            ├─ ExecutableLocator    PATH, prefijos de gestores, raíces de NVM/pyenv…
            ├─ UpdatePolicy         ajustes del usuario, releídos en cada escaneo
            └─ TechnicalLogger      log acotado que oculta secretos
```

## Flujo

1. **Detección** (local y rápida): cada proveedor publica lo que encuentra en cuanto lo tiene. Firmas y arquitecturas de las apps se leen en el propio proceso con Security.framework, sin lanzar `codesign` ni `lipo` por cada app.
2. **Comprobación** (red): el mismo proveedor vuelve a publicar con el estado real. La interfaz se actualiza en ambos pasos.
3. **Reconciliación**: un bundle `.app` que ya controla un cask de Homebrew, la App Store, un editor u Ollama se fusiona con su dueño, así que cada instalación aparece una sola vez.
4. **Planificación**: con «Actualizar todo» entran las actualizaciones automáticas; con «Actualizar selección», exactamente lo marcado (incluidas las acciones bajo demanda). Se ordena por prioridad y se agrupa por `lockKey`: lo que comparte gestor (Homebrew, un mismo Python, Node…) va en serie y los grupos distintos van en paralelo (hasta 3 a la vez).
5. **Ejecución**: cancelar impide empezar elementos nuevos, pero deja terminar los que están en marcha, porque interrumpir un instalador a medias no es seguro.
6. **Verificación**: un chequeo nuevo por proveedor. Las apps y los paquetes releen solo su versión instalada, sin repetir las consultas de red.

## Instalación verificada de apps (`AppInstaller`)

1. Descarga HTTPS a una carpeta temporal.
2. Comprueba el SHA-256 o SHA-512 publicado o la firma EdDSA de Sparkle (`SUPublicEDKey`), cuando existen.
3. Extrae el ZIP, DMG (montado en solo lectura) o TAR y busca el bundle con el **mismo bundle identifier**.
4. Ejecuta `codesign --verify --deep --strict`, exige el **mismo Team ID** que la app instalada y pasa `spctl --assess` (Gatekeeper).
5. Si la app está abierta, la cierra con normalidad (puede pedir guardar documentos); si no se cierra, aborta.
6. Mueve la versión anterior a la Papelera, coloca la nueva (si algo falla, restaura la anterior) y vuelve a abrirla si estaba abierta.

Los `.pkg` necesitan permisos de administrador y no se instalan: la app ofrece abrir la web del fabricante.

## Ejecución de procesos

`ProcessRunner` recibe una ruta de ejecutable y un array de argumentos: ningún shell interpreta datos del inventario. La espera y la lectura de las tuberías ocurren en hilos de GCD, así que muchos comandos simultáneos no bloquean la concurrencia de Swift ni se atascan con tuberías llenas. El proceso hijo recibe un PATH con su propia carpeta y los prefijos habituales, porque una app abierta desde el Finder hereda un PATH mínimo.

El shell solo se usa en tres sitios, siempre con scripts fijos y los datos pasados como argumentos posicionales:

- `LoginShellResolver`, para saber qué `node`, `npm`, `python3`… está activo.
- `NVMProvider`, porque NVM es una función de shell.
- Las actualizaciones de Apple que no son macOS, que pasan por `osascript … with administrator privileges` para que macOS muestre su propio diálogo de contraseña.

## Tests

`UpdateStore` acepta un `ProcessRunning` y un escenario de demostración. Cuando el bundle de tests se ejecuta dentro de la app, el store usa siempre `DemoProvider`, de modo que los tests nunca inventarían ni modifican el Mac que los ejecuta.
