#!/bin/zsh
#
# install_block_usb_storage.sh
# Instalador para despliegue vía Microsoft Intune (macOS Shell Script).
#
# Este script NO expulsa discos por sí mismo: instala el script de
# bloqueo y su LaunchDaemon en el equipo, para que el bloqueo quede
# persistente en el sistema (no depende de que Intune lo re-ejecute).
#
# Configuración recomendada en Intune:
#   - Run script as signed-in user: NO  (debe correr como root)
#   - Script frequency: Not configured (una sola vez es suficiente,
#     ya que instala un LaunchDaemon persistente). Opcionalmente,
#     puedes dejarlo en "Every day" como verificación de integridad;
#     el script detecta si ya está instalado y no duplica nada.
#
# Compatible con macOS Ventura (13) y Sonoma (14).

set -e

INSTALL_LOG="/var/log/usb_block_install.log"
WORKER_PATH="/usr/local/sbin/block_usb_storage.sh"
DAEMON_LABEL="com.empresa.blockusb"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
DATE=$(date "+%Y-%m-%d %H:%M:%S")

log() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") - $1" >> "$INSTALL_LOG"
}

log "=== Iniciando instalación/verificación del bloqueo de USB ==="

# --- 1. Crear el script worker (el que expulsa los discos USB) ---
cat << 'WORKER_EOF' > "$WORKER_PATH"
#!/bin/zsh
#
# block_usb_storage.sh
# Expulsa automáticamente cualquier volumen montado que provenga de un
# dispositivo de almacenamiento conectado por USB.

LOGFILE="/var/log/usb_block.log"
DATE=$(date "+%Y-%m-%d %H:%M:%S")

for VOL in /Volumes/*; do
    if [[ "$VOL" == "/Volumes/Macintosh HD" || "$VOL" == "/Volumes/Macintosh HD - Data" ]]; then
        continue
    fi

    PROTOCOL=$(diskutil info "$VOL" 2>/dev/null | grep -i "Protocol" | grep -i "USB")

    if [[ -n "$PROTOCOL" ]]; then
        echo "$DATE - Dispositivo USB detectado y bloqueado: $VOL" >> "$LOGFILE"
        diskutil unmountDisk force "$VOL" >> "$LOGFILE" 2>&1
    fi
done
WORKER_EOF

chown root:wheel "$WORKER_PATH"
chmod 755 "$WORKER_PATH"
log "Script worker instalado en $WORKER_PATH"

# --- 2. Crear el LaunchDaemon ---
cat << PLIST_EOF > "$DAEMON_PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${DAEMON_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${WORKER_PATH}</string>
    </array>

    <key>WatchPaths</key>
    <array>
        <string>/Volumes</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardErrorPath</key>
    <string>/var/log/usb_block_error.log</string>
</dict>
</plist>
PLIST_EOF

chown root:wheel "$DAEMON_PLIST"
chmod 644 "$DAEMON_PLIST"
log "LaunchDaemon creado en $DAEMON_PLIST"

# --- 3. Cargar (o recargar) el LaunchDaemon de forma idempotente ---
# Si ya estaba cargado (ej. una ejecución anterior de Intune), lo
# descargamos primero para evitar el error "service already loaded".
if launchctl print system/"${DAEMON_LABEL}" >/dev/null 2>&1; then
    log "El LaunchDaemon ya estaba cargado. Recargando para aplicar cambios..."
    launchctl bootout system/"${DAEMON_LABEL}" >/dev/null 2>&1 || true
    sleep 1
fi

launchctl bootstrap system "$DAEMON_PLIST"

# --- 4. Verificación final ---
if launchctl print system/"${DAEMON_LABEL}" >/dev/null 2>&1; then
    log "Verificación exitosa: ${DAEMON_LABEL} está cargado y activo."
    log "=== Instalación completada correctamente ==="
    exit 0
else
    log "ERROR: no se pudo verificar que el LaunchDaemon quedó activo."
    exit 1
fi
