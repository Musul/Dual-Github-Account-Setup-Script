# AGENTS.md

## Asistente de configuración de dos cuentas de GitHub

> **Este archivo es la fuente de verdad del proyecto.** Cualquier agente que trabaje en este repositorio debe leerlo completo antes de modificar código.
>
> **Estado:** implementación v1 disponible en `setup-github.ps1`, con pruebas automatizadas en `tests/run-tests.ps1`.
>
> **Idioma:** documentación y textos de interfaz en español; código, nombres de funciones y comentarios técnicos en inglés.

---

## 1. Resumen

Construir un asistente interactivo para Windows que configure, desde cero o sobre una instalación existente, dos identidades Git/GitHub en la misma computadora:

- una cuenta personal;
- una cuenta de trabajo;
- una carpeta raíz para cada cuenta;
- una clave SSH ed25519 por cuenta;
- configuración Git por carpeta mediante `includeIf`;
- verificación real contra GitHub;
- apertura automática del navegador para registrar las claves.

Al terminar, cualquier comando Git ejecutado dentro de una carpeta —o de un repositorio dentro de ella— debe usar automáticamente la clave SSH y la identidad correctas, sin que el usuario tenga que acordarse de nada.

El objetivo no es solo generar comandos: el asistente debe ser **seguro, idempotente, verificable y fácil de deshacer**.

---

## 2. Contexto

### 2.1 Entorno objetivo

| Elemento | Valor |
|---|---|
| Sistema operativo | Windows 10/11 |
| Shell principal | PowerShell 5.1 (incluido en Windows) |
| Git | Git for Windows; probado con 2.51 |
| SSH | OpenSSH de Git for Windows y/o OpenSSH de Windows |
| Permisos | Sin administrador |
| Dependencias extra | Ninguna obligatoria |

### 2.2 Situación de partida

Ya existe una configuración manual basada en:

- dos carpetas raíz;
- un archivo `.gitconfig-*` por carpeta;
- `core.sshCommand` apuntando a una clave privada;
- entradas `includeIf` en la configuración global de Git.

El mecanismo es correcto en lo esencial. El asistente lo conserva, pero lo endurece y lo hace repetible.

### 2.3 Hallazgos importantes de la configuración actual

1. **Falta identidad por perfil.** Los archivos `.gitconfig-*` solo definen `core.sshCommand`; no definen `user.name` ni `user.email`. En la práctica, los commits de la carpeta personal pueden heredar la identidad global de trabajo. El asistente debe configurar siempre la identidad de cada perfil.
2. **Falta `IdentitiesOnly=yes`.** Si el agente SSH tiene varias claves cargadas, GitHub puede autenticar con la clave equivocada. El comando SSH debe incluir `-o IdentitiesOnly=yes`.
3. **Las claves privadas están dentro de las carpetas raíz de repositorios.** Es válido, pero no es la ubicación recomendada. La convención segura es `%USERPROFILE%\.ssh`. El asistente debe proponer esa ubicación para instalaciones nuevas y **respetar las claves existentes sin moverlas ni borrarlas sin confirmación**.
4. **`ssh -T git@github.com` devuelve código de salida 1 cuando la autenticación es correcta**, porque GitHub no ofrece shell interactiva. El asistente no debe interpretar ese código como error; debe leer el mensaje `Hi <usuario>!`.
5. **`gitdir/i` se aplica al directorio `.git`, no al working tree.** Con una barra final, Git añade `**`. Esto hace que el patrón funcione para cualquier repositorio cuyo `.git` esté debajo de la raíz, pero siempre hay que verificarlo con un repositorio real.
6. **`includeIf` solo afecta comandos Git.** No afecta a un `ssh` ejecutado directamente ni a herramientas que no lean la configuración de Git.
7. **`GIT_SSH_COMMAND` tiene prioridad sobre `core.sshCommand`.** Si está definida en el entorno, el mecanismo por carpeta puede quedar anulado. El preflight debe detectarlo y avisar.
8. **La configuración global puede estar en más de un archivo.** Git lee `~/.gitconfig` y, si existe, `$XDG_CONFIG_HOME/git/config`. Hay que detectar los archivos efectivos y respaldarlos, no asumir una sola ruta.

---

## 3. Objetivos

### 3.1 Objetivo general

Un solo comando debe dejar lista la configuración de dos cuentas de GitHub, con verificación automática y sin efectos destructivos.

### 3.2 Objetivos específicos

- Detectar el entorno y explicar qué falta antes de cambiar nada.
- Pedir los datos de cada perfil de forma guiada.
- Crear las carpetas raíz si no existen.
- Crear o reutilizar claves SSH sin sobrescribirlas.
- Copiar la clave pública al portapapeles y abrir la página correcta de GitHub.
- Verificar que cada clave autentica contra la cuenta esperada.
- Escribir la configuración Git de cada perfil.
- Vincular cada perfil a su carpeta con `includeIf`.
- Verificar el resultado dentro de un repositorio temporal.
- Hacer backup y permitir rollback.
- Poder ejecutarse de nuevo sin duplicar configuración.
- Ser comprensible para alguien que no domina SSH ni la configuración de Git.

---

## 4. No objetivos

- Automatizar el login de GitHub, 2FA, CAPTCHA o recuperación de cuentas.
- Guardar contraseñas, tokens o passphrases.
- Configurar HTTPS con credenciales.
- Instalar Git silenciosamente o sin consentimiento.
- Modificar los remotes de repositorios existentes.
- Soportar más de dos perfiles en la v1.
- Gestionar claves GPG o commit signing en la v1.
- Garantizar compatibilidad con Linux/macOS en la v1.
- Sustituir a GitHub CLI (`gh`); puede ser una mejora opcional futura.
- Configurar proxies corporativos o conexiones SSH por el puerto 443 en la v1.

---

## 5. Decisiones de diseño

| Tema | Decisión propuesta |
|---|---|
| Plataforma | Windows 10/11 |
| Lenguaje | PowerShell 5.1 |
| Punto de entrada | `setup.cmd` → `setup-github.ps1` |
| Dependencias | Git for Windows; nada más obligatorio |
| Perfiles | Dos fijos en v1: `personal` y `work` |
| Mecanismo | `includeIf "gitdir/i:<raíz>/"` + un archivo de configuración por perfil |
| Clave nueva | `%USERPROFILE%\.ssh\id_ed25519_github_<perfil>` |
| Clave existente | Se detecta y se respeta; no se mueve automáticamente |
| Config nueva | `%USERPROFILE%\.config\git\github-<perfil>.gitconfig` |
| Config existente | Se detecta y se conserva su ubicación |
| Identidad | `user.name` y `user.email` por perfil, siempre |
| Comando SSH | `ssh -i '<clave>' -F /dev/null -o IdentitiesOnly=yes` |
| Navegador | `Start-Process` + portapapeles; login manual |
| Estado | `%LOCALAPPDATA%\DualGithubSetup\state.json`, sin secretos |
| Backups | Carpeta con timestamp antes de escribir |
| Idempotencia | Sí: `--replace-all`, detección de duplicados y reparación |
| UI | Español, pasos numerados, colores, mensajes claros |
| Tests | PowerShell puro; integración real opt-in |

### 5.1 Por qué se conserva el enfoque de `includeIf`

Porque resuelve el problema correctamente:

- no hay que configurar cada repositorio a mano;
- los repositorios nuevos dentro de la raíz heredan la configuración automáticamente;
- no hay que cambiar los remotes ni usar alias de host;
- funciona con `git clone`, `git init`, `git fetch`, `git push`, etc.

### 5.2 Qué se corrige respecto de la configuración manual

| Se conserva | Se corrige |
|---|---|
| `includeIf` por carpeta | Añadir `IdentitiesOnly=yes` |
| `.gitconfig-*` por perfil | Añadir `user.name` y `user.email` |
| `core.sshCommand` con `-i` | Verificar la cuenta real con `ssh -T` |
| Claves ed25519 separadas | Ubicación segura por defecto para claves nuevas |
| Apertura del navegador | Backup, idempotencia y rollback |

### 5.3 Modelo de perfil

Cada perfil tiene estos datos:

| Campo | Ejemplo | Obligatorio |
|---|---|---|
| `id` | `personal` | Sí |
| `label` | `Personal` | Sí |
| `root` | `C:/Users/me/GitHub/personal` | Sí |
| `githubUser` | `mi-usuario` | Sí |
| `commitName` | `Mi Nombre` | Sí |
| `email` | `me@example.com` | Sí |
| `keyPath` | `C:/Users/me/.ssh/id_ed25519_github_personal` | Sí |
| `configPath` | `C:/Users/me/.config/git/github-personal.gitconfig` | Sí |

Reglas:

- `id` único y estable.
- `root` absoluto, normalizado con `/`.
- `root` no puede ser la raíz de una unidad, la carpeta del usuario ni una carpeta demasiado amplia.
- Las dos raíces no pueden estar anidadas entre sí.
- `githubUser` no distingue mayúsculas/minúsculas al comparar.
- Los dos perfiles no deberían compartir el mismo email; si lo hacen, advertir.
- La clave de un perfil no puede ser la misma que la del otro.
- No se guarda ninguna passphrase.

### 5.4 Estructura de la configuración Git

Configuración global:

```ini
[includeIf "gitdir/i:C:/Users/me/GitHub/personal/"]
	path = C:/Users/me/.config/git/github-personal.gitconfig

[includeIf "gitdir/i:C:/Users/me/GitHub/work/"]
	path = C:/Users/me/.config/git/github-work.gitconfig
```

Configuración de cada perfil:

```ini
[core]
	sshCommand = ssh -i 'C:/Users/me/.ssh/id_ed25519_github_personal' -F /dev/null -o IdentitiesOnly=yes
[user]
	name = Mi Nombre
	email = me@example.com
```

Notas:

- La ruta de la clave va entre comillas simples porque Git ejecuta el comando mediante un shell tipo POSIX en Git for Windows.
- `-F /dev/null` evita que la configuración personal de `~/.ssh/config` interfiera con la selección de clave.
- `-o IdentitiesOnly=yes` impide que el agente SSH ofrezca otras claves.
- No se debe añadir `StrictHostKeyChecking=no` a la configuración permanente.
- No se debe definir `core.sshCommand` a nivel global; solo por perfil.
- No se debe usar `url.insteadOf` en la v1.

### 5.5 Ubicación de claves y configuraciones

Para instalaciones nuevas:

- claves en `%USERPROFILE%\.ssh`;
- configuraciones en `%USERPROFILE%\.config\git`;
- raíces de repositorios en una ruta elegida por el usuario, por ejemplo `%USERPROFILE%\GitHub\personal` y `%USERPROFILE%\GitHub\work`.

Para instalaciones existentes:

- detectar las rutas actuales desde `includeIf` y `core.sshCommand`;
- mostrar lo detectado;
- permitir conservar todo como está;
- ofrecer migración solo como acción explícita y con verificación previa.

**Nunca** mover ni borrar una clave privada automáticamente. Si se migra, el orden seguro es: copiar → restringir permisos → actualizar configuración → verificar autenticación → pedir confirmación para borrar la copia antigua.

### 5.6 Passphrase

- La v1 debe funcionar sin passphrase para que el flujo sea rápido.
- Si el usuario decide usar una passphrase, no se almacena en ningún archivo ni log.
- El asistente debe explicar que, con passphrase, Git pedirá la clave cada vez salvo que se cargue en un agente SSH.
- La verificación automática con `BatchMode=yes` solo es fiable con claves sin passphrase o ya cargadas en el agente.
- Si la clave está cifrada, el asistente debe mostrar instrucciones y permitir una verificación manual.

### 5.7 Navegador y registro de claves

El asistente no puede iniciar sesión en GitHub por el usuario. Puede:

- copiar la clave pública al portapapeles;
- abrir `https://github.com/login?return_to=%2Fsettings%2Fssh%2Fnew`;
- abrir directamente `https://github.com/settings/ssh/new` si ya hay sesión;
- mostrar el usuario esperado y pedir confirmación;
- esperar a que el usuario termine;
- verificar con `ssh -T`.

Flujo recomendado por perfil:

1. Mostrar la huella digital y el usuario esperado.
2. Copiar la clave pública.
3. Abrir la página de GitHub.
4. Pedir al usuario que confirme que está en la cuenta correcta.
5. Pedirle que pegue la clave, elija **Authentication Key** y guarde.
6. Esperar a que presione Enter.
7. Ejecutar `ssh -T` y comprobar el saludo.

Si GitHub responde que la clave ya está en uso, explicar que pertenece a otra cuenta y que debe eliminarla allí primero.

### 5.8 Estado y backups

- Estado en `%LOCALAPPDATA%\DualGithubSetup\state.json`.
- Backups en `%LOCALAPPDATA%\DualGithubSetup\backups\<timestamp>\`.
- El estado guarda rutas, usuarios y resultados de verificación; nunca passphrases.
- Antes de escribir: backup de la configuración global efectiva y de los archivos de perfil que se vayan a modificar.
- El rollback preferido es quirúrgico: eliminar solo las entradas `includeIf` gestionadas y restaurar los archivos modificados.
- Si se restaura un backup completo, avisar de que se perderán cambios posteriores.

---

## 6. Flujo de usuario

### Paso 0 — Bienvenida y preflight

Mostrar un banner y comprobar:

- versión de PowerShell;
- Git instalado y versión;
- `ssh` y `ssh-keygen` disponibles;
- `ssh -V` es OpenSSH;
- `GIT_SSH_COMMAND` y `GIT_SSH` no están definidas;
- configuración global existente;
- configuración previa del asistente;
- conexión básica con GitHub (opcional, sin bloquear).

Si falta Git:

- mostrar cómo instalarlo con `winget install --id Git.Git -e`;
- o abrir `https://git-scm.com/download/win`;
- no instalar en silencio.

### Paso 1 — Modo de ejecución

Opciones:

1. **Configuración nueva:** dos perfiles desde cero.
2. **Revisar o reparar la existente:** detectar `includeIf`, claves y configuraciones actuales.
3. **Solo diagnóstico:** no escribe nada.

### Paso 2 — Datos de los perfiles

Para cada perfil, pedir:

- nombre visible del perfil;
- carpeta raíz;
- usuario de GitHub;
- nombre para los commits;
- email para los commits;
- ruta de la clave;
- si desea usar una clave existente o crear una nueva.

Mostrar valores por defecto y validar antes de continuar.

### Paso 3 — Resumen y confirmación

Mostrar una tabla con:

- perfil;
- carpeta raíz;
- usuario de GitHub;
- email;
- ruta de la clave;
- archivo de configuración.

No mostrar la clave privada. Mostrar solo la huella digital si la clave ya existe.

Pedir confirmación explícita antes de escribir.

### Paso 4 — Claves SSH

Para cada perfil:

- si la clave no existe: crearla con `ssh-keygen -t ed25519`;
- si existe: no sobrescribir; mostrar huella y ofrecer usarla, generar otra o abortar;
- restringir permisos de la clave privada;
- verificar que `ssh-keygen -y` puede leerla;
- mostrar la clave pública y copiarla al portapapeles.

### Paso 5 — Registro en GitHub

Para cada perfil:

- abrir el navegador;
- guiar el pegado de la clave;
- esperar confirmación;
- verificar `ssh -T`;
- comprobar que el saludo coincide con el usuario esperado;
- permitir reintentar hasta tres veces;
- si falla, explicar causas probables.

### Paso 6 — Escritura de configuración

Para cada perfil:

- crear el archivo de configuración si no existe;
- escribir `core.sshCommand`, `user.name` y `user.email`;
- conservar otras claves existentes;
- hacer backup antes.

Después:

- añadir o actualizar las entradas `includeIf`;
- eliminar entradas duplicadas o antiguas del mismo perfil;
- no tocar entradas `includeIf` ajenas.

### Paso 7 — Verificación

Para cada perfil:

- crear un repositorio temporal dentro de la raíz;
- comprobar `git config --show-origin --get core.sshCommand`;
- comprobar `git config --show-origin --get user.name`;
- comprobar `git config --show-origin --get user.email`;
- comprobar que el origen es el archivo de perfil correcto;
- comprobar la identidad efectiva con `git var GIT_AUTHOR_IDENT`;
- eliminar el repositorio temporal.

Además:

- crear un repositorio temporal fuera de ambas raíces y comprobar que la configuración de perfil no se aplica;
- comprobar que no se duplicaron entradas `includeIf`;
- comprobar que la configuración global no cambió más allá de lo previsto.

### Paso 8 — Resumen y siguientes pasos

Mostrar:

- perfiles configurados;
- cuentas verificadas;
- rutas de las claves;
- archivos de configuración;
- ubicación de los backups;
- ejemplos de uso;
- cómo deshacer.

Ejemplo:

```powershell
cd "C:\Users\me\GitHub\personal"
git clone git@github.com:mi-usuario/mi-repo.git
```

---

## 7. Requisitos funcionales

| ID | Requisito |
|---|---|
| RF-01 | Detectar Git, OpenSSH, PowerShell y permisos antes de modificar nada. |
| RF-02 | Detectar `GIT_SSH_COMMAND` y `GIT_SSH` y explicar su impacto. |
| RF-03 | Detectar configuraciones `includeIf` existentes. |
| RF-04 | Pedir y validar los datos de dos perfiles. |
| RF-05 | Crear las carpetas raíz si no existen, con confirmación. |
| RF-06 | Crear claves ed25519 sin sobrescribir claves existentes. |
| RF-07 | Copiar la clave pública al portapapeles. |
| RF-08 | Abrir el navegador en la página correcta de GitHub. |
| RF-09 | Verificar la cuenta real mediante `ssh -T`. |
| RF-10 | Escribir `user.name`, `user.email` y `core.sshCommand` por perfil. |
| RF-11 | Añadir o actualizar `includeIf` de forma idempotente. |
| RF-12 | Verificar la configuración dentro de un repositorio temporal. |
| RF-13 | Hacer backup antes de escribir. |
| RF-14 | Permitir rollback quirúrgico. |
| RF-15 | Tener un modo `-Check` de solo lectura. |
| RF-16 | Tener un modo `-DryRun` sin efectos secundarios. |
| RF-17 | Soportar rutas con espacios y acentos. |
| RF-18 | Funcionar sin permisos de administrador. |
| RF-19 | No registrar claves privadas ni passphrases. |
| RF-20 | Ser ejecutable de nuevo para reparar o actualizar. |

---

## 8. Requisitos no funcionales

- **Compatibilidad:** PowerShell 5.1; evitar sintaxis exclusiva de PowerShell 7.
- **Dependencias:** ninguna obligatoria fuera de Git for Windows.
- **Rapidez:** menos de dos minutos en el camino feliz, excluyendo el tiempo del usuario en el navegador.
- **Claridad:** cada error debe explicar qué pasó, por qué y qué hacer.
- **Seguridad:** mínimo privilegio; no ejecutar como administrador.
- **Privacidad:** no subir datos a servicios externos; solo se conecta a GitHub.
- **Portabilidad:** rutas absolutas normalizadas; no asumir una unidad `C:`.
- **Mantenibilidad:** funciones pequeñas, con contracts claros y tests.
- **Accesibilidad:** no depender solo del color; usar etiquetas `[OK]`, `[!]`, `[X]`.
- **Idempotencia:** ejecutar dos veces no debe duplicar configuración.
- **Recuperación:** un fallo no debe dejar la configuración global corrupta.

---

## 9. Arquitectura propuesta

```text
Dual-Github-Account-Setup-Script/
├── AGENTS.md
├── README.md
├── .gitignore
├── setup.cmd
├── setup-github.ps1
├── lib/
│   ├── Ui.ps1
│   ├── Preflight.ps1
│   ├── Paths.ps1
│   ├── GitConfig.ps1
│   ├── Ssh.ps1
│   ├── GitHub.ps1
│   ├── State.ps1
│   └── Wizard.ps1
├── tests/
│   └── run-tests.ps1
├── docs/
│   ├── TROUBLESHOOTING.md
│   └── SECURITY.md
└── examples/
    └── setup.example.json
```

Reglas:

- `setup-github.ps1` es el punto de entrada; carga `lib/*.ps1`.
- La lógica de UI no debe estar mezclada con la lógica de configuración.
- Las funciones que escriben archivos deben aceptar `-WhatIf` o un modo `-DryRun`.
- Los tests deben poder importar las funciones sin ejecutar el asistente.

### 9.1 Funciones principales sugeridas

| Función | Responsabilidad |
|---|---|
| `Assert-Prerequisites` | Comprobar Git, SSH, PowerShell y entorno. |
| `Get-EffectiveGlobalConfigPaths` | Localizar los archivos globales efectivos. |
| `ConvertTo-GitPath` | Normalizar a `/`, sin barra final salvo raíz. |
| `Resolve-ProfileRoot` | Validar y crear la carpeta raíz. |
| `Assert-NoNestedRoots` | Evitar raíces anidadas. |
| `New-SshCommandValue` | Construir el valor de `core.sshCommand` con quoting seguro. |
| `New-GitHubSshKey` | Crear la clave ed25519. |
| `Set-PrivateKeyAcl` | Restringir permisos con `icacls`. |
| `Get-SshKeyFingerprint` | Obtener la huella sin exponer la clave privada. |
| `Test-GitHubSshAuth` | Ejecutar `ssh -T` y parsear el saludo. |
| `Write-ProfileGitConfig` | Escribir las claves gestionadas del perfil. |
| `Set-ManagedIncludeIf` | Añadir, actualizar o eliminar la entrada `includeIf`. |
| `Test-ProfileInRepo` | Verificar la configuración dentro de un repo temporal. |
| `New-SetupBackup` | Crear el backup con timestamp. |
| `Restore-SetupBackup` | Rollback quirúrgico o completo. |
| `Save-SetupState` | Persistir el estado sin secretos. |

---

## 10. Interfaz de línea de comandos

### 10.1 Uso interactivo

```powershell
.\setup.cmd
```

o:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-github.ps1
```

### 10.2 Modos

| Comando | Efecto |
|---|---|
| `.\setup.cmd` | Asistente interactivo completo. |
| `.\setup.cmd -Check` | Diagnóstico de solo lectura. |
| `.\setup.cmd -DryRun` | Muestra lo que haría, sin escribir. |
| `.\setup.cmd -Config .\examples\setup.example.json` | Ejecución guiada por archivo. |
| `.\setup.cmd -NoBrowser` | No abre el navegador; muestra la URL. |
| `.\setup.cmd -Rollback` | Deshace la última configuración gestionada. |
| `.\setup.cmd -Rollback -Force` | Rollback sin confirmaciones interactivas. |

### 10.3 Códigos de salida

| Código | Significado |
|---|---|
| 0 | Éxito |
| 1 | Error o cancelación |
| 2 | `-Check` encontró errores de entorno |

La v1 usa códigos simples. Si en el futuro se necesitan códigos más específicos (autenticación, escritura, verificación), se pueden añadir sin romper los actuales.

---

## 11. Algoritmos y detalles técnicos

### 11.1 Normalización de rutas

- Convertir rutas relativas a absolutas o rechazarlas.
- Resolver `..`.
- Convertir `\` a `/`.
- Eliminar barras finales, excepto en la raíz de una unidad.
- Usar rutas absolutas en `includeIf` y en `core.sshCommand`.
- Rechazar raíces que sean:
  - una unidad completa (`C:/`);
  - la carpeta del usuario (`C:/Users/me`);
  - una carpeta demasiado amplia como `C:/Users`;
- Advertir si la raíz es en sí misma un repositorio Git.
- Advertir si la raíz o la clave están dentro de OneDrive u otra carpeta sincronizada.
- Advertir si las raíces están anidadas.

### 11.2 Construcción de `core.sshCommand`

Valor base:

```text
ssh -i '<clave>' -F /dev/null -o IdentitiesOnly=yes
```

Reglas:

- Normalizar la ruta de la clave a `/`.
- Escapar comillas simples si la ruta las contiene.
- No incluir `BatchMode=yes` en la configuración persistente; sí en las pruebas automáticas.
- No incluir `StrictHostKeyChecking=no` en la configuración persistente.
- Verificar con `ssh -G` que el comando se parsea antes de escribirlo.
- Si el SSH disponible no soporta `-F /dev/null`, usar un archivo de configuración vacío temporal y documentarlo.

### 11.3 Entrada `includeIf`

Construcción:

```text
includeIf.gitdir/i:<raíz>/.path
```

Ejemplo:

```text
includeIf.gitdir/i:C:/Users/me/GitHub/personal/.path
```

Reglas:

- La raíz debe terminar en `/`.
- Usar `git config --global --replace-all` para evitar duplicados.
- Antes de escribir, buscar entradas existentes con el mismo `path` y eliminar las antiguas.
- No eliminar entradas `includeIf` que no pertenezcan al asistente.
- Verificar que el patrón funcione con un repositorio temporal.

### 11.4 Verificación de autenticación

Comando:

```powershell
ssh -T -i "<clave>" -F /dev/null -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 git@github.com
```

Consideraciones:

- El código de salida correcto es `1`.
- El mensaje correcto contiene `Hi <usuario>! You've successfully authenticated`.
- Comparar `<usuario>` con el usuario esperado, sin distinguir mayúsculas.
- Si el mensaje muestra otro usuario, la clave pertenece a otra cuenta.
- Si el mensaje es `Permission denied (publickey)`, la clave no está registrada o no es válida.
- Si hay un error de host key, no continuar automáticamente; mostrar la huella y pedir revisión.
- La primera conexión puede usar `-o StrictHostKeyChecking=accept-new` para añadir `github.com` a `known_hosts`.

### 11.5 Verificación de configuración

Dentro de un repositorio temporal bajo la raíz:

```powershell
git -C <repo-temporal> config --show-origin --get core.sshCommand
git -C <repo-temporal> config --show-origin --get user.name
git -C <repo-temporal> config --show-origin --get user.email
git -C <repo-temporal> var GIT_AUTHOR_IDENT
```

Comprobar:

- el valor de `core.sshCommand` es el esperado;
- el origen (`--show-origin`) es el archivo de perfil correcto;
- `user.name` y `user.email` son los del perfil;
- `git var GIT_AUTHOR_IDENT` contiene el email esperado;
- el repositorio temporal se elimina incluso si hay errores.

Fuera de las raíces:

- crear otro repositorio temporal en `%TEMP%`;
- comprobar que no se aplica ninguno de los dos perfiles;
- comparar con el estado global previo.

### 11.6 Backup y rollback

Backup:

- localizar todos los archivos globales efectivos;
- copiar la configuración global;
- copiar los archivos de perfil que se van a modificar;
- guardar un manifiesto con rutas y fechas;
- si un archivo no existía, registrar que fue creado por el asistente.

Rollback:

- eliminar solo las entradas `includeIf` gestionadas;
- restaurar los archivos de perfil desde el backup;
- si el archivo fue creado por el asistente, eliminarlo;
- no borrar claves privadas salvo que el usuario lo pida explícitamente;
- no intentar borrar claves de GitHub; mostrar el título y la huella para que el usuario las elimine;
- avisar de que un rollback completo puede perder cambios posteriores.

### 11.7 Logs

- Guardar logs en `%LOCALAPPDATA%\DualGithubSetup\logs`.
- Registrar comandos ejecutados y resultados, no secretos.
- Nunca registrar:
  - contenido de claves privadas;
  - passphrases;
  - tokens;
  - contenido completo de `stdin`.
- La clave pública sí puede mostrarse; no es secreta.
- Redactar emails si el usuario lo solicita.

---

## 12. Manejo de errores

| Situación | Comportamiento |
|---|---|
| Git no instalado | Explicar y ofrecer instalación asistida o enlace. |
| PowerShell demasiado antiguo | Detener con instrucciones. |
| `GIT_SSH_COMMAND` definida | Explicar que anula `core.sshCommand`; ofrecer ayuda para quitarla. |
| Clave existente | No sobrescribir; ofrecer usar, generar otra o abortar. |
| Clave ya registrada en otra cuenta | Explicar cómo eliminarla y volver a intentar. |
| `ssh -T` devuelve otro usuario | Fallar; no escribir configuración como verificada. |
| Host key desconocida o cambiada | Mostrar huella; no continuar sin confirmación. |
| Sin conexión a GitHub | Guardar progreso y permitir reintentar. |
| Sin permiso de escritura | Mostrar ruta y sugerir ejecutar como usuario normal. |
| Raíces anidadas | Detener y pedir rutas separadas. |
| Raíz demasiado amplia | Detener o requerir confirmación explícita. |
| Usuario cancela | No dejar archivos corruptos; guardar estado. |
| Fallo al escribir configuración | Restaurar backup y reportar. |

---

## 13. Pruebas

### 13.1 Unitarias

Sin tocar la configuración real del usuario:

- normalización de rutas;
- construcción de `includeIf`;
- construcción de `core.sshCommand` con espacios y comillas;
- detección de raíces anidadas;
- parseo del saludo de GitHub;
- interpretación del código de salida de `ssh -T`;
- lectura y escritura de configuración en archivos temporales;
- idempotencia al aplicar dos veces;
- rollback;
- redacción de logs.

Aislamiento:

```powershell
$env:GIT_CONFIG_GLOBAL = Join-Path $temp "gitconfig"
$env:GIT_CONFIG_SYSTEM = Join-Path $temp "gitconfig-system"
$env:HOME = $temp
```

Nunca ejecutar tests contra `%USERPROFILE%\.gitconfig` real.

### 13.2 Integración

Opt-in, porque requiere red y cuentas reales:

- crear una clave temporal;
- verificar que `ssh -T` devuelve la cuenta esperada;
- crear un repositorio temporal;
- comprobar la configuración efectiva;
- comprobar que un repositorio fuera de la raíz no hereda el perfil.

### 13.3 Matriz manual

- instalación nueva;
- reparación de una instalación existente;
- re-ejecución;
- clave equivocada;
- cuenta equivocada;
- sin red;
- ruta con espacios;
- ruta con acentos;
- clave con passphrase;
- Git no instalado;
- raíz inexistente;
- raíces anidadas;
- cancelación a mitad de flujo;
- rollback.

---

## 14. Criterios de aceptación

La v1 se considera terminada cuando:

1. En una máquina Windows con Git instalado, `setup.cmd` completa el flujo y deja dos perfiles funcionales.
2. Cada clave autentica contra la cuenta correcta y el asistente lo verifica con `ssh -T`.
3. Dentro de un repositorio bajo cada raíz:
   - `core.sshCommand` incluye la clave correcta y `IdentitiesOnly=yes`;
   - `user.name` y `user.email` son los del perfil;
   - el origen de la configuración es el archivo de perfil correcto.
4. Fuera de las raíces, la configuración de perfil no se aplica.
5. Ejecutar dos veces no duplica entradas `includeIf`.
6. Existe un backup antes de cada escritura.
7. `-Check` funciona sin escribir nada.
8. `-DryRun` no modifica ningún archivo.
9. El rollback elimina solo lo gestionado y restaura lo modificado.
10. No aparece ninguna clave privada ni passphrase en logs, consola o repositorio.
11. Una clave de la cuenta A usada en el perfil B produce un error claro y no se marca como verificada.
12. El asistente funciona sin permisos de administrador.
13. Las rutas con espacios funcionan.
14. La documentación explica cómo verificar y cómo deshacer.

---

## 15. Plan de implementación

### Milestone 0 — Especificación

- [x] Crear `AGENTS.md`.
- [x] Confirmar las decisiones abiertas de la sección 17.
- [x] Crear `README.md` inicial.

### Milestone 1 — Base y diagnóstico

- [x] Preflight.
- [x] Localización de la configuración global efectiva.
- [x] Normalización y validación de rutas.
- [x] Modo `-Check`.
- [x] Tests unitarios de la base.

### Milestone 2 — Perfiles y claves

- [x] Entrada interactiva de datos.
- [x] Validaciones.
- [x] Creación y reutilización de claves.
- [x] ACL de la clave privada.
- [x] Huellas digitales.
- [x] Tests de claves.

### Milestone 3 — GitHub

- [x] Portapapeles.
- [x] Apertura del navegador.
- [x] Guía de registro.
- [x] `ssh -T` y parseo del saludo.
- [x] Reintentos y mensajes de error.
- [x] Modo `-NoBrowser`.

### Milestone 4 — Configuración Git

- [x] Escritura de archivos de perfil.
- [x] `includeIf` idempotente.
- [x] Backups.
- [x] Rollback.
- [x] Tests de configuración.

### Milestone 5 — Verificación y acabado

- [x] Repositorios temporales de verificación.
- [x] Resumen final.
- [x] Logs redactados.
- [x] Documentación de troubleshooting.
- [x] Pruebas manuales en Windows.
- [x] Revisión de seguridad.

### Milestone 6 — Extras opcionales

- [ ] Integración con `gh`.
- [ ] Commit signing.
- [ ] Más de dos perfiles.
- [ ] Soporte para SSH por puerto 443.
- [ ] Migración asistida de claves.

---

## 16. Convenciones para agentes

- Leer este archivo completo antes de empezar.
- No ejecutar comandos destructivos contra la configuración real del usuario.
- No imprimir claves privadas, tokens ni passphrases.
- No hardcodear rutas, emails o nombres reales en el código ni en los tests.
- Usar placeholders en ejemplos y documentación.
- Mantener compatibilidad con PowerShell 5.1.
- Guardar los `.ps1` con acentos como UTF-8 con BOM, o evitar acentos en el código.
- Usar `Set-StrictMode -Version Latest`.
- Usar `$ErrorActionPreference = 'Stop'` para cmdlets, pero manejarlo con cuidado alrededor de comandos nativos.
- Comprobar `$LASTEXITCODE` después de cada comando nativo.
- No confiar en el stderr de PowerShell 5.1 para detectar fallos de comandos nativos.
- Usar `-LiteralPath` en operaciones de archivos.
- No usar `Invoke-Expression`.
- No añadir dependencias sin aprobación.
- No cambiar la identidad global de Git salvo que el usuario lo pida.
- No modificar repositorios existentes ni sus remotes.
- Actualizar `README.md`, `docs/` y tests cuando cambie el comportamiento.
- Mantener los mensajes de UI en español y el código en inglés.
- Preferir funciones pequeñas y testeables.
- Añadir comentarios solo donde aporten contexto; evitar comentarios obvios.
- Si algo no está claro, preguntar antes de asumir.

### 16.1 Estilo de código

- Verbos aprobados de PowerShell (`Get-`, `Set-`, `New-`, `Test-`, `Remove-`, `Invoke-`).
- Nombres de funciones en inglés.
- Variables en inglés.
- Mensajes de usuario en español.
- Evitar abreviaturas innecesarias.
- Devolver objetos, no texto formateado, desde la lógica.
- La UI se encarga de formatear.

### 16.2 Seguridad

- Mínimo privilegio.
- No ejecutar como administrador.
- No desactivar la verificación de host keys de forma permanente.
- No guardar secretos.
- No registrar el contenido de claves privadas.
- Restringir permisos de la clave privada.
- Hacer backup antes de escribir.
- Pedir confirmación para acciones destructivas.
- No borrar claves de GitHub automáticamente.

---

## 17. Decisiones confirmadas

El usuario confirmó los valores propuestos para la v1:

- Stack: PowerShell 5.1.
- Claves nuevas en `%USERPROFILE%\.ssh`.
- Configuraciones nuevas en `%USERPROFILE%\.config\git`.
- Passphrase vacía por defecto, con advertencia.
- Sin `gh` en la v1.
- Dos perfiles.
- Interfaz en español.
- Migración de claves existentes manual y con verificación asistida.
- Raíces nuevas en `%USERPROFILE%\GitHub\<perfil>`.
- Commit signing fuera de la v1.



---

## 18. Referencias

- Git — Conditional includes: <https://git-scm.com/docs/git-config#_conditional_includes>
- Git — `core.sshCommand`: <https://git-scm.com/docs/git-config#Documentation/git-config.txt-coresshCommand>
- GitHub — Connecting to GitHub with SSH: <https://docs.github.com/en/authentication/connecting-to-github-with-ssh>
- GitHub — Adding a new SSH key: <https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account>
- GitHub — SSH key types: <https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent>
- OpenSSH — `ssh(1)`: <https://man.openbsd.org/ssh>
- Git for Windows: <https://gitforwindows.org/>

---

## 19. Definición de "listo" para esta fase

- [x] Especificación inicial creada.
- [x] Decisiones confirmadas.
- [x] Implementación v1 completada.
- [x] Tests automatizados pasando.
- [ ] Prueba real de instalación desde cero con dos cuentas de GitHub completada.
- [x] Documentación de usuario lista.
