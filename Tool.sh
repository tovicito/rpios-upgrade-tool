#!/bin/bash
# -----------------------------------------------------------------------------
# Script de Actualización COMPLETO y ROBUSTO para Raspberry Pi OS / Debian
# con Interfaz Gráfica (GUI) Avanzada usando YAD.
#
# Este script ofrece dos modos de actualización:
# 1. Actualización de Paquetes: Realiza un 'apt update' y 'apt upgrade' normal.
# 2. Actualización Mayor de Sistema y Paquetes: Realiza un 'apt full-upgrade'
#    que puede cambiar la versión de la distribución (ej. Bullseye a Bookworm).
#
# Características principales:
# - Infalible: Exhaustivas verificaciones de permisos, dependencias, red,
#   espacio en disco, salud de APT, estado de la alimentación.
# - GUI Ultra Guapa (con YAD): Interfaz amigable, barras de progreso dinámicas,
#   mensajes claros y enriquecidos con Pango Markup, iconos y diseño profesional.
#   ¡Protegido contra inyección de Pango Markup para texto arbitrario!
# - Integración Profunda: Se siente como una herramienta nativa del sistema.
# - Detección Inteligente: Descubre automáticamente el codename objetivo
#   (la última versión estable de Debian compatible con RPi OS).
# - Copias de Seguridad: Backups automáticos de los repositorios antes de cambios mayores.
# - Modo de Simulación (Dry Run): Permite previsualizar los cambios antes de aplicarlos.
# - Gestión de Repositorios de Terceros: Advertencia y opción de deshabilitar.
# - Reversión de Fuentes APT: Opción de deshacer los cambios en los repositorios
#   si la actualización mayor falla.
# - Logging Exhaustivo: Cada paso, verificación y error se registra.
#
# Autor: Tomás (con extensas mejoras y pulido por Gemini)
# Fecha: 15 de junio de 2025
# Versión: 4.1 (Monolítico, Infalible, GUI YAD Premium, Ultra-Paranoica)
#
# Uso:
#   sudo ./rpios-upgrade-tool.sh
#
# Logs:
#   /var/log/rpios-upgrade-tool.log     (Log principal persistente del script)
#   /tmp/rpios-apt-output-TIMESTAMP.log (Log detallado y temporal de la salida de APT)
#
# -----------------------------------------------------------------------------

# Configuración Global y Traps
LOG_FILE="/var/log/rpios-upgrade-tool.log"
BACKUP_BASE_DIR="/var/backups/apt-sources-$(date '+%F-%H%M%S')"
APT_TEMP_LOG="/tmp/rpios-apt-output-$(date '+%F-%H%M%S').log"

# Variable para detectar si YAD está disponible y si estamos en un entorno gráfico
GUI_AVAILABLE=false
if command -v yad &>/dev/null && [ -n "$DISPLAY" ]; then
    GUI_AVAILABLE=true
fi

# Trap para asegurar la limpieza del log temporal de APT al salir
# Copia el log temporal al log principal solo si el script termina con un error.
trap '
    if [ -f "$APT_TEMP_LOG" ]; then
        if [ "$?" -ne 0 ]; # Si el último comando ejecutado antes del trap tuvo un error
            log_error "El script terminó con un fallo. Copiando el log temporal de APT ($APT_TEMP_LOG) al log principal ($LOG_FILE) para depuración."
            cat "$APT_TEMP_LOG" >> "$LOG_FILE"
        fi
        rm -f "$APT_TEMP_LOG"
    fi
' EXIT

# --- Funciones de Utilidad para la GUI ---

# Función para escapar texto para Pango Markup (seguridad contra inyección)
escape_pango_text() {
    echo "$*" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'
}

# --- Funciones de Logging y Mensajes de Interfaz (GUI con YAD) ---

log_info() {
    local message="$*"
    echo "$(date '+%F %T') [INFO] $message" | tee -a "$LOG_FILE"
    if ! "$GUI_AVAILABLE"; then
        echo "[INFO] $message"
    fi
}

log_warning() {
    local message="$*"
    echo "$(date '+%F %T') [WARNING] $message" | tee -a "$LOG_FILE" >&2
    if ! "$GUI_AVAILABLE"; then
        echo "[WARNING] $message" >&2
    fi
}

log_error() {
    local message="$*"
    echo "$(date '+%F %T') [ERROR] $message" | tee -a "$LOG_FILE" >&2
    if ! "$GUI_AVAILABLE"; then
        echo "[ERROR] $message" >&2
    fi
}

show_critical_error_and_exit() {
    local message_raw="$1"
    local message_escaped=$(escape_pango_text "$message_raw")
    log_error "Error Crítico: $message_raw"

    if "$GUI_AVAILABLE"; then
        yad --error --title="🚫 Error Crítico del Sistema 🚫" \
            --text="<span font='12pt' weight='bold' foreground='red'>Se ha producido un error crítico que impide continuar:</span>\n\n<span font='10pt'>$message_escaped</span>\n\n<span font='9pt'>Por favor, revise el log detallado en <b>$LOG_FILE</b> para más información.</span>" \
            --width=550 --height=180 --no-buttons --timeout=0 --center
    else
        echo -e "\n===================================================================" >&2
        echo -e "  ⛔ ERROR CRÍTICO: El script ha terminado debido a un fallo grave. ⛔" >&2
        echo -e "  $message_raw" >&2
        echo -e "  Consulte el log detallado en $LOG_FILE para más información." >&2
        echo -e "===================================================================\n" >&2
    fi
    exit 1
}

show_info_message() {
    local title="$1"
    local message_raw="$2"
    local width="${3:-400}"
    local icon="${4:-dialog-information}"
    local message_escaped=$(escape_pango_text "$message_raw")

    if "$GUI_AVAILABLE"; then
        yad --info --title="$title" --text="<span font='10pt'>$message_escaped</span>" \
            --width="$width" --height=150 --button="Aceptar:0" --image="$icon" --image-on-top --center
    else
        log_info "--- $title ---"
        log_info "$message_raw"
        echo -e "\n$message_raw\n"
        sleep 2
    fi
}

ask_question() {
    local title="$1"
    local message_raw="$2"
    local width="${3:-450}"
    local icon="${4:-dialog-question}"
    local message_escaped=$(escape_pango_text "$message_raw")

    if "$GUI_AVAILABLE"; then
        yad --question --title="$title" --text="<span font='10pt'>$message_escaped</span>" \
            --width="$width" --height=150 --button="Sí:0" --button="No:1" --image="$icon" --image-on-top --center
        return $?
    else
        echo -e "\n--- $title ---"
        echo -e "$message_raw (s/n): "
        read -r -p "" response
        if [[ "$response" =~ ^[sS]$ ]]; then
            return 0
        else
            return 1
        fi
    fi
}

show_warning_message() {
    local title="$1"
    local message_raw="$2"
    local sleep_time="${3:-2}"
    local icon="${4:-dialog-warning}"
    local message_escaped=$(escape_pango_text "$message_raw")

    if "$GUI_AVAILABLE"; then
        yad --warning --title="$title" --text="<span font='10pt'>$message_escaped</span>" \
            --width=500 --height=150 --button="Entendido:0" --image="$icon" --image-on-top --center --timeout="$sleep_time" --timeout-indicator=bottom
    else
        log_warning "--- $title ---"
        log_warning "$message_raw"
        echo -e "\n⚠️ ADVERTENCIA: $message_raw\n" >&2
        sleep "$sleep_time"
    fi
}

# Inicia una barra de progreso pulsante en YAD y devuelve su PID
start_pulsating_progress() {
    local title="$1"
    local text_raw="$2"
    local text_escaped=$(escape_pango_text "$text_raw")
    if "$GUI_AVAILABLE"; then
        (
            echo "0"; echo "PULSE"
            while true; do
                echo "# <span font='9pt'>$text_escaped</span>"
                sleep 0.5
            done
        ) | yad --progress --title="$title" --text="<span font='10pt'>Iniciando...</span>" \
                --pulsate --auto-close --no-buttons --width=400 --height=120 --center &
        echo "$!"
    fi
}

# Detiene una barra de progreso pulsante de YAD
stop_pulsating_progress() {
    local yad_pid="$1"
    if "$GUI_AVAILABLE" && [ -n "$yad_pid" ]; then
        kill "$yad_pid" >/dev/null 2>&1 || true
    fi
}

# --- Funciones de Verificación Inicial ---

check_root_permissions() {
    log_info "Verificando permisos de root..."
    if [ "$EUID" -ne 0 ]; then
        local script_path=$(realpath "$0")
        if "$GUI_AVAILABLE"; then
            yad --error --title="🚫 Permisos Insuficientes 🚫" \
                --text="<span font='12pt' weight='bold' foreground='red'>Este script debe ejecutarse como root (superusuario).</span>\n\n<span font='10pt'>Por favor, reinícialo con:</span>\n\n<b><span font='11pt' foreground='blue'>sudo bash \"$(escape_pango_text "$script_path")\"</span></b>" \
                --width=550 --height=180 --no-buttons --timeout=0 --center
        else
            echo -e "\nERROR: Este script debe ejecutarse como root (superusuario).\n" >&2
            echo -e "Por favor, reinícialo con: sudo bash \"$script_path\"\n" >&2
        fi
        log_error "Intento de ejecución sin permisos de root. Abortando."
        exit 1
    fi
    log_info "Verificación de permisos de root: OK."
}

check_dependencies() {
    log_info "Verificando dependencias necesarias (curl, jq, yad, apt, bc, etc.)..."
    local yad_pid=""
    yad_pid=$(start_pulsating_progress "⚙️ Verificando Dependencias" "Asegurando que todas las herramientas necesarias están instaladas...")

    local missing_deps=()
    for cmd in curl jq apt grep cut sort find sed tee df dpkg ping systemctl bc; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    if "$GUI_AVAILABLE" && ! command -v yad &>/dev/null; then
        missing_deps+=("yad")
        GUI_AVAILABLE=false
    fi
    if command -v upower &>/dev/null; then
        log_info "Dependencia 'upower' encontrada (para verificación de batería más precisa)."
    fi

    stop_pulsating_progress "$yad_pid"

    if [ ${#missing_deps[@]} -gt 0 ]; then
        local missing_deps_text=$(printf "%s\n" "${missing_deps[@]}")
        show_critical_error_and_exit "<span font='10pt'>Las siguientes dependencias necesarias no están instaladas:</span>\n\n<b>$(escape_pango_text "$missing_deps_text")</b>\n\n<span font='9pt'>Por favor, instálelas con '<b>sudo apt install [nombre_paquete]</b>' e intente de nuevo.</span>"
    fi
    log_info "Todas las dependencias necesarias están presentes: OK."
}

check_internet_connection() {
    log_info "Verificando conexión a internet..."
    local yad_pid=""
    yad_pid=$(start_pulsating_progress "🌐 Verificando Conexión a Internet" "Conectando con servidores de prueba para confirmar la conexión...")

    if ! ping -c 3 -W 3 8.8.8.8 >/dev/null 2>&1; then
        stop_pulsating_progress "$yad_pid"
        show_critical_error_and_exit "<span font='10pt'>No se pudo establecer una conexión a internet.</span>\n\n<span font='9pt'>Por favor, revise su conexión de red (Wi-Fi/Ethernet) y vuelva a intentarlo antes de ejecutar el script.</span>"
    fi
    stop_pulsating_progress "$yad_pid"
    log_info "Conexión a internet verificada: OK."
}

# --- Verificaciones Pre-Actualización (Salud del Sistema) ---

check_disk_space() {
    log_info "Calculando espacio en disco necesario para la actualización (estimado)..."
    local yad_pid=""
    yad_pid=$(start_pulsating_progress "💾 Estimando Espacio en Disco" "Consultando APT para el tamaño estimado de la actualización...")

    local required_bytes apt_simulate_output
    apt_simulate_output=$(LANG=C apt-get --simulate dist-upgrade 2>&1)
    
    stop_pulsating_progress "$yad_pid"

    local used_pattern="After this operation, ([0-9.]+) (kB|MB|GB) of additional disk space will be used"
    local freed_pattern="After this operation, ([0-9.]+) (kB|MB|GB) disk space will be freed"

    local value unit
    if [[ "$apt_simulate_output" =~ $used_pattern ]]; then
        value="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        required_bytes=$(echo "$value $unit" | awk '{
            if ($2=="kB") print $1*1024
            else if ($2=="MB") print $1*1024*1024
            else if ($2=="GB") print $1*1024*1024*1024
            else print $1
        }' OFMT="%.0f")
        required_bytes=${required_bytes:-0}
    elif [[ "$apt_simulate_output" =~ $freed_pattern ]]; then
        required_bytes=$((500 * 1024 * 1024))
    else
        log_warning "No se pudo parsear la estimación de espacio de 'apt-get --simulate'. Asumiendo un mínimo de 3GB de espacio requerido."
        required_bytes=$((3 * 1024 * 1024 * 1024))
    fi

    required_bytes=$((required_bytes + 1 * 1024 * 1024 * 1024))

    local available_bytes
    available_bytes=$(df -P / | awk 'NR==2 {print $4 * 1024}')

    local required_gb=$(printf "%.1f" $(echo "scale=1; $required_bytes / (1024 * 1024 * 1024)" | bc -l))
    local available_gb=$(printf "%.1f" $(echo "scale=1; $available_bytes / (1024 * 1024 * 1024)" | bc -l))

    log_info "Espacio requerido estimado: ${required_gb}GB. Espacio disponible: ${available_gb}GB."

    if (( $(echo "$available_bytes < $required_bytes" | bc -l) )); then
        show_critical_error_and_exit "<span font='10pt'>Espacio en disco insuficiente en la partición raíz (/).</span>\n\n<span font='9pt'>Necesitas al menos <b>${required_gb}GB</b>, pero solo tienes <b>${available_gb}GB</b> disponibles.</span>\n\n<span font='9pt'>Por favor, libera espacio (ej. con '<b>sudo apt clean</b>' o eliminando archivos grandes) antes de continuar.</span>"
    fi
    log_info "Espacio en disco suficiente: OK."
}

check_apt_health() {
    log_info "Comprobando el estado de paquetes APT (dependencias rotas y paquetes retenidos)..."
    local yad_pid=""
    yad_pid=$(start_pulsating_progress "🩺 Verificando Salud del Sistema APT" "Comprobando dependencias de paquetes y detectando paquetes retenidos...")

    local apt_check_output
    local apt_check_exit_status=0
    apt_check_output=$(apt check 2>&1) || apt_check_exit_status=$?

    if [ "$apt_check_exit_status" -ne 0 ]; then
        log_warning "El comando 'apt check' finalizó con código de salida: $apt_check_exit_status. Esto puede indicar problemas. Output:\n$apt_check_output"
    fi

    if echo "$apt_check_output" | grep -q "The following packages have unmet dependencies"; then
        stop_pulsating_progress "$yad_pid"
        show_warning_message "⚠️ Advertencia: APT con Dependencias Rotas ⚠️" \
            "Se detectaron paquetes rotos o con dependencias no resueltas en tu sistema APT.\n\nEs <b>MUY RECOMENDABLE</b> solucionar esto manualmente <b>ANTES</b> de cualquier actualización mayor.\n\nIntentando reparar automáticamente con 'apt -f install'..." 5 "dialog-warning"
        log_error "Sistema APT con dependencias rotas detectadas. Intentando reparar automáticamente..."

        if ! apt -f install -y >> "$LOG_FILE" 2>&1; then
            show_critical_error_and_exit "<span font='10pt'>Falló el intento de reparar las dependencias de APT automáticamente con '<b>apt -f install</b>'.</span>\n\n<span font='9pt'>Por favor, intenta repararlas manualmente ('<b>sudo apt -f install</b>') y ejecuta el script de nuevo.</span>"
        fi
        log_info "Intento de reparación de APT completado."
    fi

    local held_packages
    held_packages=$(dpkg --get-selections | grep 'hold$' | awk '{print $1}' || true)

    if [ -n "$held_packages" ]; then
        stop_pulsating_progress "$yad_pid"
        local held_packages_escaped=$(escape_pango_text "$(printf "%s\n" "${held_packages[@]}")")
        if ask_question "⚠️ Advertencia: Paquetes Retenidos (Hold) ⚠️" \
            "Los siguientes paquetes están 'retenidos' (hold) y <b>NO</b> se actualizarán:\n\n<span font='10pt' weight='bold'>$held_packages_escaped</span>\n\nEsto puede causar problemas serios en la actualización mayor o dejar tu sistema incompleto.\n\n<b>¿Deseas intentar liberarlos (unhold) AHORA?</b> (RECOMENDADO ENCARECIDAMENTE)" 550 "dialog-question"; then
            log_info "Usuario ha elegido intentar liberar paquetes retenidos."
            for pkg in $held_packages; do
                log_info "Intentando liberar el paquete: '$pkg'..."
                local pkg_escaped=$(escape_pango_text "$pkg")
                if ! echo "$pkg install" | dpkg --set-selections >> "$LOG_FILE" 2>&1; then
                    log_error "Fallo al liberar el paquete '$pkg'. Se mantendrá en hold."
                    show_warning_message "⚠️ Fallo al Liberar Paquete ⚠️" \
                        "Fallo al liberar el paquete <b>'$pkg_escaped'</b>. Se mantendrá en estado 'hold'.\n<span font='9pt'>Por favor, revísalo manualmente: '<b>sudo dpkg --set-selections <<< '$pkg_escaped install'</b>'</span>" 3 "dialog-warning"
                else
                    log_info "Paquete '$pkg' liberado."
                fi
            done
            log_info "Proceso de liberación de paquetes retenidos completado."
        else
            log_warning "Usuario ha elegido NO liberar los paquetes retenidos. Esto podría causar problemas serios en la actualización."
            show_warning_message "🚨 Advertencia CRÍTICA: Paquetes Retenidos No Liberados 🚨" \
                "Has elegido <b>NO</b> liberar los paquetes retenidos. Esto puede provocar fallos o inconsistencias <b>MUY GRAVES</b> durante o después de la actualización.\n\n<b>Proceder bajo tu PROPIA responsabilidad y riesgo.</b>" 7 "dialog-error"
        fi
    fi
    stop_pulsating_progress "$yad_pid"
    log_info "Verificación del estado de APT: OK."
}

check_battery_status() {
    log_info "Comprobando estado de la alimentación (batería/corriente)..."
    local yad_pid=""
    yad_pid=$(start_pulsating_progress "⚡ Verificando Estado de la Alimentación" "Detectando baterías y conexiones de corriente...")

    local battery_detected=0

    if command -v upower &>/dev/null; then
        local upower_output=$(upower -e 2>/dev/null | grep "battery" || true)
        if [ -n "$upower_output" ]; then
            local battery_path=$(echo "$upower_output" | head -n 1)
            local battery_state=$(upower -i "$battery_path" | grep state | awk '{print $2}' || echo "unknown")
            local battery_percentage=$(upower -i "$battery_path" | grep percentage | awk '{print $2}' | tr -d '%' || echo "0")
            battery_detected=1

            log_info "Batería detectada: Estado='$battery_state', Porcentaje='$battery_percentage%'."

            if [ "$battery_state" != "charging" ] && [ "$battery_percentage" -lt 50 ]; then
                stop_pulsating_progress "$yad_pid"
                if ! ask_question "⚠️ Advertencia: Batería Baja ⚠️" \
                    "La batería está baja (<span font='10pt' weight='bold'>${battery_percentage}%</span>) y <b>NO</b> está cargando. Una actualización del sistema puede tardar mucho y si se interrumpe por falta de energía, podría dañar el sistema.\n\n<b>¿Deseas continuar a pesar de este riesgo CRÍTICO?</b>" 500 "dialog-warning"; then
                    log_info "Actualización abortada por baja batería."
                    exit 0
                fi
                log_warning "Continuando con la actualización a pesar de la batería baja. Riesgo de fallo por interrupción de energía."
            fi
        fi
    fi

    if [ "$battery_detected" -eq 0 ]; then
        if [ -f "/sys/class/power_supply/AC/online" ] && [ "$(cat /sys/class/power_supply/AC/online)" -eq 0 ]; then
            stop_pulsating_progress "$yad_pid"
            if ! ask_question "⚠️ Advertencia: Alimentación no Conectada ⚠️" \
                "Parece que tu Raspberry Pi <b>NO</b> está conectada a la corriente (o no se detecta suministro AC).\nUna interrupción de energía durante la actualización puede <b>DAÑAR el sistema de forma IRRECUPERABLE</b>.\n\n<b>¿Deseas continuar a pesar de este riesgo CRÍTICO?</b>" 550 "dialog-warning"; then
                log_info "Actualización abortada por falta de alimentación AC."
                exit 0
            fi
            log_warning "Continuando con la actualización a pesar de no estar conectado a la corriente. Riesgo de fallo por interrupción de energía."
        else
            log_info "Alimentación AC detectada y conectada, o no aplica. OK."
        fi
    fi
    
    if [ "$battery_detected" -eq 0 ] && [ ! -f "/sys/class/power_supply/AC/online" ]; then
        log_info "No se detectó una batería ni un indicador AC/online. Saltando la comprobación de alimentación (no aplica o no se pudo verificar)."
    else
        log_info "Verificación de batería/alimentación: Completada. OK."
    fi
    stop_pulsating_progress "$yad_pid"
}

handle_third_party_repos() {
    log_info "Gestionando repositorios de terceros (no-Debian/Raspberry Pi)..."
    local yad_pid=""
    yad_pid=$(start_pulsating_progress "🔍 Analizando Repositorios" "Buscando repositorios de software de terceros (no oficiales) en tu sistema...")

    local third_party_repo_files=()

    while IFS= read -r file; do
        if ! grep -qE "deb(\-src)?\s+(http|https)://(deb\.debian\.org|raspbian\.raspberrypi\.org|archive\.raspberrypi\.org)" "$file"; then
            third_party_repo_files+=("$(basename "$file")")
            log_info "Repositorio de terceros detectado: $file"
        fi
    done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f -name "*.list" 2>/dev/null || true)

    stop_pulsating_progress "$yad_pid"

    if [ ${#third_party_repo_files[@]} -gt 0 ]; then
        local third_party_files_escaped=$(escape_pango_text "$(printf "%s\n" "${third_party_repo_files[@]}")")
        if ask_question "⚠️ Advertencia: Repositorios de Terceros Detectados ⚠️" \
            "Se detectaron los siguientes repositorios de terceros que NO son oficiales de Debian/Raspberry Pi OS:\n\n<span font='10pt' weight='bold'>$third_party_files_escaped</span>\n\nEstos pueden causar <b>CONFLICTOS</b>, dependencias rotas o no funcionar después de una actualización mayor.\n\n<b>¿Deseas deshabilitarlos (comentarlos) temporalmente ANTES de la actualización?</b>\n\n<span font='9pt'>(Puedes volver a habilitarlos manualmente después si es necesario, adaptándolos a la nueva versión si existen repositorios compatibles.)</span>" 600 "dialog-warning"; then
            log_info "Usuario ha elegido deshabilitar repositorios de terceros."
            for file_name in "${third_party_repo_files[@]}"; do
                local full_path="/etc/apt/sources.list.d/$file_name"
                log_info "Deshabilitando repositorio: $full_path..."
                local full_path_escaped=$(escape_pango_text "$full_path")
                if ! sed -i -E 's/^(deb|deb-src)/# \0/' "$full_path"; then
                    log_error "Fallo al deshabilitar el repositorio: $full_path. Se mantendrá activo."
                    show_warning_message "⚠️ Fallo al Deshabilitar Repositorio ⚠️" \
                        "Fallo al deshabilitar <b>$full_path_escaped</b>. Se mantendrá activo.\n<span font='9pt'>Por favor, revísalo manualmente.</span>" 3 "dialog-warning"
                else
                    log_info "Repositorio deshabilitado: $full_path"
                fi
            done
            log_info "Repositorios de terceros deshabilitados."
        else
            log_warning "Usuario ha elegido NO deshabilitar los repositorios de terceros. Riesgo de conflicto."
            show_warning_message "🚨 Advertencia CRÍTICA: Repositorios de Terceros Activos 🚨" \
                "Has elegido <b>NO</b> deshabilitar los repositorios de terceros. Esto podría provocar fallos o inconsistencias <b>MUY GRAVES</b> durante o después de la actualización.\n\n<b>Proceder bajo tu PROPIA responsabilidad y riesgo.</b>" 7 "dialog-error"
        fi
    else
        log_info "No se detectaron repositorios de terceros. OK."
    fi
    log_info "Gestión de repositorios de terceros: Completada."
}

# --- Funciones de Detección de Codenames (para actualización mayor de OS) ---

obtener_codenames_debian() {
    log_info "Obteniendo codenames de Debian desde endoflife.date..."
    local yad_pid=""
    yad_pid=$(start_pulsating_progress "🌐 Obteniendo Datos de Versiones" "Consultando la API de Debian (endoflife.date) para obtener las versiones disponibles...")

    local codenames
    codenames=$(curl --connect-timeout 10 --max-time 30 -sSL "https://endoflife.date/api/debian.json" | jq -r '.[].cycle')
    stop_pulsating_progress "$yad_pid"

    if [ -z "$codenames" ]; then
        show_critical_error_and_exit "<span font='10pt'>No se pudieron obtener codenames de Debian desde <b>endoflife.date</b>.</span>\n\n<span font='9pt'>Verifique la API o su conexión a internet.</span>"
    fi
    echo "$codenames"
}

obtener_codenames_rpi() {
    log_info "Obteniendo codenames de Raspberry Pi OS desde archive.raspberrypi.org/debian/dists/..."
    local yad_pid=""
    yad_pid=$(start_pulsating_progress "🌐 Obteniendo Datos de Versiones" "Consultando repositorios de Raspberry Pi OS para versiones compatibles...")
    local codenames
    codenames=$(curl --connect-timeout 10 --max-time 30 -sSL "https://archive.raspberrypi.org/debian/dists/" | grep -oP '(?<=href=")[^/"]+' | grep -v '^[.][.]$')
    stop_pulsating_progress "$yad_pid"

    if [ -z "$codenames" ]; then
        show_critical_error_and_exit "<span font='10pt'>No se pudieron obtener codenames de RPi OS desde <b>archive.raspberrypi.org</b>.</span>\n\n<span font='9pt'>Verifique la URL o su conexión.</span>"
    fi
    echo "$codenames"
}

obtener_codename_objetivo() {
    log_info "Determinando el codename objetivo de la actualización mayor..."
    local debian_codenames
    debian_codenames=$(obtener_codenames_debian) || return 1
    local rpi_codenames
    rpi_codenames=$(obtener_codenames_rpi) || return 1
    local target_codename=""

    local yad_pid=""
    yad_pid=$(start_pulsating_progress "🧠 Calculando Versión Objetivo" "Comparando las últimas versiones de Debian y Raspberry Pi OS compatibles...")

    for codename in $debian_codenames; do
        if echo "$rpi_codenames" | grep -qx "$codename"; then
            target_codename="$codename"
            break
        fi
    done

    stop_pulsating_progress "$yad_pid"

    if [ -z "$target_codename" ]; then
        show_critical_error_and_exit "<span font='10pt'>No se encontró ningún codename de Debian compatible con los repositorios de Raspberry Pi OS.</span>\n\n<span font='9pt'>Esto puede significar que no hay una versión de actualización disponible en este momento o un problema con las fuentes de información.</span>"
    fi
    log_info "Codename objetivo compatible detectado: '$(escape_pango_text "$target_codename")'."
    echo "$target_codename"
}

# Obtiene el codename actual del sistema a partir de /etc/os-release (primera opción)
# o /etc/debian_version (fallback para sistemas muy antiguos/específicos)
get_current_codename() {
    local current_codename
    current_codename=$(grep -oP 'VERSION_CODENAME=\K[^ ]+' /etc/os-release 2>/dev/null || true)
    if [ -z "$current_codename" ]; then
        log_warning "No se pudo obtener el codename actual de /etc/os-release. Intentando /etc/debian_version."
        current_codename=$(grep -oP '([a-z]+)' /etc/debian_version 2>/dev/null | tail -n 1 || true)
        if [ -z "$current_codename" ]; then
            log_error "No se pudo obtener el codename actual del sistema desde ninguna fuente. Abortando."
            return 1
        fi
    fi
    log_info "Codename actual del sistema: '$(escape_pango_text "$current_codename")'."
    echo "$current_codename"
    return 0
}

# --- Funciones de Configuración de APT (para actualización mayor de OS) ---

hacer_backup() {
    log_info "Realizando copia de seguridad de las fuentes APT en $BACKUP_BASE_DIR..."
    local yad_pid=""
    yad_pid=$(start_pulsating_progress "📂 Realizando Copia de Seguridad" "Copiando archivos de configuración de APT a:\n<b>$(escape_pango_text "$BACKUP_BASE_DIR")</b>...")
    mkdir -p "$BACKUP_BASE_DIR" || show_critical_error_and_exit "<span font='10pt'>No se pudo crear el directorio de copia de seguridad: <b>$(escape_pango_text "$BACKUP_BASE_DIR")</b>.</span>\n\n<span font='9pt'>Verifique permisos o espacio en disco.</span>"

    cp -a /etc/apt/sources.list "$BACKUP_BASE_DIR/" || show_critical_error_and_exit "<span font='10pt'>Fallo al copiar <b>/etc/apt/sources.list</b>.</span>\n\n<span font='9pt'>No se puede continuar sin una copia de seguridad completa.</span>"
    
    if [ -d "/etc/apt/sources.list.d" ]; then
        cp -a /etc/apt/sources.list.d "$BACKUP_BASE_DIR/" || log_error "Fallo al copiar /etc/apt/sources.list.d. Continuará, pero considere revisar manualmente el backup."
        log_info "Copia de seguridad de /etc/apt/sources.list.d completada."
    else
        log_info "/etc/apt/sources.list.d no existe, no se copió."
    fi
    stop_pulsating_progress "$yad_pid"
    log_info "Copia de seguridad de fuentes APT completada en <b>$(escape_pango_text "$BACKUP_BASE_DIR")</b>."
    show_info_message "✅ Copia de Seguridad Realizada ✅" \
        "<span font='10pt'>Se ha creado una copia de seguridad completa de tus fuentes APT en:</span>\n\n<b><span font='10pt' foreground='blue'>$(escape_pango_text "$BACKUP_BASE_DIR")</span></b>\n\n<span font='9pt'>Guarda esta ruta por si necesitas restaurar manualmente.</span>" 550 "dialog-ok"
}

actualizar_codenames() {
    local nuevo_codename="$1"
    local all_debian_codenames_list=$(obtener_codenames_debian)

    log_info "Actualizando codenames en archivos de repositorios a '$(escape_pango_text "$nuevo_codename")'..."
    local yad_pid=""
    yad_pid=$(start_pulsating_progress "🔄 Actualizando Fuentes APT" "Modificando archivos de repositorio para apuntar a <b>$(escape_pango_text "$nuevo_codename")</b>...")

    find /etc/apt/ -type f -name "*.list" -print0 | while IFS= read -r -d $'\0' file; do
        local modified_file=0
        local temp_file=$(mktemp)

        while IFS= read -r line; do
            local new_line="$line"
            if [[ "$line" =~ ^(deb|deb-src) ]]; then
                for word in $line; do
                    if [[ "$word" =~ ^[a-z]+$ ]] && grep -qwx "$word" <<< "$all_debian_codenames_list"; then
                        if [ "$word" != "$nuevo_codename" ]; then
                            new_line=$(echo "$new_line" | sed -E "s/\b$word\b/$nuevo_codename/g")
                            modified_file=1
                            log_info "  → En $(escape_pango_text "$file"): Línea modificada. Reemplazado '$(escape_pango_text "$word")' por '$(escape_pango_text "$nuevo_codename")'"
                        fi
                    fi
                done
            fi
            echo "$new_line" >> "$temp_file"
        done < "$file"

        if [ "$modified_file" -eq 1 ]; then
            log_info "Guardando cambios de $(escape_pango_text "$temp_file") a $(escape_pango_text "$file")."
            mv "$temp_file" "$file" || log_error "Fallo al guardar los cambios en $(escape_pango_text "$file"). Revise los permisos o el espacio."
        else
            rm -f "$temp_file"
            log_info "No se encontraron codenames para actualizar en $(escape_pango_text "$file")."
        fi
    done
    stop_pulsating_progress "$yad_pid"
    log_info "Proceso de actualización de codenames completado."
    show_info_message "✅ Fuentes APT Actualizadas ✅" \
        "<span font='10pt'>Los archivos de configuración de tus repositorios APT han sido actualizados para apuntar a <b>$(escape_pango_text "$nuevo_codename")</b>.</span>" 500 "dialog-ok"
}

# --- Funciones de Ejecución de APT ---

# Función para actualizar solo paquetes (apt upgrade)
perform_apt_upgrade() {
    log_info "Iniciando actualización de paquetes (apt upgrade)..."
    local apt_commands_succeeded=0

    > "$APT_TEMP_LOG" # Limpiar el log temporal de APT antes de cada ejecución

    (
        echo "0" ; echo "# <span weight='bold'>🔄 Paso 1/4:</span> Actualizando índices de paquetes (<span foreground='blue'>apt update</span>)..."
        echo "5"
        if ! apt update -y >> "$APT_TEMP_LOG" 2>&1; then
            echo "100"; echo "# <span foreground='red'>❌ Error en apt update.</span> Revisa el log: $(escape_pango_text "$APT_TEMP_LOG")"
            apt_commands_succeeded=1
        fi
        
        if grep -iqE "ERR|W:|E:" "$APT_TEMP_LOG"; then
            show_warning_message "⚠️ Advertencias en 'apt update' ⚠️" \
                "Se detectaron advertencias o errores durante 'apt update'. Por favor, revise el log detallado para más información:\n<b>$(escape_pango_text "$APT_TEMP_LOG")</b>" 3 "dialog-warning"
            log_warning "Advertencias/Errores detectados durante apt update."
        fi

        echo "30" ; echo "# <span weight='bold'>📦 Paso 2/4:</span> Descargando y preparando paquetes..."
        echo "40"
        
        echo "45" ; echo "# <span weight='bold'>🚀 Paso 3/4:</span> Ejecutando actualización de paquetes (<span foreground='blue'>apt upgrade</span>)..."
        if ! apt upgrade -y >> "$APT_TEMP_LOG" 2>&1; then
            echo "100"; echo "# <span foreground='red'>❌ Error: 'apt upgrade' falló.</span> Revisa el log: $(escape_pango_text "$APT_TEMP_LOG")"
            apt_commands_succeeded=1
        fi

        echo "90" ; echo "# <span weight='bold'>🧹 Paso 4/4:</span> Limpiando paquetes innecesarios (<span foreground='blue'>apt autoremove</span>)..."
        echo "95"
        if ! apt autoremove -y >> "$APT_TEMP_LOG" 2>&1; then
            log_error "'apt autoremove' falló. Podrías necesitar limpiar manualmente."
            show_warning_message "⚠️ Advertencia: Limpieza de Paquetes ⚠️" \
                "'apt autoremove' falló. Esto no es crítico para el funcionamiento del sistema, pero puedes necesitar limpiar manualmente después." 3 "dialog-warning"
        fi

        echo "100" ; echo "# <span weight='bold'>✅ Proceso de actualización de paquetes completado.</span>"
        return "$apt_commands_succeeded"
    ) | (
        if "$GUI_AVAILABLE"; then
            yad --progress --title="🚀 Actualizando Paquetes (apt upgrade) 🚀" \
                --text="<span font='10pt'>Iniciando la operación de actualización...</span>" \
                --percentage=0 --auto-close --no-buttons --width=500 --height=150 --center \
                --image="software-update-available" --image-on-top
        else
            local progress=0
            while read -r line; do
                if [[ "$line" =~ ^[0-9]+$ ]]; then
                    progress="$line"
                elif [[ "$line" =~ ^# ]]; then
                    echo "$line"
                fi
                echo -ne "Progreso: $progress%\r"
            done
            echo
            cat
        fi
        exit "${PIPESTATUS[0]}"
    )

    local apt_subshell_exit_status=${PIPESTATUS[0]}
    local yad_exit_status=${PIPESTATUS[1]}

    if "$GUI_AVAILABLE" && [ "$yad_exit_status" -ne 0 ]; then
        log_error "El proceso de actualización de paquetes fue cancelado por el usuario o YAD falló inesperadamente. Código de salida de YAD: $yad_exit_status"
        show_critical_error_and_exit "<span font='10pt'>La actualización fue cancelada o hubo un problema con la interfaz gráfica.</span>\n\n<span font='9pt'>Por favor, revise el log principal (<b>$(escape_pango_text "$LOG_FILE")</b>) y el log de APT (<b>$(escape_pango_text "$APT_TEMP_LOG")</b>) para más detalles.</span>"
    fi

    if [ "$apt_subshell_exit_status" -ne 0 ]; then
        log_error "Uno o más comandos APT fallaron durante la actualización de paquetes (apt upgrade). Código de salida del subshell APT: $apt_subshell_exit_status"
        show_info_message "❌ Actualización de Paquetes Fallida ❌" \
            "<span font='10pt'>La actualización de paquetes (apt upgrade) ha fallado.</span>\n\n<span font='9pt'>Por favor, revise el log detallado en <b>$(escape_pango_text "$LOG_FILE")</b> y <b>$(escape_pango_text "$APT_TEMP_LOG")</b> para diagnosticar el problema.</span>" 550 "dialog-error"
        return 1
    fi

    log_info "Actualización de paquetes (apt upgrade) completada exitosamente."
    show_info_message "🎉 ¡Actualización de Paquetes Exitosa! 🎉" \
        "<span font='10pt'>Tus paquetes han sido actualizados correctamente.</span>" 500 "dialog-apply"
    return 0
}

# Función para actualización mayor de sistema y paquetes (apt full-upgrade)
perform_full_system_upgrade() {
    log_info "Iniciando actualización mayor del sistema (apt full-upgrade)..."
    local current_codename
    if ! current_codename=$(get_current_codename); then
        show_critical_error_and_exit "<span font='10pt'>No se pudo determinar la versión actual de tu sistema.</span>\n\n<span font='9pt'>No se puede proceder con la actualización mayor.</span>"
    fi
    local current_codename_escaped=$(escape_pango_text "$current_codename")

    local codename_objetivo
    codename_objetivo=$(obtener_codename_objetivo)
    local codename_objetivo_escaped=$(escape_pango_text "$codename_objetivo")
    
    show_info_message "✨ Versión de Actualización Detectada ✨" \
        "<span font='10pt'>Tu sistema actual es <b>$current_codename_escaped</b>.</span>\n\n<span font='10pt'>Se actualizará a la versión de Debian:</span>\n\n<b><span font='12pt' foreground='darkblue' weight='bold'>$codename_objetivo_escaped</span></b>\n\n<span font='9pt'>(Basado en la última versión estable de Debian compatible con Raspberry Pi OS).</span>" 600 "dialog-ok"
    log_info "Codename objetivo detectado: '$codename_objetivo'."

    handle_third_party_repos

    if ask_question "🔍 Modo de Simulación (Dry Run) 🔍" \
        "Antes de realizar cambios reales, ¿deseas ejecutar una simulación de la actualización ('apt full-upgrade --dry-run')?\n\nEsto te mostrará qué paquetes se instalarán, actualizarán o eliminarán, <b>sin modificar el sistema</b>." 550 "dialog-question"; then
        log_info "Ejecutando simulación de apt full-upgrade..."
        local dry_run_output
        local yad_pid=""
        yad_pid=$(start_pulsating_progress "📊 Preparando Simulación" "Ejecutando 'apt full-upgrade --dry-run' para analizar los cambios...")
        dry_run_output=$(LANG=C apt full-upgrade --assume-no --dry-run 2>&1)
        stop_pulsating_progress "$yad_pid"
        
        # Escapar la salida de apt-get para Pango Markup antes de mostrarla en text-info
        local dry_run_output_escaped=$(escape_pango_text "$dry_run_output")

        if "$GUI_AVAILABLE"; then
            yad --text-info --title="📈 Simulación de Actualización 📈" --width=900 --height=600 \
                --text="<span font='10pt'>Output de 'apt full-upgrade --dry-run':</span>\n\n<tt>$dry_run_output_escaped</tt>\n\n<span font='9pt' weight='bold' foreground='blue'>¡Revisa esto cuidadosamente antes de proceder con la actualización real!</span>" \
                --button="Entendido:0" --center --wrap --read-only --geometry=900x600 \
                --image="utilities-system-monitor" --image-on-top
        else
            echo -e "\n--- SIMULACIÓN DE ACTUALIZACIÓN ---"
            echo "$dry_run_output"
            echo -e "--- FIN DE LA SIMULACIÓN ---"
        fi
        log_info "Simulación de actualización completada. Salida guardada en el log principal."

        show_info_message "✅ Simulación Completada ✅" \
            "<span font='10pt'>Revisa la simulación cuidadosamente para entender los cambios propuestos.</span>\n\n<span font='9pt'>Si estás de acuerdo, procede con la actualización real.</span>" 500 "dialog-apply"
    else
        log_info "Modo de simulación saltado por el usuario."
    fi

    if ! ask_question "🚨 CONFIRMAR ACTUALIZACIÓN MAYOR (¡IRREVERSIBLE!) 🚨" \
        "<span font='10pt'>Estás a punto de iniciar una <b>actualización mayor irreversible</b> de tu sistema a <b>'$codename_objetivo_escaped'</b>.</span>\n\n<span font='10pt' weight='bold' foreground='red'>Esto implica cambios significativos y <b>errores pueden dejar el sistema inutilizable</b>.</span>\n\n<span font='10pt' weight='bold'>\n- ¡ASEGÚRATE de haber hecho una COPIA DE SEGURIDAD de tus datos IMPORTANTES ANTES DE CONTINUAR!\n- ¡NO APAGUES la Raspberry Pi durante el proceso, o puedes CORROMPER EL SISTEMA IRRECUPERABLEMENTE!\n</b>\n\n<span font='10pt' weight='bold'>¿Estás ABSOLUTAMENTE SEGURO de que deseas continuar con la actualización REAL?</span>" 650 "dialog-error"; then
        log_info "Actualización mayor cancelada por el usuario en la confirmación final."
        show_info_message "🛑 Actualización Cancelada 🛑" "<span font='10pt'>La actualización mayor ha sido cancelada por tu seguridad.</span>" 400 "dialog-cancel"
        return 1
    fi

    log_info "Iniciando fase de backup de repositorios."
    hacer_backup
    
    log_info "Iniciando fase de actualización de codenames en los repositorios APT."
    actualizar_codenames "$codename_objetivo"

    log_info "Iniciando fase de actualización de paquetes: apt update, full-upgrade, autoremove."
    local apt_commands_succeeded=0
    > "$APT_TEMP_LOG"

    (
        echo "0" ; echo "# <span weight='bold'>🔄 Paso 1/5:</span> Actualizando índices de paquetes (<span foreground='blue'>apt update</span>)..."
        echo "5"
        if ! apt update -y >> "$APT_TEMP_LOG" 2>&1; then
            echo "100"; echo "# <span foreground='red'>❌ Error en apt update.</span> Ver log: $(escape_pango_text "$APT_TEMP_LOG")"
            apt_commands_succeeded=1
        fi
        
        if grep -iqE "ERR|W:|E:" "$APT_TEMP_LOG"; then
            show_warning_message "⚠️ Advertencias en 'apt update' ⚠️" \
                "Se detectaron advertencias o errores durante 'apt update'. Por favor, revise el log para más detalles:\n<b>$(escape_pango_text "$APT_TEMP_LOG")</b>" 3 "dialog-warning"
            log_warning "Advertencias/Errores detectados durante apt update."
        fi

        echo "20" ; echo "# <span weight='bold'>⬇️ Paso 2/5:</span> Descargando y preparando paquetes..."
        echo "30"
        
        echo "35" ; echo "# <span weight='bold'>🚀 Paso 3/5:</span> Ejecutando actualización completa del sistema (<span foreground='blue'>apt full-upgrade</span>)..."
        if ! apt full-upgrade -y >> "$APT_TEMP_LOG" 2>&1; then
            echo "100"; echo "# <span foreground='red'>❌ Error: 'apt full-upgrade' falló.</span> Ver log: $(escape_pango_text "$APT_TEMP_LOG")"
            apt_commands_succeeded=1
        fi

        if grep -q "Los siguientes paquetes han sido retenidos:" "$APT_TEMP_LOG" || \
           grep -q "Los siguientes paquetes serán ELIMINADOS:" "$APT_TEMP_LOG"; then
            show_warning_message "⚠️ ATENCIÓN: Cambios en Paquetes (full-upgrade) ⚠️" \
                "Durante 'apt full-upgrade' se RETUVIERON o ELIMINARON paquetes. Esto es CRÍTICO.\n\nEs <b>IMPRESCINDIBLE</b> revisar el log de APT para entender el impacto:\n<b>$(escape_pango_text "$APT_TEMP_LOG")</b>" 5 "dialog-warning"
            log_warning "Paquetes retenidos/eliminados durante apt full-upgrade."
        fi

        echo "90" ; echo "# <span weight='bold'>🧹 Paso 4/5:</span> Limpiando paquetes innecesarios (<span foreground='blue'>apt autoremove</span>)..."
        echo "95"
        if ! apt autoremove -y >> "$APT_TEMP_LOG" 2>&1; then
            log_error "'apt autoremove' falló. Podrías necesitar limpiar manualmente."
            show_warning_message "⚠️ Advertencia: Limpieza de Paquetes ⚠️" \
                "'apt autoremove' falló. Esto no es crítico para el funcionamiento del sistema, pero puedes necesitar limpiar manualmente después." 3 "dialog-warning"
        fi

        echo "100" ; echo "# <span weight='bold'>✅ Paso 5/5:</span> Proceso de actualización mayor completado."
        return "$apt_commands_succeeded"
    ) | (
        if "$GUI_AVAILABLE"; then
            yad --progress --title="✨ Actualizando Sistema Raspberry Pi OS ✨" \
                --text="<span font='10pt'>Iniciando la actualización mayor del sistema...</span>" \
                --percentage=0 --auto-close --no-buttons --width=600 --height=180 --center \
                --image="system-software-update" --image-on-top --vertical --pulsate-enable
        else
            local progress=0
            while read -r line; do
                if [[ "$line" =~ ^[0-9]+$ ]]; then
                    progress="$line"
                elif [[ "$line" =~ ^# ]]; then
                    echo "$line"
                fi
                echo -ne "Progreso: $progress%\r"
            done
            echo
            cat
        fi
        exit "${PIPESTATUS[0]}"
    )

    local apt_subshell_exit_status=${PIPESTATUS[0]}
    local yad_exit_status=${PIPESTATUS[1]}

    if "$GUI_AVAILABLE" && [ "$yad_exit_status" -ne 0 ]; then
        log_error "El proceso de actualización fue cancelado por el usuario o YAD falló inesperadamente. Código de salida de YAD: $yad_exit_status"
        show_critical_error_and_exit "<span font='10pt'>La actualización fue cancelada o hubo un problema con la interfaz gráfica.</span>\n\n<span font='9pt'>Por favor, revise el log principal (<b>$(escape_pango_text "$LOG_FILE")</b>) y el log de APT (<b>$(escape_pango_text "$APT_TEMP_LOG")</b>) para más detalles.</span>"
    fi

    if [ "$apt_subshell_exit_status" -ne 0 ]; then
        log_error "Uno o más comandos APT fallaron durante la actualización mayor. Código de salida del subshell APT: $apt_subshell_exit_status"
        if ask_question "❌ ¡Actualización Mayor Fallida! ¿Revertir Fuentes? ❌" \
            "<span font='10pt'>La actualización mayor de paquetes ha fallado.</span>\n\n<span font='9pt'>Se ha generado un log detallado en:\n<b>$(escape_pango_text "$APT_TEMP_LOG")</b>\n\nEste log es <b>CRUCIAL</b> para la depuración.</span>\n\n<b>¿Deseas revertir la configuración de tus repositorios APT a su estado original?</b>\n\n<span font='9pt'>(Esto <b>NO</b> revierte los paquetes que ya hayan sido instalados/actualizados. Su sistema podría quedar en un estado inconsistente y requerir intervención manual para estabilizarlo.)</span>" 650 "dialog-error"; then
            revertir_fuentes_apt
        else
            log_info "Usuario decidió no revertir las fuentes APT tras un fallo en la actualización mayor."
            show_info_message "❗ Acción Requerida: Fallo en Actualización Mayor ❗" \
                "<span font='10pt'>La actualización falló y no se revertirán las fuentes APT.</span>\n\n<span font='9pt'>Su sistema puede estar en un estado inconsistente. Por favor, revise el log principal y el log de APT para depurar el problema.</span>" 550 "dialog-error"
        fi
        return 1
    fi

    log_info "Actualización mayor completada exitosamente."
    show_info_message "🎉 ¡Actualización Mayor Exitosa! 🎉" \
        "<span font='10pt'>Tu sistema ha sido actualizado correctamente a <b>$codename_objetivo_escaped</b>.</span>\n\n<span font='9pt'>Ahora, el último paso crítico: reiniciar.</span>" 550 "dialog-ok"
    return 0
}

revertir_fuentes_apt() {
    log_info "Iniciando reversión de las fuentes APT a partir del backup..."
    show_info_message "↩️ Reviertiendo Fuentes APT ↩️" \
        "<span font='10pt'>Se intentará restaurar los archivos de configuración de sus repositorios APT a partir de la copia de seguridad guardada en:</span>\n<b><span font='10pt' foreground='blue'>$(escape_pango_text "$BACKUP_BASE_DIR")</span></b>\n\n<span font='9pt'>Este proceso solo restaurará los archivos de configuración, <b>NO</b> los paquetes instalados.</span>" 550 "dialog-information"

    if [ ! -d "$BACKUP_BASE_DIR" ]; then
        log_error "Directorio de backup no encontrado: $BACKUP_BASE_DIR. No se puede revertir."
        show_critical_error_and_exit "<span font='10pt'>No se encontró el directorio de copia de seguridad.</span>\n\n<span font='9pt'>La reversión de las fuentes APT no es posible. Deberá restaurar manualmente si es necesario.</span>"
    fi

    local yad_pid=""
    yad_pid=$(start_pulsating_progress "🔄 Restaurando Fuentes APT" "Copiando archivos de backup a /etc/apt/...")

    if cp -a "$BACKUP_BASE_DIR/sources.list" /etc/apt/sources.list; then
        log_info "/etc/apt/sources.list restaurado desde backup."
    else
        log_error "Fallo al restaurar /etc/apt/sources.list."
        show_warning_message "⚠️ Fallo Parcial al Revertir ⚠️" \
            "<span font='10pt'>No se pudo restaurar <b>/etc/apt/sources.list</b>.</span>\n<span font='9pt'>Revise manualmente.</span>" 3 "dialog-warning"
    fi

    if [ -d "$BACKUP_BASE_DIR/sources.list.d" ]; then
        log_info "Limpiando el directorio actual de /etc/apt/sources.list.d/ para evitar duplicados."
        rm -rf /etc/apt/sources.list.d/* >> "$LOG_FILE" 2>&1 || true
        
        mkdir -p /etc/apt/sources.list.d/ >> "$LOG_FILE" 2>&1 || true

        if cp -a "$BACKUP_BASE_DIR/sources.list.d/." /etc/apt/sources.list.d/; then
            log_info "/etc/apt/sources.list.d/ restaurado desde backup."
        else
            log_error "Fallo al restaurar /etc/apt/sources.list.d/."
            show_warning_message "⚠️ Fallo Parcial al Revertir ⚠️" \
                "<span font='10pt'>No se pudo restaurar <b>/etc/apt/sources.list.d/</b>.</span>\n<span font='9pt'>Revise manualmente.</span>" 3 "dialog-warning"
        fi
    else
        log_info "No hay backup de /etc/apt/sources.list.d/, saltando restauración de este directorio."
    fi
    stop_pulsating_progress "$yad_pid"


    log_info "Intentando 'apt update' después de la reversión de fuentes..."
    yad_pid=$(start_pulsating_progress "Finalizando Reversión" "Ejecutando 'apt update' para asegurar la consistencia del sistema...")
    if apt update -y >> "$LOG_FILE" 2>&1; then
        log_info "'apt update' exitoso después de la reversión."
        stop_pulsating_progress "$yad_pid"
        show_info_message "✅ Reversión Completada y APT Actualizado ✅" \
            "<span font='10pt'>Las fuentes de sus repositorios APT han sido restauradas a su estado original y 'apt update' se ejecutó con éxito.</span>" 550 "dialog-apply"
    else
        log_error "'apt update' falló después de la reversión. Puede que haya problemas residuales."
        stop_pulsating_progress "$yad_pid"
        show_warning_message "❌ Advertencia Post-Reversión: Fallo en 'apt update' ❌" \
            "<span font='10pt'>'apt update' falló después de restaurar las fuentes.</span>\n\n<span font='9pt'>Su sistema puede estar en un estado inconsistente. Por favor, revise el log principal.</span>" 3 "dialog-error"
    fi

    show_info_message "ℹ️ Reversión de Fuentes APT Completada ℹ️" \
        "<span font='10pt'><b>IMPORTANTE:</b> Esto NO revierte los paquetes que ya hayan sido instalados o actualizados.</span>\n\n<span font='9pt'>Su sistema puede estar en un estado mixto y requerir intervención manual para estabilizarlo.</span>\n\n<span font='9pt'>Revise el log (<b>$(escape_pango_text "$LOG_FILE")</b>) para más detalles.</span>" 550 "dialog-information"
    log_info "Reversión de fuentes APT completada. Se ha notificado al usuario el estado mixto."
    return 0
}

# --- Función Principal del Script Interactivo ---
main() {
    > "$LOG_FILE"
    log_info "-------------------------------------------------------------"
    log_info "INICIO DE LA EJECUCIÓN DEL SCRIPT DE ACTUALIZACIÓN"
    log_info "Fecha y Hora: $(date)"
    log_info "-------------------------------------------------------------"

    show_info_message "👋 ¡Bienvenido al Actualizador de Raspberry Pi OS! 👋" \
        "<span font='10pt'>Este script te ayudará a mantener tu sistema actualizado y funcionando perfectamente.</span>\n\n<span font='9pt'>Por favor, sigue las instrucciones cuidadosamente.</span>" 550 "applications-system"

    log_info "Iniciando verificaciones pre-ejecución..."
    check_root_permissions
    check_dependencies
    check_internet_connection
    check_disk_space
    check_apt_health
    check_battery_status
    log_info "Todas las verificaciones pre-ejecución han sido completadas con éxito."

    local choice

    while true; do
        if "$GUI_AVAILABLE"; then
            choice=$(yad --list --title="🛠️ Opciones de Actualización del Sistema 🛠️" \
                --text="<span font='10pt' weight='bold'>Elige el tipo de actualización que deseas realizar en tu Raspberry Pi OS:</span>" \
                --radiolist --column "" --column "Tipo de Actualización" --column "Descripción" \
                TRUE "Actualizar Paquetes" "<span font='9pt'>Realiza un 'apt update' y 'apt upgrade' (actualizaciones diarias de seguridad y funcionalidades).</span>" \
                FALSE "Actualizar Sistema y Paquetes (Cambio de Versión)" "<span font='9pt'>Realiza un 'apt full-upgrade' y cambia a la siguiente versión mayor de Raspberry Pi OS (ej. de Bullseye a Bookworm).<span weight='bold' foreground='red'> ¡Requiere Copia de Seguridad!</span></span>" \
                FALSE "Salir del Actualizador" "<span font='9pt'>Cierra el script de forma segura.</span>" \
                --width=700 --height=280 --button="Continuar:0" --button="Cancelar:1" --center --image="system-upgrade" --image-on-top 2>/dev/null)
            
            local yad_exit_status=$?
            if [ "$yad_exit_status" -ne 0 ]; then
                log_info "YAD fue cancelado o no se seleccionó ninguna opción. Saliendo."
                show_info_message "🛑 Operación Cancelada 🛑" "<span font='10pt'>Ninguna opción seleccionada o la operación fue cancelada. Saliendo del actualizador.</span>" 450 "dialog-cancel"
                break
            fi
        else
            echo -e "\n--- 🛠️ Opciones de Actualización del Sistema 🛠️ ---"
            echo "1) Actualizar Paquetes (apt upgrade)"
            echo "2) Actualizar Sistema y Paquetes (apt full-upgrade / Cambio de Versión)"
            echo "3) Salir del Actualizador"
            read -r -p "Elige una opción (1-3): " choice_num
            case "$choice_num" in
                1) choice="Actualizar Paquetes";;
                2) choice="Actualizar Sistema y Paquetes (Cambio de Versión)";;
                3) choice="Salir del Actualizador";;
                *) echo "Opción inválida. Intenta de nuevo."; continue;;
            esac
        fi

        case "$choice" in
            "Actualizar Paquetes")
                log_info "El usuario ha elegido: Actualizar Paquetes (apt upgrade)."
                if perform_apt_upgrade; then
                    show_info_message "✅ Actualización de Paquetes Finalizada ✅" \
                        "<span font='10pt'>La actualización de paquetes ha concluido. Si se actualizaron componentes importantes (como el kernel), se recomienda reiniciar el sistema.</span>" 550 "dialog-apply"
                else
                    show_warning_message "❌ Actualización de Paquetes No Completada ❌" \
                        "<span font='10pt'>La actualización de paquetes no se completó con éxito.</span>\n\n<span font='9pt'>Revisa el log principal (<b>$(escape_pango_text "$LOG_FILE")</b>) y el log de APT (<b>$(escape_pango_text "$APT_TEMP_LOG")</b>) para más detalles.</span>" 550 "dialog-error"
                fi
                ;;
            "Actualizar Sistema y Paquetes (Cambio de Versión)")
                log_info "El usuario ha elegido: Actualizar Sistema y Paquetes (apt full-upgrade / Cambio de Versión)."
                if perform_full_system_upgrade; then
                    show_info_message "🎉 ¡Actualización Mayor Finalizada! 🎉" \
                        "<span font='10pt'>La actualización mayor del sistema ha concluido. ¡Es <b>IMPRESCINDIBLE</b> reiniciar ahora para aplicar todos los cambios!</span>" 550 "dialog-ok"
                    if ask_question "🔄 REINICIAR AHORA (¡RECOMENDADO ENCARECIDAMENTE!) 🔄" \
                        "<span font='10pt'>La actualización ha finalizado con éxito.</span>\n\n<span font='10pt' weight='bold' foreground='blue'>Es IMPRESCINDIBLE reiniciar tu sistema AHORA</span> <span font='9pt'>para aplicar todos los cambios del kernel, librerías y asegurar la estabilidad.</span>\n\n<b>¿Deseas reiniciar tu Raspberry Pi ahora?</b>" 550 "system-restart-panel"; then
                        log_info "Reinicio solicitado por el usuario. Iniciando 'systemctl reboot'."
                        show_info_message "🚀 Reiniciando Sistema... 🚀" "<span font='10pt'>Tu sistema se reiniciará en breve para aplicar todos los cambios.</span>" 400 "system-reboot"
                        systemctl reboot
                    else
                        log_info "Reinicio pospuesto por el usuario. Advertencia de reinicio manual pendiente."
                        show_info_message "⚠️ Actualización Mayor Completada (Reinicio Pendiente) ⚠️" \
                            "<span font='10pt'>La actualización mayor se completó correctamente.</span>\n\n<span font='9pt' weight='bold'>Recuerda reiniciar tu Raspberry Pi tan pronto como sea posible</span> <span font='9pt'>para que todos los cambios surtan efecto y evitar posibles inestabilidades.</span>" 550 "dialog-warning"
                    fi
                else
                    show_warning_message "❌ Actualización Mayor No Completada ❌" \
                        "<span font='10pt'>La actualización mayor del sistema no se completó con éxito o fue cancelada.</span>\n\n<span font='9pt'>Revisa los logs para detalles y actúa según sea necesario.</span>" 550 "dialog-error"
                fi
                ;;
            "Salir del Actualizador")
                log_info "El usuario ha elegido: Salir del Actualizador."
                show_info_message "👋 Saliendo del Actualizador 👋" "<span font='10pt'>Gracias por usar el Actualizador de Raspberry Pi OS. ¡Que tengas un gran día!</span>" 450 "application-exit"
                break
                ;;
            *)
                log_warning "Opción de menú inválida. Volviendo a mostrar el menú."
                continue
                ;;
        esac
    done

    log_info "-------------------------------------------------------------"
    log_info "FIN DE LA EJECUCIÓN DEL SCRIPT DE ACTUALIZACIÓN"
    log_info "-------------------------------------------------------------"
}

main "$@"
