# Configurador de dos cuentas de GitHub

Asistente para Windows que deja configuradas dos identidades Git/GitHub en la misma computadora:

- una cuenta personal;
- una cuenta de trabajo;
- una carpeta raíz para cada cuenta;
- una clave SSH ed25519 por cuenta;
- configuración Git automática por carpeta mediante `includeIf`;
- verificación real contra GitHub;
- apertura del navegador para registrar las claves;
- backup y rollback.

Al terminar, cualquier comando Git dentro de una carpeta —o de un repositorio dentro de ella— usa automáticamente la clave SSH correcta y la identidad correcta.

> Este proyecto no está afiliado a GitHub.

---

## Requisitos

- Windows 10 u 11.
- PowerShell 5.1 o superior (incluido en Windows).
- Git for Windows con OpenSSH (`ssh.exe` y `ssh-keygen.exe`).
- Dos cuentas de GitHub.
- Acceso a internet para verificar las claves.

No hace falta ejecutar como administrador. El asistente rechaza las sesiones elevadas para evitar crear claves y configuración con permisos incorrectos.

---

## Inicio rápido

Desde PowerShell o CMD, en la carpeta del proyecto:

```powershell
.\setup.cmd
```

El asistente te guía por estos pasos:

1. Comprueba el entorno.
2. Detecta una configuración anterior, si existe.
3. Pide los datos de los dos perfiles.
4. Crea o reutiliza las claves SSH.
5. Abre GitHub para registrar cada clave.
6. Escribe la configuración Git.
7. Verifica la configuración dentro de un repositorio temporal.
8. Muestra un resumen y cómo deshacer.

### Diagnóstico

```powershell
.\setup.cmd -Check
```

No modifica la configuración. Muestra:

- perfiles detectados;
- clave y huella digital;
- identidad configurada;
- estado de `IdentitiesOnly`;
- resultado de `ssh -T`;
- identidad global de Git.

### Simulación

```powershell
.\setup.cmd -DryRun
```

Muestra lo que haría sin crear claves, carpetas ni configuración.

### Configuración desde JSON

```powershell
.\setup.cmd -Config .\examples\setup.example.json -Force
```

El archivo de ejemplo usa rutas y cuentas ficticias. Cópialo, edítalo y ejecútalo.

`-Force` omite la confirmación del plan, pero el registro de claves en GitHub sigue siendo manual. Si las claves ya están registradas, usa `-NoBrowser` para evitar que se abra el navegador.

### Rollback

```powershell
.\setup.cmd -Rollback
```

Elimina las entradas `includeIf` gestionadas y restaura los archivos de perfil desde el backup. No borra claves privadas ni claves de GitHub.

Si usaste un `-StatePath` personalizado, pasa la misma ruta al rollback.

### Ayuda

```powershell
.\setup.cmd -Help
```

---

## Cómo funciona

Cada perfil tiene su propio archivo de configuración Git:

```ini
[core]
	sshCommand = ssh -i 'C:/Users/me/.ssh/id_ed25519_github_personal' -F /dev/null -o IdentitiesOnly=yes
[user]
	name = Mi Nombre
	email = me@example.com
```

La configuración global de Git incluye ese archivo solo cuando el repositorio está dentro de la carpeta raíz:

```ini
[includeIf "gitdir/i:C:/Users/me/GitHub/personal/"]
	path = C:/Users/me/.config/git/github-personal.gitconfig
```

`gitdir/i` hace la comparación sin distinguir mayúsculas. El patrón termina en `/`, por lo que Git añade `**` y aplica a cualquier repositorio cuyo directorio `.git` esté debajo de esa raíz.

### Por qué `IdentitiesOnly=yes`

Sin esa opción, si el agente SSH tiene varias claves, GitHub podría autenticar con la clave equivocada. `-i` indica la clave y `IdentitiesOnly=yes` impide que se ofrezcan otras.

### Por qué `-F /dev/null`

Evita que la configuración personal de `~/.ssh/config` interfiera con la selección de clave. Es intencional: cada perfil debe usar exactamente su clave.

### Limitaciones

- `includeIf` afecta a los comandos Git, no a un `ssh` ejecutado directamente.
- `GIT_SSH_COMMAND` tiene prioridad sobre `core.sshCommand`; el asistente avisa si está definida.
- Los repositorios con remotos HTTPS no usan SSH.
- Algunas herramientas gráficas pueden no respetar `core.sshCommand`; usa la terminal o revisa la configuración de la herramienta.
- Un proxy corporativo o el bloqueo del puerto 22 pueden requerir configuración adicional.
- La versión actual está pensada para dos perfiles.

---

## Qué modifica en la computadora

- Crea las carpetas raíz que falten.
- Crea claves SSH si no existen. Nunca sobrescribe una clave existente.
- Restringe los permisos de la clave privada con `icacls`.
- Crea o actualiza los archivos de configuración de cada perfil.
- Añade o actualiza entradas `includeIf` en la configuración global de Git.
- Guarda estado y backups en:

```text
%LOCALAPPDATA%\DualGithubSetup\
```

No cambia la identidad global de Git ni los remotes de tus repositorios.

---

## Verificación manual

Dentro de un repositorio que esté debajo de una raíz:

```powershell
git config --show-origin --get core.sshCommand
git config --show-origin --get user.name
git config --show-origin --get user.email
```

Deberías ver el archivo de perfil correcto y el comando SSH con la clave correcta.

También puedes probar la clave directamente:

```powershell
ssh -T -i "C:\Users\me\.ssh\id_ed25519_github_personal" -F /dev/null -o IdentitiesOnly=yes git@github.com
```

GitHub responde con un mensaje parecido a:

```text
Hi tu-usuario! You've successfully authenticated, but GitHub does not provide shell access.
```

El código de salida es `1` cuando la autenticación es correcta. No es un error.

---

## Seguridad

- Las claves nuevas se guardan por defecto en `%USERPROFILE%\.ssh`.
- Las configuraciones nuevas se guardan por defecto en `%USERPROFILE%\.config\git`.
- Las claves privadas nunca se imprimen, se registran ni se suben.
- Las passphrases no se guardan.
- El asistente no automatiza el login de GitHub ni pide contraseñas.
- No se desactiva la verificación de host keys de forma permanente.
- Los backups pueden contener emails y rutas; trátalos como información personal.

Más detalles en [docs/SECURITY.md](docs/SECURITY.md).

---

## Solución de problemas

Consulta [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) para:

- `Permission denied (publickey)`;
- clave asociada a la cuenta equivocada;
- passphrase y ssh-agent;
- `GIT_SSH_COMMAND`;
- host key desconocida;
- VS Code, GitHub Desktop e IDEs;
- rutas con espacios;
- proxy o puerto 443.

---

## Pruebas

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Las pruebas usan un `GIT_CONFIG_GLOBAL` temporal y no tocan la configuración real del usuario. El flujo completo se prueba con un `ssh` simulado para no depender de cuentas reales.

---

## Estructura

```text
setup.cmd
setup-github.ps1
lib/
  Ui.ps1
  Paths.ps1
  GitConfig.ps1
  Ssh.ps1
  GitHub.ps1
  State.ps1
  Preflight.ps1
  Wizard.ps1
tests/
  run-tests.ps1
examples/
  setup.example.json
docs/
  TROUBLESHOOTING.md
  SECURITY.md
```

La especificación completa y las decisiones de diseño están en [AGENTS.md](AGENTS.md).
