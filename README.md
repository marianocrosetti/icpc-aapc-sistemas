# Setup del TAP

Pasos para levantar la infraestructura del **TAP** (Torneo Argentino de Programación): un contest
corriendo sobre **BOCA** en Google Cloud. Ir refinando con cada edición.

Hay dos caminos según qué necesites:

- **Operar la infra que ya existe** (el caso normal): [runbook](#runbook-encender-y-apagar-el-contest).
- **Instalar todo de cero** para una edición nueva: [instalación](#instalación-desde-cero-una-vez-por-edición).

## Glosario

Vocabulario que se usa en todo el documento:

| Término | Qué es |
|---|---|
| **TAP** | Torneo Argentino de Programación, el contest que estamos corriendo |
| **PDA** | Programadores de América, el ICPC Latin America Championship |
| **BOCA** | El software de contest: web para los equipos, base de datos, y el juez automático |
| **main** | La VM que corre el web server y la base de datos. Se llama `boca-main`. **No juzga** |
| **judge** | Una VM dedicada a juzgar envíos. Se llaman `boca-judge-1`, `boca-judge-2`, ... |
| **autojudge** | El proceso que compila y corre los envíos y les pone veredicto. Corre en las judges |
| **jail** | El chroot (`/bocajail`) donde el autojudge compila y ejecuta código ajeno, aislado del sistema |
| **`openrun`** | Estado de un envío que todavía nadie juzgó. Si se queda ahí para siempre, el autojudge no está corriendo |
| **`langtable`** | La tabla de BOCA que define los lenguajes habilitados y la extensión de cada uno |
| **`rbx`** / **`box`** | Los dos empaquetadores de problemas. Desde 2026 se usa `rbx`; `box` es el viejo |
| **CLICS** | El formato de export de datos de `icpc.global`, de donde salen los usuarios de los equipos |

## Prerequisitos del operador

Todo lo de este README asume que tenés:

- El repo clonado, y corrés los scripts desde su raíz.
- `gcloud` instalado y autenticado (`gcloud auth login`), con permisos para prender y apagar VMs.
- Acceso SSH a las VMs vía `gcloud compute ssh` (la primera vez genera la clave sola).

Los recursos viven en el proyecto **`aapc-sistemas-tap`**, zona **`us-central1-a`**. Los scripts lo
traen por default, así que no hace falta configurar nada; si querés otro, se pasa por variable de
entorno (ver [variables](#variables-de-entorno-de-los-scripts)).

> **Convención:** cada bloque de comandos arranca con un comentario que dice **dónde** se corre:
> `# [local]` en tu máquina, `# [boca-main]` o `# [boca-judge-N]` adentro de esa VM. Para entrar a
> una VM:
>
> ```bash
> # [local]
> gcloud compute ssh boca-main --zone=us-central1-a --project=aapc-sistemas-tap
> ```

## Runbook: encender y apagar el contest

Si la infraestructura **ya está instalada** (que es el caso desde abril 2026), prender todo y
dejarlo funcionando es un comando:

```bash
# [local] — estos scripts hacen todo por gcloud y por SSH; no hace falta entrar a ninguna VM
./scripts/04-start-contest.sh     # prende las VMs y levanta los autojudges en las judges
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

Para hacer los pasos a mano, ver [§2 jail](#jail-del-autojudge-obligatorio-en-toda-judge)
y [§2.1](#21-arrancar-y-parar-el-autojudge).

### Estado verificado al 2026-08-08

Para no volver a auditar desde cero: esto ya está hecho y probado, **no hace falta reinstalar
nada**. Sólo hay que prender y levantar los autojudges.

| Componente | Estado |
|---|---|
| Web | `http://34.57.222.36/boca/` (HTTP, sin HTTPS: certbot no está configurado) |
| `boca-main` (`e2-medium`) | Apache + PHP 8.1-fpm + Postgres 14 + BOCA 1.5.21. Sin jail y sin autojudge, **a propósito** |
| `boca-judge-1` (`c2d-highcpu-2`) | BOCA 1.5.21, jail listo (1.6 GB), apunta a la base de la main por IP interna |
| Contest | `Contest-test` (contestnumber 1), activo |
| Problemas | Cargados, empaquetados con `rbx` |
| Usuarios | 210 importados del export CLICS (195 equipos + 14 staff + 1 admin) |
| Juzgado | Validado end-to-end: C++11 → `YES` en ~4 s con el checker propio del paquete |
| C++ | `g++ 11.4.0`, compilado con `-std=c++20 -O2 -lm -static`. `<ranges>` y `<bit>` verificados; `std::format` no existe |
| Credenciales | `admin` / `mateocarranzajaja` (cambiada el 2026-08-08). `system` / `boca`, o sea la default: ver [la advertencia](#ojo-con-la-password-de-system) |
| Lenguajes | C, C++, Python 3 funcionan. **Kotlin no** (falta en `langtable` y falta `kotlinc`); Python 2 aparece ofrecido pero no hay intérprete; **Java sin verificar** (el `javac` del jail no arranca, `libjli.so`) |

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
| Los envíos quedan en `openrun`, sin error en la web | El autojudge no está corriendo. **No es un servicio de systemd**, hay que levantarlo a mano después de cada boot | [§2.1](#21-arrancar-y-parar-el-autojudge) |
| `boca-autojudge` dice `Bocajail not found` | Nunca se corrió `boca-createjail` en esa máquina | [§2 jail](#jail-del-autojudge-obligatorio-en-toda-judge) |
| `boca-createjail` dice `/bocajail/proc seems to be mounted` | Una corrida previa se interrumpió y dejó `/proc` montado | [session-2026-08-08](./docs/session-2026-08-08.md#gotcha-si-se-interrumpe-queda-proc-montado-y-no-se-puede-reintentar) |
| C++ falla al juzgar | El paquete usa `cpp` (formato `box`) y BOCA espera `cc`. Los paquetes de `rbx` usan `cc` y no requieren cambios | [session-2026-08-08](./docs/session-2026-08-08.md#4-paquetes-rbx-vs-box-la-extensión-de-c) |
| Kotlin no aparece o falla | No está en `langtable` **y** `kotlinc` no viene en el jail | idem |
| El upload del paquete falla | Límites de PHP; sólo importa el `php.ini` de **fpm** | [§1 límites](#subir-problemas-pesados-aumentar-límites-de-php) |
| Apagaste el autojudge pero los envíos se siguen juzgando | Mataste el wrapper y quedó vivo el hijo `php autojudging.php`, huérfano | [session-2026-08-08 §8](./docs/session-2026-08-08.md#gotcha-grande-el-autojudge-son-dos-procesos-y-pkill--f-boca-autojudge-no-lo-detiene) |
| Querés saber qué máquina juzgó un run | `runtable.autoip` dice `local` siempre, incluso juzgando en remoto. Usar el log del autojudge | [session-2026-08-08 §8](./docs/session-2026-08-08.md#validación-del-juzgado-remoto-y-por-qué-autoip-no-sirve-para-saber-quién-juzgó) |

## Instalación desde cero (una vez por edición)

Esto es lo que hay que hacer para una edición nueva, o si hay que rehacer una máquina. **Si la
infra ya está instalada, no necesitás nada de acá**: andá al
[runbook](#runbook-encender-y-apagar-el-contest).

El procedimiento viene de la edición 2025 y se validó por última vez en abril de 2026, cuando se
levantó la instalación actual. Los scripts `01` y `02` automatizan la creación de las VMs; el resto
de los pasos (instalar BOCA, el jail, conectar las máquinas) sigue siendo manual porque el
instalador de BOCA es interactivo.

```bash
# [local] crear las VMs, en vez de hacerlo a mano por la consola de GCP
./scripts/01-setup-main-vm.sh
./scripts/02-setup-judge-vm.sh
```

Las especificaciones de abajo describen qué crean esos scripts, y sirven de referencia si hay que
hacerlo a mano por la consola.

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

El instalador es **interactivo** (prompts de debconf) y pide:

- **Ubicación base de datos:** `localhost`
- **Password:** generá una nueva y **anotala acá mismo**; la vas a necesitar de nuevo al instalar
  cada judge, que se conecta a esta base. La de la instalación actual es
  `J553wdSKvXAkhNVK4iLO`.
- **Sobreescribir versión de Postgres:** sí
- **Crear nueva base de datos:** sí

> Ojo con esas dos últimas en una máquina que ya tenga datos: sobrescriben la instalación de
> Postgres y crean la base de cero. En una VM recién creada no hay nada que perder, que es el caso
> acá.

> Esta máquina **no** necesita el jail del autojudge y **no** debe correr `boca-createjail`: no
> juzga. El jail va sólo en las judges, [§2](#2-instancia-máquina-judge-auto-judge).

#### Verificación

Web server y base de datos deberían estar corriendo. Loguear en `IP_DE_LA_VM/boca`:

- Usuario: `system`
- Password: `boca`

(Es el usuario más poderoso: crea contests, elige el contest que se está viendo, etc. Se pueden crear usuarios de diferentes tipos: admin, competidor, juez, etc.)

#### Configuración inicial

1. Ir a **Options** y cambiar la password del usuario `system`.
2. Ir a **Contest** y crear un nuevo contest.
3. Click en **Send** para guardar la configuración.
4. Click en **Activate** para activar el contest. Esto crea el usuario `admin` con password `boca`,
   que es quien carga los problemas. Cambiarla.

##### Ojo con la password de `system`

Las passwords que andan circulando en la documentación son de **instalaciones de años anteriores** y
no sirven para la instalación actual. En particular `VmLXgcXO13csRUyBQi70` (para `system`) y
`5PCZMI2wxkXRgxNpllpN` (para `admin`) salen de la sección 2025 de `boca.md`, no de esta instalación.

Para la instalación actual (abril 2026) valen éstas:

| Usuario | Password | Cómo lo sabemos |
|---|---|---|
| `admin` | `mateocarranzajaja` | Cambiada el 2026-08-08. Hasta ese día tenía la default `boca`, o sea que el paso 4 nunca se hizo en abril |
| `system` | `boca` (la default) | La bitácora de abril sólo registra el login inicial y nunca registra haberla cambiado. **Sin verificar**: si no entra, probar las de `boca.md` |
| Base de datos | `J553wdSKvXAkhNVK4iLO` | Registrada en la bitácora de abril |

La moraleja para la próxima edición: si cambiás una password, anotala acá en el mismo momento. El
enredo de arriba existe porque los pasos "cambiar la password" se documentaron como si se hubieran
hecho, y no se hicieron.

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

#### Jail del autojudge (obligatorio en toda judge)

`apt install boca` **no** crea el jail, y `boca-autojudge` se niega a arrancar sin él, con
`Bocajail not found`. El paso está en las notas viejas, pero no lo que se rompe si falta: los
envíos quedan en `openrun` sin ningún error visible en la web.

```bash
# Tarda 5-10 min (debootstrap + compiladores) y termina en ~1.6 GB.
# Desatachado para que no lo corte una desconexión de SSH:
sudo bash -c 'nohup setsid boca-createjail > /tmp/createjail.log 2>&1 < /dev/null &'
sudo tail -f /tmp/createjail.log
```

Verificar que quedó completo. El `chroot` es importante: preguntar desde el host da falsos
negativos en `java`/`javac`, porque son symlinks a `/etc/alternatives` que sólo resuelven adentro.

```bash
schroot -l    # debe listar chroot:bocajail
for b in gcc g++ javac java python3; do
  printf '%-9s %s\n' "$b" "$(sudo chroot /home/bocajail which $b 2>/dev/null || echo NO)"
done
```

Si se interrumpe a mitad de camino queda `/proc` montado adentro y no se puede reintentar ni
borrar; cómo recuperarse está en
[session-2026-08-08](./docs/session-2026-08-08.md#gotcha-si-se-interrumpe-queda-proc-montado-y-no-se-puede-reintentar).

### 2.1 Arrancar y parar el autojudge

En la operación normal esto lo hace `04-start-contest.sh`; lo de acá es el equivalente manual, y
es lo que hay que saber si necesitás tocar un solo judge en medio de un contest.

**`boca-autojudge` no es un servicio de systemd.** No hay unit file, no arranca al bootear, y no
sobrevive un reboot. Hay que levantarlo a mano en cada judge, cada vez que se prende:

```bash
# [boca-judge-N]
sudo bash -c 'nohup setsid boca-autojudge > /tmp/autojudge.log 2>&1 < /dev/null &'
sudo tail -f /tmp/autojudge.log   # queda en "Nothing to do. Sleeping...."
```

Si esto falta, los envíos se quedan en estado `openrun` para siempre **sin ningún error visible
en la web**: parece que el sistema está colgado. Es el error operativo más fácil de cometer.

Para **ver si está corriendo** y para **pararlo** hay que acordarse de que son dos procesos, el
wrapper y su hijo `php`, y usar match exacto (`-x -f`):

```bash
# [boca-judge-N] ¿está corriendo?
sudo pgrep -x -f '/bin/bash /usr/sbin/boca-autojudge'   # el wrapper
sudo pgrep -x -f 'php autojudging.php'                  # el que juzga de verdad

# [boca-judge-N] pararlo, los dos y en este orden
sudo pkill -x -f '/bin/bash /usr/sbin/boca-autojudge'
sudo pkill -x -f 'php autojudging.php'
```

Si matás sólo el primero, el hijo queda huérfano y **sigue juzgando**. Y no uses `pkill -f` sin
`-x`: mata tu propia sesión de SSH, que corta con `return code [255]` como si la VM se hubiera
caído. Cuidado también con no matar los `php-fpm` de Apache, que son otra cosa y hacen falta para
la web; los patrones exactos de arriba no los tocan, pero un `pkill php` te deja el sitio caído.

Apagar la VM entera (`05-stop-contest.sh`) también sirve y es lo más simple si estás terminando.

Además, una vez por contest, como `admin` hay que habilitar el checkbox de autojudge en la pestaña
**Site** de la web. Sin eso los envíos no se reparten a los judges.

### 3. Conectar máquinas (web server ↔ judges)

Lo que hace falta es que Postgres escuche por red y acepte a cada judge. Son dos ediciones y un
reload:

```bash
# [boca-main] 1) que escuche fuera de localhost
sudo nano /etc/postgresql/14/main/postgresql.conf     # listen_addresses = '*'

# [boca-main] 2) una línea por cada judge, con su IP privada
sudo nano /etc/postgresql/14/main/pg_hba.conf         # host all all 10.128.0.3/32 md5

# [boca-main] 3) aplicar sin rebootear
sudo systemctl restart postgresql
```

> **Sobre la regla de `iptables` que piden las notas viejas**
> (`iptables -A INPUT -p tcp --dport 5432 -s <ip-judge> -j ACCEPT`): en estas VMs **no hace falta**,
> y conviene saber por qué antes de copiarla. Verificado el 2026-08-08: el `iptables` de los hosts
> tiene la política de `INPUT` en `ACCEPT` y ninguna regla, así que agregar un `ACCEPT` es un no-op;
> y el tráfico entre VMs del VPC ya lo habilita la regla `default-allow-internal` de GCP, que
> permite `tcp:0-65535` desde `10.128.0.0/9` (se ve con
> `gcloud compute firewall-rules list`). El paso viene de las notas de 2023/2024, de cuando esto
> corría en AWS.
>
> Si algún día **sí** hace falta (porque alguien endurece el `INPUT`, o se cambia de cloud), ojo que
> `iptables -A` **no sobrevive un reboot**: hay que persistirla con `iptables-persistent` o
> equivalente, o se pierde silenciosamente y el síntoma es el peor de todos, envíos en `openrun` sin
> error visible.

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

Cargarlos no tiene ningún truco: como `admin`, en la pestaña **Problems** de la web, se sube el
`.zip` que genera `rbx` tal cual. Lo único a tener en cuenta es que los paquetes son grandes, así
que primero hay que subir los límites de PHP
([§1](#subir-problemas-pesados-aumentar-límites-de-php)).

### Versión de C++ y flags

**El estándar lo define el paquete, no BOCA**: los flags viven en el script `compile/cc` de cada
`.zip`. Los paquetes de `rbx` compilan así, con el `g++ 11.4.0` del jail:

```bash
g++ -std=c++20 -O2 -lm -static
```

`-static` no es opcional: el script de ejecución aborta si el binario no quedó estático. Y ojo que
`-std=c++20` no es C++20 completo: `<ranges>` y `<bit>` andan bien, pero **`std::format` no está**
(llega en g++ 13) ni `constexpr std::vector` (llega en libstdc++ 12). Para medirlo en vez de
suponerlo: `scripts/06-check-cpp-features.sh`, con
[el detalle acá](./docs/session-2026-08-08.md#qué-versión-de-c-se-compila-y-con-qué-flags).

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
| `06-check-cpp-features.sh` | Mide qué features de C++ soporta de verdad el compilador del jail, con los flags reales del paquete. Se corre en un contenedor o dentro del jail |
| `build-boca-packages.sh` | Pipeline `box build` + `mpkg.py` para el problemset 2025 (formato viejo) |
| `clone-externals.sh` | Clona los repos externos en `externals/` |

Los scripts `01`–`02` son de **instalación** (una vez por edición); `03`–`05` son de **operación**
(cada sesión). Todos son idempotentes: si el recurso ya existe o el proceso ya está corriendo, no
lo tocan, así que se pueden correr de nuevo sin miedo.

### Variables de entorno de los scripts

Todos toman los mismos defaults, pensados para la instalación actual, así que en general se corren
sin nada:

| Variable | Default | Qué es |
|---|---|---|
| `PROJECT_ID` | `aapc-sistemas-tap` | Proyecto de GCP |
| `ZONE` | `us-central1-a` | Zona de las VMs |
| `MAIN_VM` | `boca-main` | Nombre de la VM main |
| `JUDGES` | `boca-judge-1` | Lista de judges, separadas por espacios. Tienen que ser VMs que ya existan (creadas con `02-setup-judge-vm.sh`) |
| `VM_NAME` | `boca-main` | Sólo en `03-diagnose-boca.sh`: qué VM diagnosticar. Para una judge: `VM_NAME=boca-judge-1 ./scripts/03-diagnose-boca.sh` |
| `CONTEST` | `1` | Sólo en `03-diagnose-boca.sh`: el `contestnumber` a inspeccionar |
