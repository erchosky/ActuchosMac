# Cómo contribuir

Gracias por ayudar a mejorar ActuchosMac.

1. La detección es de solo lectura; las actualizaciones solo ocurren cuando el usuario las pide.
2. Añade un proveedor solo si su mecanismo de actualización está documentado, no es interactivo y se puede verificar (ver [docs/PROVIDERS.md](docs/PROVIDERS.md)).
3. Nada de scripts remotos con una tubería al shell, credenciales embebidas, rutas personales ni cambios en las dependencias de proyectos.
4. Pasa los datos del inventario a los comandos como argumentos separados, nunca interpolados en un shell.
5. Las descargas de apps deben pasar por `AppInstaller`: HTTPS, hash o firma publicada cuando exista, mismo Team ID y Gatekeeper.
6. Añade tests con mocks para el parseo, los fallos, la deduplicación del plan y la verificación. Los tests nunca deben ejecutar actualizaciones reales.
7. Mejor «no comprobado» que un «al día» falso.

Antes de abrir un pull request, ejecuta:

```sh
xcodebuild -project ActuchosMac.xcodeproj -scheme ActuchosMac -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```
