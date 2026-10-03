# ActuchosMac

Mi invento para revisar las actualizaciones del Mac sin ir abriendo veinte cosas. Apps, macOS, Homebrew, App Store, Node, Python, Rust, editores, herramientas de IA y paquetes: lo junta en una app nativa hecha con SwiftUI y te deja actualizar todo o solo lo que marques.

Y si algo no se puede comprobar, te dice **«no comprobado»**. Darlo por actualizado porque sí sería echarle demasiada fe, chacho.

## Qué puedes hacer con esto

- **Un escaneo de solo lectura** con 17 proveedores en paralelo. Los resultados aparecen según llegan y, al abrir, se muestra al instante el inventario anterior mientras se comprueba de nuevo.
- **Actualizar todo** o **Actualizar selección**: marca las casillas de lo que quieras (o "Seleccionar actualizables" por sección) y pulsa un botón. Lo que comparte gestor va en orden; lo demás, en paralelo.
- **Apps instaladas a mano también se actualizan** descargando la versión nueva del propio fabricante (feeds Sparkle y electron-updater, servicio de actualizaciones de VS Code, releases de GitHub) o del catálogo público de Homebrew. Antes de instalar se comprueba:
  - descarga solo por HTTPS,
  - SHA-256/SHA-512 publicado o firma EdDSA de Sparkle (cuando existen),
  - firma de código válida **del mismo desarrollador (Team ID)** que la app instalada,
  - aceptación de Gatekeeper (notarización).

  La versión anterior va a la **Papelera**, así que siempre se puede deshacer. Si la app está abierta, se cierra y se vuelve a abrir (configurable).
- **Dependencias y paquetes**:
  - pip, en **cada** Python instalado (Homebrew, python.org, pyenv, Command Line Tools)
  - paquetes globales de npm
  - gems de Ruby (no las del sistema)
  - binarios de `cargo install` (comprobados contra crates.io)
  - herramientas de pipx y `uv tool` (comprobadas contra PyPI)
  - toolchains de rustup
- **Gestores y runtimes**: macOS y componentes de Apple, fórmulas y casks de Homebrew (con `brew update` previo; marca las dependencias y respeta `brew pin`), Mac App Store con `mas` (si no lo tienes, te ofrece instalarlo), Node con NVM (misma versión mayor), npm, Corepack y pnpm, y Ollama con sus modelos. También comprueba Bun, Deno, uv, Composer, Go, fnm, Volta, pyenv y rbenv contra su última versión publicada.
- **Verificación**: después de actualizar, vuelve a leer la versión instalada. Un código de salida 0 no basta para dar algo por bueno.
- Simulación del plan, búsqueda, filtros, informe en Markdown/JSON, log técnico que oculta secretos e historial local.

## Hasta dónde llega

- Pedir, guardar ni automatizar tu contraseña de administrador. Las actualizaciones de Apple que la necesitan usan el diálogo del propio macOS.
- Instalar nada que no supere las comprobaciones de arriba, ni ejecutar scripts remotos con una tubería al shell.
- Tocar dependencias de tus proyectos ni entornos virtuales, ni cambiar la versión mayor de un runtime.
- Borrar software o ejecutar limpiezas (`brew autoremove`, purgas de caché…).
- Ejecutar `/usr/bin/python3` o `/usr/bin/java` si eso abriría un instalador del sistema.

## Requisitos

- macOS 15 o posterior (Apple Silicon o Intel)
- Xcode 16 o posterior para compilar

Homebrew, `mas`, NVM y el resto de gestores son opcionales; si faltan, simplemente hay menos que revisar.

## Cómo arrancarlo

```sh
git clone https://github.com/erchosky/ActuchosMac.git
cd ActuchosMac
open ActuchosMac.xcodeproj
```

Desde la terminal:

```sh
xcodebuild -project ActuchosMac.xcodeproj -scheme ActuchosMac -configuration Release build
```

Para generar un `.zip` de la app firmada ad hoc en `dist/`:

```sh
./scripts/package.sh
```

> Si el repositorio está en una carpeta sincronizada con iCloud, la firma puede fallar con *"resource fork, Finder information, or similar detritus not allowed"*. Compila con la ubicación por defecto de DerivedData (como arriba) o mueve el repositorio fuera de iCloud Drive.

La app no está notarizada: la primera vez, haz clic derecho sobre ella y elige **Abrir**.

## Comprobar que todo sigue en su sitio

```sh
xcodebuild -project ActuchosMac.xcodeproj -scheme ActuchosMac -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

Los tests usan mocks, HTTP simulado y datos sintéticos: nunca actualizan el Mac en el que se ejecutan. Hay además una prueba de integración opcional del instalador que trabaja sobre una **copia** temporal de una app con feed Sparkle:

```sh
TEST_RUNNER_ACTUCHOS_INTEGRATION_APP=/Applications/DaisyDisk.app xcodebuild -project ActuchosMac.xcodeproj -scheme ActuchosMac -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO -only-testing:ActuchosMacTests/InstallerIntegrationTests
```

## Modo demostración

Arranca con `--demo` (Xcode › Edit Scheme › Arguments) para usar datos sintéticos. No se ejecuta ningún comando real ni se guarda historial.

| Argumento | Escenario |
|---|---|
| `--demo` / `--demo=developer` | Cask de Homebrew, app Sparkle y app manual |
| `--demo=clean` | Solo macOS |
| `--demo=standard` | Usuario normal con apps que se actualizan solas y apps manuales |
| `--demo=many-updates` | Plan largo para probar el progreso |
| `--demo=failures` | Fallo aislado de un proveedor |
| `--demo=pyenv` | Python gestionado con pyenv |
| `--demo=homebrew-node` | Node gestionado con Homebrew |
| `--demo=multiple-node` | Node activo de NVM y otro adicional de Homebrew |
| `--demo=mas` | App gestionada por la Mac App Store |
| `--demo=manual-apps` | Apps sin proveedor automático |

## Ajustes

| Ajuste | Por defecto |
|---|---|
| Buscar actualizaciones al abrir | Sí |
| Consultar a los fabricantes (Sparkle, Electron, VS Code, GitHub…) | Sí |
| Usar el catálogo de Homebrew para apps instaladas a mano | Sí |
| Cerrar y volver a abrir las apps abiertas al actualizarlas | Sí |
| Incluir versiones beta | No |
| Refrescar el índice de Homebrew antes de comprobar | Sí |
| Incluir casks con actualizador propio (`--greedy`) | No |
| Permitir volver a descargar modelos de Ollama | No |

## Atajos

| Atajo | Acción |
|---|---|
| ⌘R | Buscar actualizaciones |
| ⌘U | Actualizar selección |
| ⇧⌘U | Actualizar todo |
| ⇧⌘A | Seleccionar todas las actualizaciones |

## Documentación

- [Arquitectura](docs/ARCHITECTURE.md)
- [Cobertura de proveedores](docs/PROVIDERS.md)
- [Hoja de ruta](docs/ROADMAP.md)
- [Cómo contribuir](CONTRIBUTING.md) · [Seguridad](SECURITY.md)

## Licencia

[MIT](LICENSE)
