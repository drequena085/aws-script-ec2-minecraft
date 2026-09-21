#!/bin/bash
set -e

# ==============================================================================
# CONFIGURACIÓN DE VARIABLES DEL SERVIDOR
# Modifica únicamente este bloque al desplegar una nueva instancia/servidor
# ==============================================================================
S3_BUCKET="s3://bucket_name"
SERVER_TAR="file_name.tar"           # Nombre del archivo .tar en tu bucket S3
DUCKDNS_DOMAIN="domain_name"           # Ejemplo: "miservermine" (sin .duckdns.org)
DUCKDNS_TOKEN="token"                 # Tu token de DuckDNS
JAVA_RAM_MIN="8G"                        # Memoria RAM inicial para la JVM (-Xms)
JAVA_RAM_MAX="8G"                        # Memoria RAM máxima para la JVM (-Xmx)
TOKEN_LAMBDA="token_value"              # Token de seguridad que espera la función lambda
# ==============================================================================

# 1. Instalar dependencias (Java 17, AWS CLI, cronie)
dnf update -y
dnf install -y java-17-amazon-corretto-headless aws-cli tmux tar cronie

systemctl enable --now crond

# 2. Configurar memoria Swap (2 GB) para absorción del SO y picos de la JVM
if [ ! -f /swapfile ]; then
    echo "Creando archivo Swap de 2 GB..."
    dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
    echo "Swap configurada."
fi

# 3. Configurar DuckDNS
mkdir -p /opt/duckdns
cat << EOF > /opt/duckdns/duck.sh
#!/bin/bash
echo url="https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=" | curl -k -s -o /opt/duckdns/duck.log -K -
EOF

chmod +x /opt/duckdns/duck.sh

cat << EOF > /etc/cron.d/duckdns
@reboot root /opt/duckdns/duck.sh
*/5 * * * * root /opt/duckdns/duck.sh
EOF

/opt/duckdns/duck.sh

# 4. Crear carpetas y usuario de ejecución
mkdir -p /opt/minecraft/server
useradd -m -s /bin/bash minecraft || true

# 5. Crear script de inicio (start.sh) inyectando las variables parametrizadas
cat << EOF > /opt/minecraft/start.sh
#!/bin/bash
set -e
MC_DIR="/opt/minecraft/server"
S3_BUCKET="${S3_BUCKET}"
TAR_FILE="${SERVER_TAR}"

mkdir -p "\$MC_DIR"
cd "\$MC_DIR"

echo "Descargando \$TAR_FILE desde \$S3_BUCKET..."
if aws s3 ls "\$S3_BUCKET/\$TAR_FILE" > /dev/null 2>&1; then
    aws s3 cp "\$S3_BUCKET/\$TAR_FILE" /tmp/\$TAR_FILE
    
    echo "Extrayendo servidor..."
    tar -xf /tmp/\$TAR_FILE -C "\$MC_DIR"
    rm -f /tmp/\$TAR_FILE
else
    echo "ERROR: No se encontró \$TAR_FILE en \$S3_BUCKET"
    exit 1
fi

if [ ! -f "server.jar" ]; then
    echo "ERROR: server.jar no fue encontrado en \$MC_DIR"
    exit 1
fi

echo "Iniciando servidor de Minecraft con Java 17..."
exec java -Xms${JAVA_RAM_MIN} -Xmx${JAVA_RAM_MAX} \
  -XX:+UseG1GC \
  -XX:+ParallelRefProcEnabled \
  -XX:MaxGCPauseMillis=200 \
  -XX:+UnlockExperimentalVMOptions \
  -XX:+DisableExplicitGC \
  -XX:G1NewSizePercent=30 \
  -XX:G1MaxNewSizePercent=40 \
  -XX:G1HeapRegionSize=8M \
  -XX:G1ReservePercent=20 \
  -XX:G1HeapWastePercent=5 \
  -XX:G1MixedGCCountTarget=4 \
  -jar server.jar nogui
EOF

# 6. Crear script de guardado/parada (stop.sh) inyectando las variables parametrizadas
cat << EOF > /opt/minecraft/stop.sh
#!/bin/bash
MC_DIR="/opt/minecraft/server"
S3_BUCKET="${S3_BUCKET}"
TAR_FILE="${SERVER_TAR}"

cd "\$MC_DIR"

echo "Proceso Java finalizado. Empaquetando servidor en \$TAR_FILE..."
tar -cf /tmp/\$TAR_FILE .

echo "Subiendo \$TAR_FILE a S3..."
aws s3 cp /tmp/\$TAR_FILE "\$S3_BUCKET/\$TAR_FILE"

rm -f /tmp/\$TAR_FILE
echo "Respaldo en S3 completado con éxito."
EOF

# Asignar permisos ejecutables y propietario
chmod +x /opt/minecraft/*.sh
chown -R minecraft:minecraft /opt/minecraft

# Script de auto-apagado por inactividad
mkdir -p /opt/minecraft
cat << 'EOF' > /opt/minecraft/autostop.sh
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PORT=25565
INACTIVE_FILE="/tmp/inactive_count"

# 1. No contar si el servicio ya se está deteniendo o está apagado
if ! systemctl is-active --quiet minecraft.service; then
    rm -f "$INACTIVE_FILE"
    exit 0
fi

# 2. Tiempo de gracia de 5 minutos tras iniciar la EC2
UPTIME=$(cut -d. -f1 /proc/uptime)
if [ "$UPTIME" -lt 300 ]; then
    rm -f "$INACTIVE_FILE"
    exit 0
fi

# 3. Detección mejorada de conexiones (TCP en estado ESTABLISHED)
CONNECTIONS=$(ss -tun state established "( dport = :$PORT or sport = :$PORT )" | grep -v "Recv-Q" | wc -l)

if [ "$CONNECTIONS" -eq 0 ]; then
    if [ -f "$INACTIVE_FILE" ]; then
        COUNT=$(cat "$INACTIVE_FILE")
        COUNT=$((COUNT + 1))
    else
        COUNT=1
    fi
    echo "$COUNT" > "$INACTIVE_FILE"

    # Requiere 2 chequeos consecutivos (10 min sin ningún jugador)
    if [ "$COUNT" -ge 2 ]; then
        echo "Inactividad detectada por 10 minutos. Deteniendo servidor..."
        rm -f "$INACTIVE_FILE"
        systemctl stop minecraft.service
        
        # Obtención segura de INSTANCE_ID (IMDSv2)
        TOKEN=$(curl -s -S -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
        INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
        if [ -z "$INSTANCE_ID" ]; then
            INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
        fi

        # Invocación compatible con AWS CLI v2 usando comillas sencillas en el JSON exterior
        aws lambda invoke \
          --region us-east-1 \
          --function-name DestroyMinecraftServer \
          --cli-binary-format raw-in-base64-out \
          --payload '{"instance_id": "'"$INSTANCE_ID"'", "token": "${TOKEN_LAMBDA}"}' \
          /tmp/lambda_out.json
    fi
else
    # Si hay conexiones, limpiar inmediatamente el contador
    rm -f "$INACTIVE_FILE"
fi
EOF

chmod +x /opt/minecraft/autostop.sh

# Agregar verificación cada 5 minutos en el Cron
cat << 'EOF' > /etc/cron.d/minecraft_autostop
*/5 * * * * root /opt/minecraft/autostop.sh
EOF

# 7. Crear el servicio systemd
cat << 'EOF' > /etc/systemd/system/minecraft.service
[Unit]
Description=Servidor de Minecraft automatizado con S3
After=network.target

[Service]
Type=simple
User=minecraft
WorkingDirectory=/opt/minecraft/server
ExecStart=/opt/minecraft/start.sh
ExecStopPost=/opt/minecraft/stop.sh
TimeoutStopSec=180
Restart=no

[Install]
WantedBy=multi-user.target
EOF

# 8. Habilitar e iniciar servicio
systemctl daemon-reload
systemctl enable --now minecraft
