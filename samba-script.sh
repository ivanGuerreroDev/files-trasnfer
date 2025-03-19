#!/bin/bash

# Script para configurar Samba en Rocky Linux 9.4
# Este script realiza las siguientes tareas:
# 1. Instala Samba y utilidades necesarias
# 2. Configura un directorio compartido
# 3. Configura el acceso a carpetas compartidas de Windows

# Colores para mejorar la legibilidad
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Función para mostrar mensajes de progreso
show_message() {
    echo -e "${GREEN}[+] $1${NC}"
}

# Función para mostrar mensajes de error
show_error() {
    echo -e "${RED}[!] $1${NC}"
    exit 1
}

# Función para mostrar mensajes de advertencia
show_warning() {
    echo -e "${YELLOW}[*] $1${NC}"
}

# Verificar si se está ejecutando como root
if [ "$EUID" -ne 0 ]; then
    show_error "Este script debe ejecutarse como root (sudo)."
fi

# Actualizar repositorios
show_message "Actualizando repositorios..."
dnf update -y || show_error "No se pudo actualizar los repositorios."

# 1. Instalar Samba y utilidades necesarias
show_message "Instalando Samba y utilidades necesarias..."
dnf install -y samba samba-client samba-common cifs-utils || show_error "No se pudo instalar Samba."

# 2. Configurar Samba
show_message "Configurando Samba..."

# Hacer backup del archivo de configuración original
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

# Crear un nuevo archivo de configuración de Samba
cat > /etc/samba/smb.conf << 'EOL'
[global]
    workgroup = WORKGROUP
    server string = Samba Server %v
    netbios name = Rocky
    security = user
    map to guest = bad user
    dns proxy = no
    unix extensions = no
    
    # Authentication
    passdb backend = tdbsam
    
    # Configuración para permitir acceso desde Windows 10/11
    client min protocol = SMB2
    client max protocol = SMB3
    
    # Configuración de logs
    log file = /var/log/samba/log.%m
    max log size = 1000
    logging = file
    
    # Ajustes de rendimiento
    socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=65536 SO_SNDBUF=65536
    
    # Soporte para permisos extendidos
    vfs objects = acl_xattr
    map acl inherit = yes
    store dos attributes = yes

# Compartir un directorio para todos los usuarios autenticados
[shared]
    comment = Directorio compartido
    path = /samba/shared
    browseable = yes
    read only = no
    create mask = 0775
    directory mask = 0775
    valid users = @smbgroup
EOL

# 3. Crear estructura de directorios
show_message "Creando estructura de directorios..."
mkdir -p /samba/shared

# 4. Configurar permisos
show_message "Configurando permisos..."
groupadd smbgroup
chgrp -R smbgroup /samba/shared
chmod -R 2775 /samba/shared
semanage fcontext -a -t samba_share_t "/samba/shared(/.*)?"
restorecon -Rv /samba/shared

# 5. Configurar firewall
show_message "Configurando firewall..."
firewall-cmd --permanent --add-service=samba
firewall-cmd --reload

# 6. Habilitar e iniciar el servicio de Samba
show_message "Habilitando e iniciando Samba..."
systemctl enable smb nmb
systemctl restart smb nmb

# 7. Crear usuario Samba
show_message "Vamos a crear un usuario para Samba"
read -p "Ingrese nombre de usuario: " SMB_USER

# Verificar si el usuario existe
if id "$SMB_USER" &>/dev/null; then
    show_message "El usuario $SMB_USER ya existe"
else
    useradd -M -s /sbin/nologin $SMB_USER
    show_message "Usuario $SMB_USER creado"
fi

# Agregar usuario al grupo smbgroup
usermod -a -G smbgroup $SMB_USER

# Establecer contraseña para el usuario de Samba
show_message "Estableciendo contraseña para usuario Samba $SMB_USER"
smbpasswd -a $SMB_USER

# 8. Configurar SELinux para permitir compartir archivos
show_message "Configurando SELinux..."
setsebool -P samba_enable_home_dirs on
setsebool -P samba_export_all_rw on

# 9. Crear script para montar carpeta compartida de Windows
show_message "Creando script para montar carpeta compartida de Windows..."
cat > /usr/local/bin/mount-windows-share << 'EOL'
#!/bin/bash

# Script para montar carpeta compartida de Windows
# Uso: ./mount-windows-share.sh <IP_WINDOWS> <NOMBRE_COMPARTIDO> <USUARIO> <PUNTO_MONTAJE>

if [ $# -ne 4 ]; then
    echo "Uso: $0 <IP_WINDOWS> <NOMBRE_COMPARTIDO> <USUARIO> <PUNTO_MONTAJE>"
    echo "Ejemplo: $0 192.168.1.100 Documents usuario /mnt/windows-share"
    exit 1
fi

WINDOWS_IP=$1
SHARE_NAME=$2
WIN_USER=$3
MOUNT_POINT=$4

# Crear punto de montaje si no existe
if [ ! -d "$MOUNT_POINT" ]; then
    mkdir -p "$MOUNT_POINT"
fi

# Montar la carpeta compartida
mount -t cifs "//$WINDOWS_IP/$SHARE_NAME" "$MOUNT_POINT" -o username=$WIN_USER,vers=3.0,iocharset=utf8

# Verificar si se montó correctamente
if [ $? -eq 0 ]; then
    echo "La carpeta compartida se ha montado correctamente en $MOUNT_POINT"
    
    # Agregar entrada en fstab para montaje automático al iniciar
    echo "¿Desea configurar el montaje automático al iniciar? (s/n)"
    read response
    
    if [ "$response" = "s" ] || [ "$response" = "S" ]; then
        # Verificar si la entrada ya existe en fstab
        if ! grep -q "//$WINDOWS_IP/$SHARE_NAME" /etc/fstab; then
            echo "//$WINDOWS_IP/$SHARE_NAME $MOUNT_POINT cifs username=$WIN_USER,password=,vers=3.0,iocharset=utf8,_netdev 0 0" >> /etc/fstab
            echo "Se agregó la entrada en /etc/fstab para montaje automático"
            echo "IMPORTANTE: Debe editar /etc/fstab y agregar su contraseña después de 'password='"
        else
            echo "La entrada ya existe en /etc/fstab"
        fi
    fi
else
    echo "Error al montar la carpeta compartida"
fi
EOL

# Hacer ejecutable el script para montar carpeta compartida de Windows
chmod +x /usr/local/bin/mount-windows-share

# 10. Crear guía de acceso desde Windows
show_message "Creando guía de acceso desde Windows..."
cat > /samba/shared/INSTRUCCIONES_ACCESO_WINDOWS.txt << 'EOL'
INSTRUCCIONES PARA ACCEDER DESDE WINDOWS A ESTE COMPARTIDO

1. Abrir el Explorador de Archivos de Windows
2. En la barra de direcciones, escribir: \\IP_DEL_SERVIDOR_LINUX\shared
   (Reemplazar IP_DEL_SERVIDOR_LINUX con la dirección IP del servidor Linux)
3. Cuando solicite credenciales, ingresar el nombre de usuario y contraseña que creaste en el servidor Samba
4. La carpeta compartida debería abrirse y podrás acceder a los archivos

PARA CREAR UNA UNIDAD DE RED:

1. En el Explorador de Archivos, hacer clic derecho en "Este equipo" y seleccionar "Conectar a unidad de red"
2. Seleccionar una letra de unidad
3. En la ruta, escribir: \\IP_DEL_SERVIDOR_LINUX\shared
4. Marcar "Conectar usando credenciales diferentes" y "Recordar mis credenciales"
5. Hacer clic en "Finalizar"
6. Ingresar el nombre de usuario y contraseña creados en el servidor Samba
EOL

# 11. Crear guía para compartir desde Windows
show_message "Creando guía para compartir desde Windows..."
cat > /samba/shared/INSTRUCCIONES_COMPARTIR_DESDE_WINDOWS.txt << 'EOL'
INSTRUCCIONES PARA COMPARTIR UNA CARPETA DESDE WINDOWS PARA ACCEDER DESDE LINUX

1. En Windows, crear o seleccionar la carpeta que deseas compartir
2. Hacer clic derecho en la carpeta y seleccionar "Propiedades"
3. Ir a la pestaña "Compartir" y hacer clic en "Uso compartido avanzado"
4. Marcar la casilla "Compartir esta carpeta"
5. Configurar los permisos haciendo clic en "Permisos":
   - Para acceso completo: dar "Control total" al usuario que usarás desde Linux
   - Para acceso de solo lectura: dar solo permiso de "Lectura"
6. Hacer clic en "Aplicar" y "Aceptar" para cerrar las ventanas

7. Abrir Panel de Control > Sistema y seguridad > Firewall de Windows
8. Hacer clic en "Permitir una aplicación o característica a través del Firewall"
9. Asegurarse de que "Compartir archivos e impresoras" esté habilitado para redes privadas

10. Para verificar la configuración y obtener el nombre de PC:
    - Presionar Win+R, escribir "cmd" y presionar Enter
    - En la ventana de símbolo del sistema, escribir "hostname" y presionar Enter
    - El nombre mostrado es el que deberás usar para acceder desde Linux

11. Para acceder desde Linux a tu carpeta compartida:
    - Usar el script mount-windows-share que se instaló en tu sistema:
      sudo /usr/local/bin/mount-windows-share NOMBRE_PC_O_IP NOMBRE_COMPARTIDO USUARIO_WINDOWS PUNTO_MONTAJE
    - Ejemplo:
      sudo /usr/local/bin/mount-windows-share 192.168.1.100 Documents usuario_windows /mnt/windows-docs

NOTA: Asegúrate de que ambas máquinas (Windows y Linux) estén en la misma red y puedan comunicarse entre sí.
EOL

# 12. Mostrar información sobre la configuración
show_message "Mostrando información del sistema..."
echo "Dirección IP del servidor: $(hostname -I | awk '{print $1}')"
echo "Nombre de host: $(hostname)"
echo "Estado del servicio Samba:"
systemctl status smb --no-pager

# Información final
show_message "¡Configuración completada!"
echo -e "
${YELLOW}RESUMEN DE LA CONFIGURACIÓN:${NC}

1. Servidor Samba instalado y configurado
2. Carpeta compartida creada en: /samba/shared
3. Grupo de acceso: smbgroup
4. Usuario Samba creado: $SMB_USER
5. Firewall configurado para permitir Samba
6. Script para montar carpetas de Windows: /usr/local/bin/mount-windows-share
7. Instrucciones para Windows guardadas en /samba/shared/

${YELLOW}PRÓXIMOS PASOS:${NC}

1. Para acceder desde Windows:
   - En el Explorador de Archivos, escribir: \\$(hostname -I | awk '{print $1}')\shared
   - Usar el usuario $SMB_USER con la contraseña que estableciste

2. Para acceder a una carpeta compartida de Windows:
   - Ejecutar: sudo /usr/local/bin/mount-windows-share IP_WINDOWS NOMBRE_COMPARTIDO USUARIO PUNTO_MONTAJE
   - Ejemplo: sudo /usr/local/bin/mount-windows-share 192.168.1.100 Documents usuario_windows /mnt/windows

${GREEN}¡La configuración se ha completado con éxito!${NC}"