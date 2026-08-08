# Setup del TAP

Pasos para levantar la infraestructura del TAP (contest BOCA en Google Cloud). Ir refinando con cada edición.

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
