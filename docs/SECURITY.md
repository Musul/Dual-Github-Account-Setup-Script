# Seguridad

Este documento explica qué protege el asistente, qué no protege y qué debes revisar antes de usarlo en una computadora compartida.

---

## Modelo de seguridad

El asistente asume que:

- la computadora es de uso personal o está protegida con una cuenta de Windows;
- el usuario tiene acceso a su propia cuenta y a su propio perfil;
- GitHub es el único servicio externo con el que se comunica;
- el usuario revisa las URLs y las cuentas antes de pegar una clave pública.

No asume que la computadora esté libre de malware. Una clave SSH privada puede ser leída por cualquier proceso que se ejecute con tu usuario de Windows.

---

## Claves privadas

- Se generan con `ssh-keygen -t ed25519`.
- Por defecto se guardan en `%USERPROFILE%\.ssh`.
- Nunca se imprimen en la consola.
- Nunca se escriben en logs.
- Nunca se envían a GitHub; solo se envía la clave pública.
- No se sobrescribe una clave existente sin confirmación.
- Se restringen los permisos con `icacls` para que solo tu usuario pueda leerlas.

Una clave privada sin passphrase sigue siendo sensible. Debe estar protegida por:

- permisos NTFS correctos;
- una cuenta de Windows con contraseña;
- cifrado de disco (BitLocker o equivalente);
- ausencia de malware.

En una computadora compartida, usa una passphrase y un agente SSH.

---

## Claves públicas

La clave pública no es secreta. Se copia al portapapeles y se muestra para que puedas pegarla en GitHub. Puede aparecer en logs o en la consola sin riesgo directo.

---

## Passphrases

- El asistente no almacena passphrases.
- Si eliges una passphrase, `ssh-keygen` la solicita directamente.
- Git la pedirá en cada operación salvo que la clave esté cargada en un agente SSH.
- El asistente no puede recuperar una passphrase olvidada.

---

## Host keys

El asistente no desactiva la verificación de host keys de forma permanente.

- En el flujo normal, la primera conexión puede añadir `github.com` a `known_hosts` con `StrictHostKeyChecking=accept-new`.
- En el modo diagnóstico se usa un archivo temporal para no modificar `known_hosts`.
- Si una host key cambia, el asistente se detiene y muestra el problema.
- Verifica las huellas publicadas por GitHub antes de aceptar una clave nueva.

Huellas oficiales:

<https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints>

---

## Navegador y login

El asistente:

- abre la página de GitHub en el navegador;
- copia la clave pública al portapapeles;
- espera a que el usuario confirme;
- verifica la cuenta con `ssh -T`.

El asistente no:

- pide contraseñas;
- automatiza el login;
- evade 2FA;
- lee cookies del navegador;
- envía datos a otro servicio.

El usuario debe comprobar que la sesión del navegador pertenece a la cuenta correcta antes de guardar la clave.

---

## Backups

Los backups se guardan en:

```text
%LOCALAPPDATA%\DualGithubSetup\backups
```

Pueden contener:

- rutas;
- emails;
- nombres;
- configuración de Git;
- copias de archivos `.gitconfig-*`.

No contienen claves privadas ni passphrases, salvo que el usuario haya puesto manualmente una clave en un archivo de configuración (algo que el asistente no hace).

Los backups pueden contener información personal. No los publiques ni los subas a un repositorio.

---

## Logs

Los logs se guardan en:

```text
%LOCALAPPDATA%\DualGithubSetup\logs
```

El archivo de estado `%LOCALAPPDATA%\DualGithubSetup\state.json` también contiene rutas, usuarios y emails de los perfiles. No contiene claves privadas ni passphrases.

Los logs registran pasos, comandos y resultados. No registran:

- contenido de claves privadas;
- passphrases;
- tokens.

Aun así, pueden contener rutas, emails y nombres. Revísalos antes de compartirlos.

---

## Rollback

El rollback es quirúrgico:

- elimina solo las entradas `includeIf` gestionadas;
- restaura los archivos de perfil desde el backup;
- elimina los archivos de perfil que creó el asistente;
- no borra claves privadas;
- no borra claves de GitHub.

Para eliminar una clave de GitHub, hazlo manualmente en **Settings > SSH and GPG keys**. El asistente muestra el título y la huella para ayudarte a identificarla.

---

## Riesgos conocidos

- **Carpetas sincronizadas:** OneDrive, Dropbox y similares pueden subir una clave privada. Usa `%USERPROFILE%\.ssh` y evita sincronizarlo.
- **Computadora compartida:** otra persona con tu usuario de Windows puede leer la clave. Usa passphrase y bloquea la sesión.
- **Malware:** ningún script puede proteger una clave de un proceso malicioso con tus permisos.
- **Herramientas gráficas:** algunas pueden ignorar `core.sshCommand`. Verifica cada herramienta.
- **`GIT_SSH_COMMAND`:** si está definida, anula la configuración por carpeta. El asistente avisa.
- **Proxy corporativo:** puede requerir configuración adicional; no desactives la verificación de host keys.
- **Claves antiguas:** si migras una clave, borra la copia antigua solo después de verificar que la nueva funciona.

---

## Recomendaciones

- Usa una clave distinta por cuenta.
- Usa una passphrase si la computadora es compartida.
- Activa BitLocker o el cifrado de disco equivalente.
- Revisa la cuenta de GitHub antes de guardar una clave.
- Ejecuta `.\setup.cmd -Check` después de cambiar de equipo.
- No publiques `AGENTS.md` con datos personales; usa los ejemplos con placeholders.
- No subas claves, logs, estados ni backups a un repositorio.
