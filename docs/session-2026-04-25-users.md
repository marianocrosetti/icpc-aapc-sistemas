# Sesión 2026-04-25 — Generación de usuarios BOCA (TAP 2025)

Bitácora de cómo armamos los usuarios de BOCA para el TAP 2025 a partir del export CLICS de icpc.global usando el repo de Ribas.

## Repo usado

[`elsantodel90/icpc-latam-user-mgmt`](https://github.com/elsantodel90/icpc-latam-user-mgmt) — clonado vía SSH a `scripts/icpc-latam-user-mgmt/`.

```bash
git clone git@github.com:elsantodel90/icpc-latam-user-mgmt.git scripts/icpc-latam-user-mgmt
```

## Cómo funciona el repo

Estructura por país (`ar/`, `br/`, `cb/`, ...). Para cada país:

| Archivo | Propósito |
|---|---|
| `id` | Single digit BOCA site ID (Argentina = `3`) |
| `fullname` | Nombre del país para el scoreboard |
| `site` | Lista de sedes: `<código-6-chars>:<icpc-group-id>:<nombre>` |
| `shorts.sh` | Map opcional de short names para instituciones (ej: `SHORTS[Universidad Tecnológica Nacional - Facultad Regional Rosario]='UTN-Rosario'`) |
| `CLICS_CS*.zip` | Export descargado de icpc.global |
| `logo.jpg` | Logo del país (usado por los password badges en LaTeX, no necesario para los users) |

Pipeline (`make ar/boca-users.txt`):

1. **`%/teams.tsv: %/CLICS_CS*.zip`** — extrae `teams.tsv` del zip dentro de `ar/`.
2. **`%/boca-users.txt: %/teams.tsv %/site`** — corre `gera-usuarios.sh` desde `ar/`. El script lee `id`, `fullname`, `site`, `teams.tsv`, `shorts.sh`, `passwdmap.sh` y emite a stdout.

Outputs generados:

- `boca-users.txt` — archivo importable a BOCA por `system → Users → Import`.
- `score.sep` — config del scoreboard general + por sede.
- `webcast.sep` — equivalente para webcast.
- `passwdmap.sh` — passwords estables entre re-runs (es la clave para que reimportar no rote contraseñas).

`gera-usuarios.sh` por dentro:

- Genera `usernumber = <BOCASITEID><sede_index_2digits><0><uid_3digits>`. Para AR (BOCASITEID=3) la sede `soarba` (2da) arranca en `3020101`.
- Username: `team<código_sede><team_index_3digits>` → `teamsoarba001`, `teamsoarba002`, ...
- Por cada sede no-vacía agrega un user `staff<código>1` con `usernumber=<USERPRE>901`.
- `userdesc` lleva `[<short>][<paisLowercase>,<paisUppercase>] <institución completa>`.
- El short de la institución sale del CLICS (`teams.tsv` columna 6) o, si está vacío, del `shorts.sh`. Si ambos están vacíos hay que correr `bash sigleitor.sh ar/teams.tsv` que prompea por cada uno y graba `shorts.sh`.

Las sedes con cero teams en `teams.tsv` se skipean automáticamente (no se emite el user staff).

## Adaptaciones para macOS

El script asume Linux/Debian. Tres parches/instalaciones:

### 1. bash 4+

`gera-usuarios.sh` usa `declare -A` y `${var,,}`/`${var^^}` (case conversion). macOS ships bash 3.2.

```bash
brew install bash
```

Como `/opt/homebrew/bin` está antes que `/bin` en `PATH`, `bash` resuelve a 5.x sin tocar nada más. La regla del Makefile invoca `bash ../gera-usuarios.sh` (no usa el shebang), así que el lookup viene del `PATH` del entorno donde corremos `make`.

### 2. `makepasswd` no existe en macOS

El original hace:

```bash
[[ ! -e /etc/debian_version ]] && /usr/bin/makepasswd -c "$PASSWDSTRING" -l 12 && return
/bin/makepasswd --string "$PASSWDSTRING" $*
```

Ambos paths son absolutos (Linux). Lo reemplacé en `gera-usuarios.sh` por un generador portable:

```bash
function makepasswd()
{
  PASSWDSTRING="qwertyupasdfghjkzxcvbnmQWERTYUPASDFGHJKLZXCVBNM23456789"
  LC_ALL=C tr -dc "$PASSWDSTRING" < /dev/urandom | head -c 12
  echo
}
```

Mismo charset (no incluye chars ambiguos como `0/O/1/l/I`), 12 chars de largo. Es un parche local sobre el clon — si re-clonamos el repo hay que reaplicarlo.

### 3. Make

`/usr/bin/make` en macOS es GNU Make 3.81. Suficiente — el Makefile no usa nada de 4.x.

## Cambios para TAP 2025

### `ar/site`

Los `icpc-site-id` (segunda columna del `site`) **cambian todos los años** porque son los `group-id` del CLICS. Los del 2022 que venían en el repo no servían.

Reemplacé el archivo entero usando `groups.tsv` del CLICS 2025:

```
admins:39094:Administrative Site
soarav:39623:Avellaneda
soarib:39110:Bariloche (Instituto Balseiro)
soarba:39106:Buenos Aires
soarcp:39507:Campana
soarch:39108:Chilecito
soarco:39109:Córdoba
soarju:39101:Jujuy
soarlp:39107:La Plata
soarme:39490:Mendoza
soarno:39098:Nueva Orán (Facultad Regional Orán UNSa)
soarre:39489:Resistencia
soarrc:39100:Rio Cuarto (UNRC)
soarro:39103:Rosario
soarsa:39097:Salta
soarut:39105:Santa Fe (UTN)
soartu:39102:Tucumán
```

Códigos nuevos vs 2022:

| Sede | Código | Razón |
|---|---|---|
| Avellaneda | `soarav` | nueva en 2025 |
| Campana | `soarcp` | nueva en 2025 |
| Mendoza | `soarme` | nueva en 2025 |
| Resistencia | `soarre` | nueva en 2025 |

El resto reutiliza los códigos del 2022 (`soarba`, `soarco`, `soarib`, etc).

Nota: 3 de las 17 sedes de `groups.tsv` (admins, Avellaneda, Mendoza) no tienen teams en el `teams.tsv` 2025 — el script las skipea automáticamente. Las dejé en `site` igual para que el archivo refleje el `groups.tsv` completo.

### CLICS zip

```bash
mv ar/CLICS_CS_TAP-2022.zip ar/CLICS_CS_TAP-2022.zip.bak
cp ~/Desktop/CLICS_CS_TAP-2025.zip ar/CLICS_CS_TAP-2025.zip
```

El `.bak` se queda fuera del wildcard `CLICS_CS*.zip` del Makefile.

## Run

```bash
cd /Users/marianocrosetti/Desktop/personal-hq/icpc-aapc-sistemas/scripts/icpc-latam-user-mgmt
rm -f ar/teams.tsv ar/teams-copy.tsv ar/boca-users.txt ar/score.sep ar/webcast.sep ar/passwdmap.sh
make ar/boca-users.txt
```

Output esperado:

```
[GEN] ar/teams.tsv
[FIN] ar/teams.tsv
ar users:      193
FIN BOCA
```

## Resultado

| Archivo | Contenido |
|---|---|
| `ar/boca-users.txt` | 207 users (193 teams + 14 staff). Importable a BOCA. |
| `ar/score.sep` | 1 línea para `Argentina` + 1 por cada sede no vacía. |
| `ar/webcast.sep` | Idem score. |
| `ar/passwdmap.sh` | Passwords estables (commitear como backup, **no público**). |

Distribución de teams por sede:

| Sede | Teams |
|---|---|
| soarba (Buenos Aires) | 39 |
| soarch (Chilecito) | 31 |
| soarro (Rosario) | 20 |
| soarre (Resistencia) | 15 |
| soarrc (Rio Cuarto) | 14 |
| soarut (Santa Fe UTN) | 14 |
| soarco (Córdoba) | 12 |
| soarju (Jujuy) | 11 |
| soarib (Bariloche IB) | 9 |
| soarlp (La Plata) | 9 |
| soarno (Nueva Orán) | 7 |
| soartu (Tucumán) | 6 |
| soarsa (Salta) | 3 |
| soarcp (Campana) | 3 |
| admins / soarav / soarme | 0 (skip) |

Los 193 matchean exactamente el conteo de `teams.tsv` del CLICS. Todas las instituciones traen short del CLICS — no hizo falta correr `sigleitor.sh`.

## Para subir a BOCA

1. Login como `system` en `http://<IP_DE_LA_VM>/boca/`.
2. **Users → Import** → seleccionar `boca-users.txt` → Import.
3. **Contests → Scoreboard config** → cargar `score.sep` y `webcast.sep` (si querés sub-scoreboards por sede).
4. Guardar `passwdmap.sh` en lugar seguro (vault). Si re-corremos `make` con ese archivo presente, las passwords se mantienen estables.

## Re-correr para cambios

- Si llegan teams nuevos en un CLICS actualizado: reemplazar el zip y `make ar/boca-users.txt`. Los teams existentes mantienen password (gracias al `passwdmap.sh`).
- Si hay que cambiar el code de una sede: editar `ar/site` y borrar `passwdmap.sh` (porque las usernames cambian).

## Pendientes / nice-to-have

- [ ] Commitear `ar/site` actualizado y el patch de `gera-usuarios.sh` upstream (PR a `elsantodel90/icpc-latam-user-mgmt`) para que la próxima edición no requiera reaplicar.
- [ ] Script wrapper en `scripts/` (`03-generate-users.sh`) que automatice el `cp zip + make` para sesiones futuras.
- [ ] Generar `passwordbadges.ar` con el target del Makefile (requiere `lualatex` + logo) para imprimir las credenciales por sede.
