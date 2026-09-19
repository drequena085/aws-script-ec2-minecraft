# ⛏️ AWS Script EC2 Minecraft

Automatización completa de un servidor de Minecraft en AWS: despliega una instancia EC2 bajo demanda mediante AWS Lambda, configura el entorno automáticamente y destruye la instancia cuando no hay jugadores conectados para minimizar costos.

---

## 📋 Tabla de Contenidos

- [Descripción General](#-descripción-general)
- [Arquitectura](#-arquitectura)
- [Requisitos Previos](#-requisitos-previos)
- [Estructura del Proyecto](#-estructura-del-proyecto)
- [Configuración](#-configuración)
- [Despliegue](#-despliegue)
- [Uso](#-uso)
- [Funcionamiento Interno](#-funcionamiento-interno)
- [Seguridad](#-seguridad)
- [Costos Estimados](#-costos-estimados)
- [Solución de Problemas](#-solución-de-problemas)
- [Licencia](#-licencia)

---

## 🎯 Descripción General

Este proyecto permite lanzar un servidor de Minecraft **a demanda** en AWS, pagando solo por el tiempo que realmente se usa. La arquitectura sigue un patrón serverless donde:

1. **Un jugador solicita el servidor** → una Lambda crea la instancia EC2.
2. **La EC2 se autoconfigura** → instala Java, descarga el mundo desde S3, configura DuckDNS y arranca Minecraft.
3. **Cuando no hay jugadores** → un script de auto-apagado guarda el mundo en S3, invoca la Lambda de destrucción y termina la instancia.

---

## 🏗️ Arquitectura

```
┌─────────────┐     HTTP + Token     ┌──────────────────────────┐
│   Jugador   │ ──────────────────►  │  Lambda: StartMinecraft  │
│  (Browser)  │                      │  Server.py               │
└─────────────┘                      └────────────┬─────────────┘
                                                  │ ec2.run_instances()
                                                  ▼
                                     ┌──────────────────────────┐
                                     │   EC2 (t2.large)         │
                                     │   ┌──────────────────┐   │
                                     │   │ scriptEc2.sh     │   │
                                     │   │  • Java 17       │   │
                                     │   │  • DuckDNS       │   │
                                     │   │  • S3 download   │   │
                                     │   │  • Minecraft.jar │   │
                                     │   │  • Auto-stop     │   │
                                     │   └──────────────────┘   │
                                     └────────────┬─────────────┘
                                                  │ Sin jugadores (10 min)
                                                  ▼
                                     ┌──────────────────────────┐
                                     │  Lambda: DestroyMinecraft│
                                     │  Server.py               │
                                     │  • Backup mundo → S3     │
                                     │  • Terminar instancia    │
                                     └──────────────────────────┘
```

---

## ✅ Requisitos Previos

| Servicio / Herramienta | Detalle |
|---|---|
| **Cuenta AWS** | Con permisos para EC2, Lambda, S3 e IAM |
| **Amazon S3** | Un bucket con el archivo `.tar` del servidor de Minecraft |
| **Security Group** | Puerto `25565/TCP` (Minecraft) abierto. Opcionalmente `22/TCP` (SSH) |
| **IAM Role** | Para la instancia EC2 con permisos de S3 (lectura/escritura) y Lambda (invocación) |
| **DuckDNS** | Cuenta gratuita en [duckdns.org](https://www.duckdns.org/) con un dominio registrado |
| **Python 3.x** | Con `boto3` (incluido en el runtime de Lambda) |
| **AMI** | Amazon Linux 2023 (`ami-xxxxxxxxx`) |
| **Key Pair** *(opcional)* | Para acceso SSH a la instancia |

---

## 📁 Estructura del Proyecto

```
aws-script-ec2-minecraft/
├── StartMinecraftServer.py   # Lambda — Crea la instancia EC2
├── DestroyMinecraftServer.py # Lambda — Destruye la instancia EC2
├── scriptEc2.sh              # UserData — Configuración completa de la EC2
└── README.md                 # Documentación del proyecto
```

| Archivo | Propósito |
|---|---|
| [`StartMinecraftServer.py`](StartMinecraftServer.py) | Función Lambda que lanza una nueva instancia EC2 con el script de UserData. Valida token de seguridad y verifica que no exista ya una instancia activa. |
| [`DestroyMinecraftServer.py`](DestroyMinecraftServer.py) | Función Lambda que termina la instancia EC2 del servidor. Busca por tag o ID directo. Incluye validación de token. |
| [`scriptEc2.sh`](scriptEc2.sh) | Script Bash de configuración que se ejecuta como UserData al iniciar la EC2. Instala dependencias, configura DuckDNS, descarga el servidor desde S3, crea el servicio systemd y configura el auto-apagado. |

---

## ⚙️ Configuración

### 1. `StartMinecraftServer.py`

Edita las siguientes variables al inicio del archivo:

```python
AMI_ID = "ami-xxxxxxxxxxxxxxxxx"        # AMI de Amazon Linux 2023
INSTANCE_TYPE = "t2.large"              # Tipo de instancia (2 vCPU, 8 GB RAM)
SECURITY_GROUP_ID = "sg-xxxxxxxxxxxx"   # Security Group con puerto 25565 abierto
IAM_ROLE_ARN = "arn:aws:iam::123456789012:instance-profile/TuRolMinecraft"
KEY_NAME = "tu-keypair"                 # Key Pair para SSH (opcional)
SECRET_TOKEN = "secret_token"           # Token de autenticación para la API

SERVER_TAG_KEY = 'key'                  # Clave del tag para identificar la instancia
SERVER_TAG_VALUE = 'value'              # Valor del tag
```

### 2. `DestroyMinecraftServer.py`

```python
SECRET_TOKEN = "secret_token"           # Debe coincidir con el de Start
SERVER_TAG_KEY = 'key'                  # Misma clave de tag
SERVER_TAG_VALUE = 'value'              # Mismo valor de tag
```

### 3. `scriptEc2.sh`

```bash
S3_BUCKET="s3://bucket_name"            # Bucket S3 con el .tar del servidor
SERVER_TAR="file_name.tar"              # Nombre del archivo .tar
DUCKDNS_DOMAIN="domain_name"            # Subdominio en DuckDNS (sin .duckdns.org)
DUCKDNS_TOKEN="token"                   # Token de DuckDNS
JAVA_RAM_MIN="4G"                       # RAM mínima para la JVM (-Xms)
JAVA_RAM_MAX="8G"                       # RAM máxima para la JVM (-Xmx)
```

> [!IMPORTANT]
> Asegúrate de que el token en `autostop.sh` (línea `token_value` dentro del payload de Lambda) coincida con el `SECRET_TOKEN` de `DestroyMinecraftServer.py`.

---

## 🚀 Despliegue

### Paso 1 — Preparar el servidor Minecraft en S3

```bash
# Empaqueta tu carpeta de servidor Minecraft
tar -cf mi-servidor.tar -C /ruta/a/mi/servidor .

# Sube el .tar a tu bucket S3
aws s3 cp mi-servidor.tar s3://tu-bucket/mi-servidor.tar
```

### Paso 2 — Crear las funciones Lambda

1. Crea una función Lambda con runtime **Python 3.12**.
2. Sube `StartMinecraftServer.py` como código fuente.
3. Asigna un rol IAM con permisos: `ec2:RunInstances`, `ec2:DescribeInstances`, `ec2:CreateTags`, `iam:PassRole`.
4. Configura un **Function URL** o **API Gateway** para exponer el endpoint HTTP.
5. Repite para `DestroyMinecraftServer.py` con permisos: `ec2:TerminateInstances`, `ec2:DescribeInstances`.

### Paso 3 — Configurar el UserData

En `StartMinecraftServer.py`, asigna el contenido de `scriptEc2.sh` a la variable `USER_DATA_SCRIPT` (ya parametrizado con tus valores).

### Paso 4 — Configurar IAM Role para la EC2

El rol de la instancia EC2 necesita:

| Permiso | Servicio | Motivo |
|---|---|---|
| `s3:GetObject`, `s3:PutObject` | Amazon S3 | Descargar y subir el backup del mundo |
| `s3:ListBucket` | Amazon S3 | Verificar existencia del archivo |
| `lambda:InvokeFunction` | AWS Lambda | Auto-destrucción al detectar inactividad |

---

## 📖 Uso

### Iniciar el servidor

Realiza una petición HTTP al endpoint de la Lambda `StartMinecraftServer`:

```bash
curl "https://tu-lambda-url.amazonaws.com/?token=tu_secret_token"
```

**Respuestas posibles:**

| Código | Significado |
|---|---|
| `200` | Instancia creada exitosamente (incluye `instance_id`) |
| `200` | El servidor ya se encuentra en ejecución |
| `403` | Token inválido |

### Conectarse al servidor

Una vez que la instancia esté lista (~2-3 minutos), conéctate desde Minecraft usando:

```
tu-dominio.duckdns.org:25565
```

### Detener el servidor

El servidor se detiene **automáticamente** tras **10 minutos sin jugadores**. También puedes destruirlo manualmente:

```bash
curl "https://tu-lambda-destroy-url.amazonaws.com/?token=tu_secret_token"
```

---

## 🔧 Funcionamiento Interno

### Flujo de inicio (`scriptEc2.sh`)

1. **Actualiza paquetes** e instala Java 17 (Corretto), AWS CLI, tmux, tar y cronie.
2. **Configura 2 GB de Swap** para absorber picos de memoria.
3. **Registra la IP pública en DuckDNS** y programa una actualización cada 5 minutos via cron.
4. **Crea el usuario `minecraft`** para ejecución segura (no root).
5. **Genera `start.sh`** — Descarga el `.tar` desde S3, lo extrae y ejecuta `server.jar`.
6. **Genera `stop.sh`** — Empaqueta el directorio del servidor y lo sube a S3 como backup.
7. **Genera `autostop.sh`** — Cada 5 minutos verifica conexiones TCP en el puerto 25565. Tras 2 verificaciones sin jugadores (10 minutos), detiene el servicio e invoca la Lambda de destrucción.
8. **Crea un servicio systemd** (`minecraft.service`) que ejecuta `start.sh` al arrancar y `stop.sh` al detenerse.

### Auto-apagado por inactividad

```
Cada 5 min (cron) → autostop.sh
    ├── ¿Hay jugadores en puerto 25565?
    │   ├── SÍ → Resetear contador
    │   └── NO → Incrementar contador
    │       ├── Contador < 2 → Esperar
    │       └── Contador ≥ 2 → Detener servicio
    │           ├── stop.sh → Backup a S3
    │           └── Invocar Lambda DestroyMinecraftServer
    │               └── ec2.terminate_instances()
    └── Gracia de 5 min tras boot (evita falsos positivos)
```

---

## 🔒 Seguridad

- **Autenticación por token**: Ambas Lambdas requieren un `SECRET_TOKEN` en el query string para operar.
- **Prevención de duplicados**: `StartMinecraftServer` verifica que no exista ya una instancia activa antes de crear una nueva.
- **Usuario no-root**: El servidor Minecraft se ejecuta bajo el usuario `minecraft`, no como root.
- **IMDSv2**: El script de auto-apagado utiliza Instance Metadata Service v2 (token-based) para obtener el ID de instancia.
- **EBS efímero**: El volumen EBS se elimina automáticamente al terminar la instancia (`DeleteOnTermination: True`).

> [!WARNING]
> - Cambia el valor de `SECRET_TOKEN` por un token seguro y único antes de desplegar.
> - No expongas los endpoints de las Lambdas sin autenticación adicional en entornos de producción.
> - Considera usar AWS Secrets Manager o SSM Parameter Store para gestionar los tokens.

---

## 💰 Costos Estimados

| Recurso | Costo aproximado (us-east-1) |
|---|---|
| **EC2 `t2.large`** | ~$0.0928/hora |
| **EBS gp3 (8 GB)** | ~$0.64/mes |
| **Lambda (2 funciones)** | Prácticamente gratis (Free Tier) |
| **S3 (almacenamiento)** | ~$0.023/GB/mes |
| **DuckDNS** | Gratis |

> [!TIP]
> Si juegas 4 horas al día, el costo mensual de EC2 sería aproximadamente **~$11.14/mes** (~0.0928 × 4 × 30). Comparado con un hosting dedicado de Minecraft (~$15-30/mes), esta solución puede ser más económica y flexible.

---

## 🐛 Solución de Problemas

| Problema | Causa posible | Solución |
|---|---|---|
| La Lambda devuelve `403` | Token incorrecto | Verifica que el `token` en la URL coincida con `SECRET_TOKEN` |
| La instancia se crea pero no arranca Minecraft | Error en UserData | Revisa `/var/log/cloud-init-output.log` en la EC2 vía SSH |
| No se puede conectar al servidor | Security Group cerrado | Verifica que el puerto `25565/TCP` esté abierto en el SG |
| El servidor se apaga muy rápido | Auto-stop activado antes de tiempo | Verifica que el tiempo de gracia (5 min) sea suficiente en `autostop.sh` |
| El mundo no se guarda | Permisos de S3 insuficientes | Verifica el IAM Role de la EC2 tenga `s3:PutObject` |
| DuckDNS no actualiza la IP | Token o dominio incorrecto | Revisa `/opt/duckdns/duck.log` en la EC2 |

---

## 📄 Licencia

Este proyecto es de código abierto. Siéntete libre de usarlo, modificarlo y distribuirlo.
