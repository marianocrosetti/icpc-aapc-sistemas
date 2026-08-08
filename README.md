# Setup del TAP

Pasos para levantar la infraestructura del TAP (contest BOCA en Google Cloud). Ir refinando con cada edición.

## Runbook: encender y apagar el contest

Si la infraestructura **ya está instalada** (que es el caso desde abril 2026), prender todo y
dejarlo funcionando es un comando:

```bash
./scripts/04-start-contest.sh     # prende las VMs y levanta los autojudges
./scripts/03-diagnose-boca.sh     # verifica que todo quedó bien
# ... el contest ...
./scripts/05-stop-contest.sh      # apaga las VMs
```

La arquitectura es **una main que corre web + base y no juzga nunca, más N máquinas judge** que
corren el autojudge y se conectan a la base de la main por red. Juzgar consume CPU y no conviene
que compita con el servidor web justo cuando todos los equipos están enviando. Escalar es agregar
judges:

```bash
JUDGES="boca-judge-1 boca-judge-2" ./scripts/04-start-contest.sh
```

Dos cosas para recordar, las dos causa de envíos que se quedan en `openrun` sin ningún error
visible en la web:

> **Los autojudges no sobreviven un reboot.** No son servicios de systemd. Si reiniciás cualquier
> VM, volvé a correr `04-start-contest.sh`.

> **El autojudge son dos procesos**: el wrapper `boca-autojudge` y su hijo `php autojudging.php`,
> que es el que realmente juzga. Si matás sólo el wrapper, el hijo queda huérfano y **sigue
> juzgando**, así que nunca uses `pkill -f boca-autojudge` para apagarlo ni `pgrep` del wrapper
> para saber si está corriendo. Ver
> [session-2026-08-08 §8](./docs/session-2026-08-08.md#gotcha-grande-el-autojudge-son-dos-procesos-y-pkill--f-boca-autojudge-no-lo-detiene).

Para hacer los pasos a mano, ver [§1 jail](#jail-del-autojudge-obligatorio-si-el-autojudge-va-a-correr-acá)
y [§2.1](#21-arrancar-el-autojudge).

## Antes de empezar

Si retomás un setup existente, **empezá por el diagnóstico** en vez de asumir el estado que
describen las bitácoras (ya pasó dos veces que quedaran desactualizadas a mitad de una sesión, y
que listaran como pendiente algo que en realidad ya estaba hecho):

```bash
./scripts/03-diagnose-boca.sh                      # boca-main
VM_NAME=boca-judge-1 ./scripts/03-diagnose-boca.sh # una judge
```

Te dice si BOCA está corriendo, si existe el jail, si el autojudge está levantado, y si las
extensiones de `langtable` coinciden con las carpetas de los paquetes cargados.

### Trampas conocidas

| Síntoma | Causa | Dónde |
|---|---|---|
| Los envíos quedan en `openrun`, sin error en la web | El autojudge no está corriendo. **No es un servicio de systemd**, hay que levantarlo a mano después de cada boot | [§2.1](#21-arrancar-el-autojudge) |
| `boca-autojudge` dice `Bocajail not found` | Nunca se corrió `boca-createjail` en esa máquina | [§1 jail](#jail-del-autojudge-obligatorio-si-el-autojudge-va-a-correr-acá) |
| `boca-createjail` dice `/bocajail/proc seems to be mounted` | Una corrida previa se interrumpió y dejó `/proc` montado | [session-2026-08-08](./docs/session-2026-08-08.md#gotcha-si-se-interrumpe-queda-proc-montado-y-no-se-puede-reintentar) |
| C++ falla al juzgar | El paquete usa `cpp` (formato `box`) y BOCA espera `cc`. Los paquetes de `rbx` usan `cc` y no requieren cambios | [session-2026-08-08](./docs/session-2026-08-08.md#4-paquetes-rbx-vs-box-la-extensión-de-c) |
| Kotlin no aparece o falla | No está en `langtable` **y** `kotlinc` no viene en el jail | idem |
| El upload del paquete falla | Límites de PHP; sólo importa el `php.ini` de **fpm** | [§1 límites](#subir-problemas-pesados-aumentar-límites-de-php) |
| Apagaste el autojudge pero los envíos se siguen juzgando | Mataste el wrapper y quedó vivo el hijo `php autojudging.php`, huérfano | [session-2026-08-08 §8](./docs/session-2026-08-08.md#gotcha-grande-el-autojudge-son-dos-procesos-y-pkill--f-boca-autojudge-no-lo-detiene) |
| El diagnóstico dice que no corre el autojudge, pero sí corre (o al revés) | `pgrep -f` matchea el texto del propio script que pregunta; hay que usar `pgrep -x -f` | idem |
| Querés saber qué máquina juzgó un run | `runtable.autoip` dice `local` siempre, incluso juzgando en remoto. Usar el log del autojudge | [session-2026-08-08 §8](./docs/session-2026-08-08.md#validación-del-juzgado-remoto-y-por-qué-autoip-no-sirve-para-saber-quién-juzgó) |

## Referencia 2025

### Infraestructura: Google Cloud

### 1. Primera instancia: web server + base de datos

- **Máquina:**
  - Para pruebas iniciales: `e2-medium` (low cost, 2 vCPU, 4 GB RAM), región `us-central` (Iowa).
  - Para la prueba real, idealmente algo con **16 vCPU y 32 GB RAM**.
- **SO:** Ubuntu 22 (validar versión compatible con BOCA en https://launchpad.net/~icpc-latam/+archive/ubuntu/maratona-linux — la que diga "boca" en versión Jammy).
- **Disco:** SSD 70 GB.
- **IPs:**
  - Fijar la **IP privada** de cada máquina apenas se crea (Marketplace → IP Addresses).
  - Fijar la **IP pública** del web server que corre en `main` (abrir HTTP 80).

#### Instalación de BOCA

```bash
sudo su
apt update
apt dist-upgrade
add-apt-repository ppa:icpc-latam/maratona-linux
sudo apt update
apt install boca
```

Durante la instalación pide:

- **Ubicación base de datos:** `localhost`
- **Password (generar nueva):** `J553wdSKvXAkhNVK4iLO`
- **Sobreescribir versión de Postgres:** sí
- **Crear nueva base de datos:** sí

#### Jail del autojudge (obligatorio si el autojudge va a correr acá)

`apt install boca` **no** crea el jail, y `boca-autojudge` se niega a arrancar sin él. Hay que
correrlo explícitamente en toda máquina que vaya a juzgar, incluida la main:

```bash
# Tarda 5-10 min (debootstrap + compiladores) y termina en ~1.6 GB.
# Desatachado para que no lo corte una desconexión de SSH:
sudo bash -c 'nohup setsid boca-createjail > /tmp/createjail.log 2>&1 < /dev/null &'
sudo tail -f /tmp/createjail.log
```

Verificar que quedó completo:

```bash
schroot -l    # debe listar chroot:bocajail
for b in gcc g++ javac java python3; do
  printf '%-9s %s\n' "$b" "$(sudo chroot /home/bocajail which $b 2>/dev/null || echo NO)"
done
```

Después, arrancar el autojudge (ver [§2.1](#21-arrancar-el-autojudge)). Detalles, gotchas y cómo
recuperarse de un `boca-createjail` interrumpido: [`docs/session-2026-08-08.md`](./docs/session-2026-08-08.md).

#### Verificación

Web server y base de datos deberían estar corriendo. Loguear en `IP_DE_LA_VM/boca`:

- Usuario: `system`
- Password: `boca`

(Es el usuario más poderoso: crea contests, elige el contest que se está viendo, etc. Se pueden crear usuarios de diferentes tipos: admin, competidor, juez, etc.)

#### Configuración inicial

1. Ir a **Options** y cambiar la password del usuario `system` (usamos `VmLXgcXO13csRUyBQi70`).
2. Ir a **Contest** y crear un nuevo contest.
3. Click en **Send** para guardar la configuración.
4. Click en **Activate** para activar el contest. Esto crea un usuario:
   - Usuario: `admin`
   - Password: `boca` → cambiada a `5PCZMI2wxkXRgxNpllpN`
   - El admin es quien se encarga de cargar los problemas.

#### Subir problemas pesados (aumentar límites de PHP)

Subir un problema pesado seguro no anda hasta aumentar los límites en la config de PHP:

```bash
# Encontrar todos los php.ini
sudo find / -type f -name "php.ini"

# Editar el de fpm
sudo nano /etc/php/8.1/fpm/php.ini
```

Modificar:

```
upload_max_filesize = 100M
post_max_size = 100M
```

Más info: https://www.cyberciti.biz/faq/linux-unix-apache-increase-php-upload-limit/

Reiniciar la VM. Si sigue sin funcionar, editar los mismos límites en los otros `php.ini` que aparecieron en el `find`.

> Antes del próximo paso, asegurarse de que la **IP privada** de la máquina con la BD esté **fija** y no cambie al rebootear.

### 2. Instancia máquina judge (auto-judge)

- **Máquina:** `c2d-highcpu-2` (2 vCPU, 4 GB RAM, 20 GB disco).
- **SO:** Ubuntu 22 — **USAR LA NORMAL, NO LA MINIMAL.**

```bash
sudo apt update
sudo apt dist-upgrade
add-apt-repository ppa:icpc-latam/maratona-linux
sudo apt update
sudo apt install boca
```

Durante la instalación pide:

- **Ubicación:** IP privada de la instancia con la BD.
- **Password:** la password usada al crear la BD previamente.
- **Crear nueva base de datos:** **NO**.

```bash
sudo boca-createjail
```

### 2.1 Arrancar el autojudge

**`boca-autojudge` no es un servicio de systemd.** No hay unit file, no arranca al bootear, y no
sobrevive un reboot. Hay que levantarlo a mano en cada máquina que juzgue, cada vez que se
prende:

```bash
sudo bash -c 'nohup setsid boca-autojudge > /tmp/autojudge.log 2>&1 < /dev/null &'
sudo tail -f /tmp/autojudge.log   # queda en "Nothing to do. Sleeping...."
```

Si esto falta, los envíos se quedan en estado `openrun` para siempre **sin ningún error visible
en la web**: parece que el sistema está colgado. Es el error operativo más fácil de cometer.

Además, como admin del contest hay que habilitar el checkbox de autojudge en la pestaña **Site**.

### 3. Conectar máquinas (web server ↔ judges)

#### En la máquina MAIN (donde está la BD)

Editar `/etc/postgresql/14/main/postgresql.conf`:

```
listen_addresses = '*'
```

**Por cada máquina auto-judge:**

```bash
sudo iptables -A INPUT -p tcp --dport 5432 -s IPPRIVADAAUTOJUDGING -j ACCEPT
```

Editar `/etc/postgresql/14/main/pg_hba.conf` y agregar:

```
host  all  all  IPPRIVADAAUTOJUDGING/32 md5
```

Reiniciar la VM.

#### En la máquina del auto-judge

Editar `/var/www/boca/src/private/conf.php` y asegurarse que:

- `dbhost` apunta a la IP privada de la máquina main.
- La contraseña para la BD es la correcta.

Ahora `sudo boca-autojudge` en la máquina judge debería funcionar, y se debería poder submitear un problema a través de la web.

### 4. Dominio

Este año usamos **WordPress como name server**: fijamos la IP en Google Cloud y agregamos un DNS record tipo `A` apuntando a esta IP desde un subdominio nuevo. Detalles: https://wordpress.com/support/domains/setting-custom-a-records/

#### Redireccionar `/` a `/boca`

Agregar al archivo `/etc/apache2/sites-enabled/000-boca.conf`:

```
RedirectMatch ^/$ /boca/
```

### 5. HTTPS (certbot)

```bash
sudo snap install --classic certbot
sudo ln -s /snap/bin/certbot /usr/bin/certbot
sudo certbot --apache
```

- Ingresar el dominio o subdominio configurado previamente.
- Cuando pregunte qué `.conf` de Apache modificar, elegir el que dice **"ssl"** en el nombre.
- Copiar el contenido de `000-boca.conf` (sin incluir los tags más externos de puerto 80) dentro del archivo `*ssl*.conf` en `/etc/apache2/sites-enabled/` (el mismo que usaste con certbot).

### 6. Recursos adicionales

- **Warmup:** https://github.com/lsantire/tap-warmup
- **Crear usuarios:** https://github.com/elsantodel90/icpc-latam-user-mgmt (repo externo; se clona en `externals/icpc-latam-user-mgmt` con `scripts/clone-externals.sh`, no versionado acá)
- **`score.sep`:** para configurar scoreboards.

## Formato de los paquetes de problemas

Desde 2026 los problemas se empaquetan con **`rbx`** (lo que usan la regional y la PDA), no con
`box` (lo que se usó en 2025). Para BOCA la diferencia que importa es el nombre de la carpeta de
C++ dentro del paquete:

| | C++ | C | Java | Kotlin | Python |
|---|---|---|---|---|---|
| Paquete **`rbx`** | `cc` | `c` | `java` | `kt` | `py3` |
| Paquete **`box`** / `mpkg.py` | `cpp` | `c` | `java` | `kt` | `py3` |
| **BOCA** `langtable` (default) | `cc` | `c` | `java` | — | `py3` + `py2` |

**Con `rbx` no hay que tocar la tabla de lenguajes para C++**, porque coincide con el default de
BOCA. Con paquetes viejos de `box` sí, o C++ no compila. Validado end-to-end (incluido el checker
propio del paquete) en [`docs/session-2026-08-08.md`](./docs/session-2026-08-08.md).

## Bitácoras

- [`docs/session-2026-04-25.md`](./docs/session-2026-04-25.md) — bootstrap de GCP, VM main, paquetes del problemset 2025. **Su checklist de pendientes quedó desactualizada**: se escribió antes de terminar la sesión.
- [`docs/session-2026-04-25-judge-vm.md`](./docs/session-2026-04-25-judge-vm.md) — creación de la VM judge.
- [`docs/session-2026-04-25-users.md`](./docs/session-2026-04-25-users.md) — generación de usuarios desde el export CLICS.
- [`docs/session-2026-08-08.md`](./docs/session-2026-08-08.md) — auditoría del estado real, el jail del autojudge, y validación de paquetes `rbx`.

## Scripts

| Script | Qué hace |
|---|---|
| `01-setup-main-vm.sh` | Crea la VM main (web + BD) con IPs fijas y firewall HTTP. Idempotente |
| `02-setup-judge-vm.sh` | Crea una VM judge con IP privada fija. Idempotente |
| `03-diagnose-boca.sh` | Diagnóstico read-only del estado de un BOCA ya instalado |
| `04-start-contest.sh` | Prende las VMs y levanta los autojudges. Idempotente |
| `05-stop-contest.sh` | Apaga las VMs |
| `build-boca-packages.sh` | Pipeline `box build` + `mpkg.py` para el problemset 2025 (formato viejo) |
| `clone-externals.sh` | Clona los repos externos en `externals/` |

Los scripts `01`–`02` son de **instalación** (una vez por edición); `03`–`05` son de **operación**
(cada sesión).
