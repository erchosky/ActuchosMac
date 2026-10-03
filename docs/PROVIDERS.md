# Cobertura de proveedores

| Proveedor | Detección | Comprobación remota | Actualización | Notas |
|---|---|---|---|---|
| Apple Software Update | Versión de macOS | `softwareupdate --list` | Componentes (CLT, Safari…): `softwareupdate --install` con el diálogo de macOS. macOS: abre Ajustes | Cada componente es un elemento propio |
| Homebrew | `brew list`, `brew leaves` | `brew update` + `brew outdated --json=v2` | `brew upgrade [--cask]` | Marca dependencias; excluye `brew pin`; `--greedy` opcional |
| Mac App Store | `mas list` | `mas outdated` | `mas upgrade <id>` | Sin `mas`, ofrece `brew install mas` |
| Aplicaciones | Bundles en `/Applications`, `~/Applications`, `/System/Applications` | Sparkle, electron-updater o catálogo de casks de Homebrew | Descarga verificada (ver arquitectura) | Detecta recibos de la App Store, casks, Sparkle, Squirrel, Mozilla, Google, Microsoft, Adobe y JetBrains |
| NVM / Node | `$NVM_DIR/versions/node` + shell de inicio | `nvm version-remote <major>` | `nvm install <major> --reinstall-packages-from=<actual>` | Nunca cambia de versión mayor |
| npm / Corepack / pnpm | Shell de inicio | `npm view <tool>@<major>` | `npm install -g` / `corepack install -g` | El npm de Homebrew se deja a Homebrew |
| Paquetes npm globales | `npm ls -g` | `npm outdated -g` | `npm install -g pkg@versión` | |
| Paquetes pip | `pip list --not-required` en cada Python | `pip list --outdated` | `pip install --upgrade pkg==versión` | En Pythons PEP 668 usa `--break-system-packages`, salvo pip/setuptools/wheel |
| pipx / uv tool | `pipx list --json`, `uv tool list` | PyPI | `pipx upgrade`, `uv tool upgrade` | |
| Gems de Ruby | `gem outdated` | Incluida | `gem update` | Se omite el Ruby del sistema |
| cargo install | `cargo install --list` | crates.io | `cargo install <crate> --version <v>` | |
| rustup | `rustup check` | Incluida | `rustup update <toolchain>`, `rustup self update` | |
| Python | PATH, pyenv, python.org, CLT | Gestor dueño | No | Los Python de Homebrew los lista Homebrew |
| .NET | `dotnet --list-sdks/--list-runtimes` | Vía Homebrew si es un cask | No | |
| Ollama | App, binario y `ollama list` | Releases de GitHub | App: descarga verificada. Modelos: `ollama pull` opcional | No se sabe si un modelo es nuevo sin descargarlo |
| Editores | VS Code, Insiders, Cursor, Windsurf, VSCodium, Antigravity | API de VS Code o catálogo de Homebrew | Descarga verificada; extensiones con `--update-extensions` | |
| Herramientas | Bun, Deno, uv, Composer, Go, fnm, Volta, pyenv, rbenv, PHP, Ruby, Java… | GitHub releases, go.dev, getcomposer.org | `bun upgrade`, `deno upgrade`, `uv self update`, `composer self-update` | El resto enlaza a las instrucciones oficiales |

## Añadir un proveedor

1. Implementa `UpdateProvider`. Solo `detect` es obligatorio: `check`, `update` y `verify` tienen implementaciones por defecto seguras.
2. `detect` debe ser local y rápido; deja las consultas de red para `check`.
3. Activa `canUpdateAutomatically` solo si el comando de actualización está documentado, no es interactivo y se puede verificar.
4. Usa una `deduplicationKey` estable y un `MetadataKey.lock` para lo que no deba ejecutarse a la vez. En los elementos respaldados por un `.app`, rellena `MetadataKey.appPath` para que el bundle se fusione y no salga dos veces.
5. Regístralo en `UpdateStore.init` y añade tests de parseo con salidas sintéticas.
