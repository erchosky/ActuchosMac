# Política de seguridad

ActuchosMac ejecuta gestores de paquetes y herramientas del sistema, y reemplaza aplicaciones, así que cualquier cambio en los proveedores o en el instalador requiere una revisión conservadora.

## Versiones con soporte

Solo la última versión de la rama `main` recibe correcciones.

## Cómo informar de una vulnerabilidad

Usa el **informe privado de vulnerabilidades** de GitHub (Security › Report a vulnerability) en lugar de un issue público. Incluye el proveedor afectado, la frontera de comandos implicada, la versión, una reproducción con datos sintéticos y el comportamiento seguro esperado. No incluyas credenciales reales ni tu inventario personal.

## Reglas innegociables

- No guardar, pedir ni automatizar contraseñas de administrador. Lo que requiera privilegios usa el diálogo del propio macOS.
- No ejecutar scripts descargados mediante una tubería al shell.
- No desactivar SIP, Gatekeeper, la comprobación de firmas de código ni otras protecciones del sistema.
- Reemplazar una app solo con una descarga HTTPS que tenga una firma de código válida del **mismo Team ID**, que Gatekeeper acepte y, cuando el fabricante lo publique, cuyo hash o firma EdDSA coincida. La versión anterior va siempre a la Papelera.
- No concatenar datos del inventario en comandos de shell.
- No incluir tokens, credenciales, rutas personales ni información privada del equipo en fixtures ni en logs versionados.
