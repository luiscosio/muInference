#!/bin/bash
# Post-build script for muinference enclave
# This runs after the rootfs is built but before it's packaged

set -e

TARGET_DIR=$1

# Create init script to auto-start enclave server
cat > "${TARGET_DIR}/etc/init.d/S99enclave" << 'EOF'
#!/bin/sh

case "$1" in
    start)
        echo "Starting muinference enclave server..."
        /opt/enclave_server.py &
        ;;
    stop)
        echo "Stopping muinference enclave server..."
        killall enclave_server.py 2>/dev/null || true
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac

exit 0
EOF

chmod 755 "${TARGET_DIR}/etc/init.d/S99enclave"

# Create models directory
mkdir -p "${TARGET_DIR}/opt/models"

echo "muinference post-build complete"
