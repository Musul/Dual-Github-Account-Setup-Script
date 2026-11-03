# Dual GitHub Account Setup

**Configura dos cuentas de GitHub en la misma computadora Windows, cada una asociada a su propia carpeta.** El asistente crea o reutiliza una clave SSH por cuenta y deja preparada la configuración de Git para que los repositorios de cada carpeta usen automáticamente la clave y la identidad correctas.

**No tienes que configurar cada repositorio a mano.** El asistente detecta configuraciones existentes, pide los datos que falten, abre GitHub para registrar las claves, escribe `includeIf`, `core.sshCommand`, `user.name` y `user.email` por perfil, y verifica el resultado con un repositorio temporal. También incluye diagnóstico, simulación, backup y rollback.

> Proyecto no afiliado a GitHub.

---

## Uso rápido

Requisitos: Windows 10/11, PowerShell 5.1 o superior, Git for Windows con OpenSSH y dos cuentas de GitHub.

```powershell
git clone https://github.com/Musul/Dual-Github-Account-Setup-Script.git
cd Dual-Github-Account-Setup-Script

# Diagnóstico, no modifica nada
.\setup.cmd -Check

# Configuración guiada
.\setup.cmd
```

Durante el asistente:

1. Elige **revisar/reparar** si ya tienes una configuración, o **crear una nueva**.
2. Indica la carpeta raíz, el usuario de GitHub, el nombre y el email de cada perfil.
3. Registra cada clave pública en la cuenta correcta cuando se abra el navegador.
4. El asistente verifica la autenticación y la configuración final.

No ejecutes el asistente como administrador.

---

## Modos

| Comando | Para qué sirve |
|---|---|
| `.\setup.cmd` | Asistente interactivo completo. |
| `.\setup.cmd -Check` | Diagnóstico de solo lectura. |
| `.\setup.cmd -DryRun` | Muestra lo que haría sin modificar nada. |
| `.\setup.cmd -Config .\examples\setup.example.json -Force` | Ejecuta desde un JSON. |
| `.\setup.cmd -Rollback` | Deshace la última configuración gestionada. |

`-Rollback` elimina las entradas `includeIf` gestionadas y restaura los archivos de perfil desde el backup. No borra claves privadas ni claves de GitHub.

---

## Qué hace

- Crea una clave SSH ed25519 por cuenta si no existe; nunca sobrescribe una clave existente.
- Restringe los permisos de la clave privada.
- Añade `user.name` y `user.email` a cada perfil para evitar commits con la identidad equivocada.
- Configura `core.sshCommand` con `-F /dev/null` e `IdentitiesOnly=yes`.
- Vincula cada carpeta raíz con su perfil mediante `includeIf`.
- Comprueba que cada clave autentica contra la cuenta esperada.
- Verifica la configuración dentro de un repositorio temporal.
- Guarda estado, logs y backups en `%LOCALAPPDATA%\DualGithubSetup`.

Las claves nuevas se guardan por defecto en `%USERPROFILE%\.ssh` y las configuraciones en `%USERPROFILE%\.config\git`. Las claves existentes se respetan y no se mueven.

---

## Seguridad

- No almacena contraseñas, tokens ni passphrases.
- No imprime claves privadas.
- No automatiza el login de GitHub ni evade 2FA.
- No desactiva la verificación de host keys de forma permanente.
- No cambia la identidad global de Git ni los remotes de tus repositorios.
- Rechaza ejecutarse como administrador.

Más detalles en [docs/SECURITY.md](docs/SECURITY.md).

---

## Documentación

- [Solución de problemas](docs/TROUBLESHOOTING.md)
- [Seguridad](docs/SECURITY.md)
- [Especificación y decisiones de diseño](AGENTS.md)
- [Ejemplo de configuración JSON](examples/setup.example.json)

---

## Pruebas

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Las pruebas usan una configuración global temporal y un SSH simulado; no tocan tu configuración real ni necesitan cuentas de GitHub.
