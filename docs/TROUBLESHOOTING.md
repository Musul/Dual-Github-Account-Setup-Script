# Solución de problemas

## Primero: diagnóstico

Ejecuta:

```powershell
.\setup.cmd -Check
```

El diagnóstico no modifica nada. Revisa:

- la clave y su huella;
- si el perfil tiene `user.name` y `user.email`;
- si `core.sshCommand` incluye `IdentitiesOnly=yes`;
- el resultado de `ssh -T`;
- la identidad global.

---

## Git no está instalado

Instálalo con winget:

```powershell
winget install --id Git.Git -e --source winget
```

O descárgalo de:

<https://git-scm.com/download/win>

Cierra y vuelve a abrir la terminal después de instalarlo para que `git` esté en `PATH`.

---

## OpenSSH no está disponible

Windows 10/11 suele incluir OpenSSH Client, pero puede estar desactivado. Instálalo desde:

**Settings > Apps > Optional Features > OpenSSH Client**

O con PowerShell como administrador:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

Después comprueba:

```powershell
ssh -V
Get-Command ssh-keygen
```

---

## El asistente dice que no se ejecute como administrador

Cierra la terminal elevada y abre una sesión normal de Windows. El asistente crea claves y configuración en tu perfil; ejecutarlo como administrador puede dejar archivos con permisos del administrador y romper el acceso posterior.

`-Check` sí se puede ejecutar como administrador si solo necesitas diagnóstico.

---

## `Permission denied (publickey)`

Significa que GitHub no aceptó la clave. Causas habituales:

1. La clave pública no está registrada en GitHub.
2. La clave está registrada en otra cuenta.
3. Se está usando otra clave por culpa del agente SSH.
4. La ruta de la clave es incorrecta.
5. El archivo privado no tiene permisos válidos.

Comprueba la huella que estás usando:

```powershell
ssh-keygen -l -f "C:\Users\me\.ssh\id_ed25519_github_personal"
```

Comprueba la autenticación:

```powershell
ssh -T -i "C:\Users\me\.ssh\id_ed25519_github_personal" -F /dev/null -o IdentitiesOnly=yes git@github.com
```

Si el mensaje es `Hi otro-usuario!`, la clave pertenece a otra cuenta. Elimínala de esa cuenta en GitHub y agrégala a la correcta.

---

## La clave autentica como la cuenta equivocada

Cada clave SSH solo puede estar registrada en una cuenta de GitHub.

1. Entra en GitHub con la cuenta incorrecta.
2. Ve a **Settings > SSH and GPG keys**.
3. Elimina la clave.
4. Entra con la cuenta correcta.
5. Agrégala de nuevo.
6. Ejecuta el diagnóstico o vuelve a ejecutar el asistente.

El asistente incluye `IdentitiesOnly=yes` justamente para evitar que el agente ofrezca otras claves. Si el problema continúa, revisa si `GIT_SSH_COMMAND` está definida.

---

## `ssh -T` devuelve código 1

Es normal. GitHub no ofrece shell interactiva y devuelve código `1` incluso cuando la autenticación es correcta. Lo importante es el mensaje:

```text
Hi tu-usuario! You've successfully authenticated, but GitHub does not provide shell access.
```

No interpretes el código como fallo.

---

## `GIT_SSH_COMMAND` anula la configuración

Git da prioridad a `GIT_SSH_COMMAND` sobre `core.sshCommand`. Si está definida, los perfiles por carpeta no funcionarán.

Comprueba:

```powershell
$env:GIT_SSH_COMMAND
$env:GIT_SSH
```

Para quitarla solo en la sesión actual:

```powershell
Remove-Item Env:GIT_SSH_COMMAND -ErrorAction SilentlyContinue
Remove-Item Env:GIT_SSH -ErrorAction SilentlyContinue
```

Si está definida de forma permanente en el sistema o en tu perfil de PowerShell, tendrás que quitarla desde allí.

---

## Passphrase y ssh-agent

Si la clave tiene passphrase, Git pedirá la contraseña cada vez que use la clave, salvo que esté cargada en un agente SSH.

En Git Bash:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519_github_personal
```

En Windows, el servicio **OpenSSH Authentication Agent** puede gestionar claves, pero no todas las instalaciones de Git lo usan de la misma manera. Si tienes problemas, la opción más simple es usar una clave sin passphrase protegida con permisos de archivo y cifrado de disco.

El asistente no guarda passphrases.

---

## `Host key verification failed`

Puede ser una clave de host desconocida o un cambio real. No desactives la verificación permanentemente.

Comprueba la huella publicada por GitHub:

<https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints>

Si la huella coincide, elimina la entrada antigua:

```powershell
ssh-keygen -R github.com
```

Y vuelve a conectar. Si no coincide, no continúes.

---

## La configuración no se aplica dentro de la carpeta

Comprueba que estás dentro de un repositorio y que el `.git` está debajo de la raíz:

```powershell
git rev-parse --show-toplevel
git config --show-origin --get core.sshCommand
git config --show-origin --get user.email
```

Recuerda:

- `includeIf` se aplica al directorio `.git`, no al directorio actual.
- Un repo clonado fuera de la raíz no hereda el perfil.
- Un `ssh` directo no lee la configuración de Git.
- Un remoto HTTPS no usa SSH.

Si cambiaste la carpeta raíz de un perfil, revisa si quedó una entrada `includeIf` antigua:

```powershell
git config --global --get-regexp '^includeIf\.gitdir/i:.*\.path$'
```

Puedes eliminarla con:

```powershell
git config --global --unset-all "includeIf.gitdir/i:RUTA_ANTIGUA/.path"
```

---

## VS Code, GitHub Desktop e IDEs

- **VS Code** usa el Git del sistema para la mayoría de operaciones; la terminal integrada y el panel Source Control suelen respetar `core.sshCommand`.
- **GitHub Desktop** usa su propio Git empaquetado y puede tener configuración propia. Verifica que esté usando el Git del sistema o configura la clave en la herramienta.
- **JetBrains** y otros IDEs normalmente usan el Git del sistema.

Si una herramienta gráfica no respeta el perfil, usa la terminal para esa operación o revisa la configuración SSH de la herramienta.

---

## Rutas con espacios o acentos

El asistente normaliza las rutas a `/` y usa comillas simples en `core.sshCommand`. Si una herramienta externa falla con una ruta con espacios, prueba a mover la raíz o la clave a una ruta más simple.

No uses la raíz de una unidad (`C:/`) ni tu carpeta de usuario completa como raíz de repositorios.

---

## `-F /dev/null` y la configuración de `~/.ssh/config`

El asistente usa `-F /dev/null` para que la configuración de `~/.ssh/config` no interfiera con la clave seleccionada. Es intencional.

Si necesitas `ProxyCommand`, un host alias o una configuración corporativa en `~/.ssh/config`, esa configuración no se aplicará dentro de los perfiles. En ese caso, revisa tu caso con TI o adapta el comando SSH manualmente.

---

## Proxy corporativo o puerto 22 bloqueado

La configuración del asistente usa el puerto SSH estándar (22). Si tu red bloquea ese puerto:

- consulta con el equipo de TI;
- GitHub también ofrece SSH por el puerto 443 en `ssh.github.com`;
- esa variante requiere configuración adicional y no está incluida en la v1.

No desactives la verificación de host keys para “hacer que funcione”.

---

## Submódulos y Git LFS

Los submódulos y Git LFS pueden invocar SSH por su cuenta. Si usas esas funciones:

1. Verifica que el repositorio principal y los submódulos estén dentro de la raíz correcta.
2. Prueba un `git clone` y un `git lfs pull`.
3. Si LFS no respeta la configuración, revisa su documentación y variables de entorno.

---

## OneDrive y carpetas sincronizadas

No guardes claves privadas en OneDrive, Dropbox u otra carpeta sincronizada. El asistente avisa si detecta que una raíz o una clave están en una ruta sincronizada.

La ubicación recomendada para claves es:

```text
%USERPROFILE%\.ssh
```

---

## Deshacer la configuración

```powershell
.\setup.cmd -Rollback
```

El rollback:

- elimina las entradas `includeIf` que apuntan a los perfiles gestionados;
- restaura los archivos de perfil desde el backup;
- elimina los archivos de perfil que el asistente creó;
- no borra claves privadas;
- no borra claves de GitHub.

Si el rollback no encuentra el estado, revisa los backups en:

```text
%LOCALAPPDATA%\DualGithubSetup\backups
```

---

## Revisar el log

Los logs se guardan en:

```text
%LOCALAPPDATA%\DualGithubSetup\logs
```

No contienen claves privadas ni passphrases. Aun así, pueden contener rutas y emails; no los publiques sin revisarlos.
