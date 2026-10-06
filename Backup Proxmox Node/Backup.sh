#!/usr/bin/env bash
#
# ==============================================================================
# Proxmox Node Configuration Backup
# ==============================================================================
#
# Version : v1
# Auteur  : Alvin ARTUS
# Société : Yumaiia
#
# Description :
#   Sauvegarde de la configuration d'un nœud Proxmox VE.
#
# IMPORTANT :
#   - Les disques des VM/CT ne sont PAS sauvegardés.
#   - La configuration Proxmox, réseau, stockage et système est sauvegardée.
#   - L'archive est compressée avec zstd en multithread.
#   - Une vérification SHA256 et une vérification de l'archive sont effectuées.
#   - Les événements importants sont également envoyés dans syslog/journald.
#
# ==============================================================================

set -Eeuo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================

# Répertoire de sauvegarde local
BACKUP_DIR="/var/backups/proxmox-node"

# Conservation des sauvegardes
KEEP_DAYS=7

# Compression ZSTD
# 0 = utilisation de tous les CPU disponibles
ZSTD_THREADS=0
ZSTD_LEVEL=3

# Répertoire de logs
LOG_DIR="/var/log/proxmox-node-backup"
LOG_FILE="${LOG_DIR}/backup.log"

# Tag syslog / journald
SYSLOG_TAG="proxmox-node-backup"
SYSLOG_FACILITY="daemon"

# ------------------------------------------------------------------------------
# NOTIFICATION MAIL
#
# none     = aucun mail
# failure  = uniquement en cas d'échec
# always   = succès + échec
# ------------------------------------------------------------------------------

NOTIFICATION_MODE="failure"

# Destinataire
MAIL_TO=""

# Expéditeur
MAIL_FROM="proxmox@localhost"

# Commande sendmail
SENDMAIL="/usr/sbin/sendmail"

# ------------------------------------------------------------------------------
# TRANSFERT DISTANT
#
# false = désactivé
# true  = activé
# ------------------------------------------------------------------------------

REMOTE_ENABLED=false

# ssh ou nfs
REMOTE_TYPE="ssh"

# SSH
REMOTE_HOST=""
REMOTE_USER="root"
REMOTE_PATH="/backup/proxmox"

# Pour NFS :
# BACKUP_DIR doit être directement le point de montage NFS.
#
# ------------------------------------------------------------------------------

# Sauvegarde des clés SSH privées
BACKUP_SSH=true

# Sauvegarde des certificats privés
BACKUP_PRIVATE_CERTS=true

# Sauvegarde du /root/.ssh
BACKUP_ROOT_SSH=true

# ==============================================================================
# VARIABLES INTERNES
# ==============================================================================

HOSTNAME_SHORT="$(hostname -s)"
DATE="$(date '+%Y-%m-%d_%H-%M-%S')"

ARCHIVE="${BACKUP_DIR}/proxmox-node_${HOSTNAME_SHORT}_${DATE}.tar.zst"
CHECKSUM="${ARCHIVE}.sha256"

WORK_DIR=""
SOURCE_DIR=""
INVENTORY_DIR=""

START_TIME="$(date +%s)"
BACKUP_STATUS="FAILED"
ERROR_MESSAGE=""

# ==============================================================================
# LOGGING
# ==============================================================================

log()
{
    local message="$*"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: ${message}"

    logger \
        -t "$SYSLOG_TAG" \
        -p "${SYSLOG_FACILITY}.info" \
        -- "$message" \
        2>/dev/null || true
}

warn()
{
    local message="$*"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: ${message}" >&2

    logger \
        -t "$SYSLOG_TAG" \
        -p "${SYSLOG_FACILITY}.warning" \
        -- "$message" \
        2>/dev/null || true
}

error()
{
    local message="$*"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${message}" >&2

    logger \
        -t "$SYSLOG_TAG" \
        -p "${SYSLOG_FACILITY}.err" \
        -- "$message" \
        2>/dev/null || true
}

# ==============================================================================
# NOTIFICATION MAIL
# ==============================================================================

send_mail()
{
    local subject="$1"
    local body="$2"

    [[ -n "${MAIL_TO}" ]] || {
        warn "MAIL_TO n'est pas configuré. Notification ignorée."
        return 0
    }

    [[ -x "${SENDMAIL}" ]] || {
        warn "sendmail introuvable : ${SENDMAIL}. Notification ignorée."
        return 0
    }

    {
        echo "From: ${MAIL_FROM}"
        echo "To: ${MAIL_TO}"
        echo "Subject: ${subject}"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo
        echo "${body}"
    } | "${SENDMAIL}" -t

    log "Notification mail envoyée à ${MAIL_TO}"
}

notify_success()
{
    [[ "${NOTIFICATION_MODE}" == "always" ]] || return 0

    local duration="$1"
    local sha256="$2"

    local body

    body="$(cat <<EOF
Proxmox Node Configuration Backup

Status      : SUCCESS
Node        : ${HOSTNAME_SHORT}
Date        : $(date '+%Y-%m-%d %H:%M:%S')
Duration    : ${duration}s

Archive:
${ARCHIVE}

SHA256:
${sha256}

Archive verification:
OK

Backup directory:
${BACKUP_DIR}

Retention:
${KEEP_DAYS} days

The backup contains configuration only.
VM/CT disks are NOT included.

--
Proxmox Node Configuration Backup v1
Alvin ARTUS - Yumaiia
EOF
)"

    send_mail \
        "[Proxmox] Backup OK - ${HOSTNAME_SHORT}" \
        "${body}"
}

notify_failure()
{
    [[ "${NOTIFICATION_MODE}" == "failure" ||
       "${NOTIFICATION_MODE}" == "always" ]] || return 0

    local duration="$1"
    local reason="$2"

    local body

    body="$(cat <<EOF
Proxmox Node Configuration Backup

Status      : FAILED
Node        : ${HOSTNAME_SHORT}
Date        : $(date '+%Y-%m-%d %H:%M:%S')
Duration    : ${duration}s

Reason:
${reason}

Archive:
${ARCHIVE}

Log:
${LOG_FILE}

Please check the backup log and system journal.

--
Proxmox Node Configuration Backup v1
Alvin ARTUS - Yumaiia
EOF
)"

    send_mail \
        "[Proxmox] Backup FAILED - ${HOSTNAME_SHORT}" \
        "${body}"
}

# ==============================================================================
# CLEANUP
# ==============================================================================

cleanup()
{
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi
}

# ==============================================================================
# ERROR HANDLER
# ==============================================================================

on_error()
{
    local exit_code=$?

    if [[ "${BACKUP_STATUS}" != "SUCCESS" ]]; then

        ERROR_MESSAGE="${ERROR_MESSAGE:-Erreur lors du backup.}"

        error "BACKUP FAILED"
        error "${ERROR_MESSAGE}"

        local end_time
        local duration

        end_time="$(date +%s)"
        duration=$((end_time - START_TIME))

        notify_failure "${duration}" "${ERROR_MESSAGE}"
    fi

    cleanup

    exit "${exit_code}"
}

trap on_error ERR
trap cleanup EXIT

# ==============================================================================
# ROOT CHECK
# ==============================================================================

require_root()
{
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: ce script doit être exécuté en root." >&2
        exit 1
    fi
}

# ==============================================================================
# COMMAND CHECK
# ==============================================================================

require_commands()
{
    local commands=(
        tar
        zstd
        sha256sum
        find
        hostname
        date
        mountpoint
        sqlite3
        logger
        mktemp
        cp
        tee
    )

    local missing=()

    for cmd in "${commands[@]}"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${cmd}")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        error "Commandes manquantes : ${missing[*]}"
        exit 1
    fi
}

# ==============================================================================
# CONFIGURATION VALIDATION
# ==============================================================================

validate_config()
{
    case "${NOTIFICATION_MODE}" in
        none|failure|always)
            ;;
        *)
            error "NOTIFICATION_MODE invalide : ${NOTIFICATION_MODE}"
            error "Valeurs possibles : none, failure, always"
            exit 1
            ;;
    esac

    case "${REMOTE_TYPE}" in
        ssh|nfs)
            ;;
        *)
            error "REMOTE_TYPE invalide : ${REMOTE_TYPE}"
            exit 1
            ;;
    esac

    if [[ "${KEEP_DAYS}" -lt 1 ]]; then
        error "KEEP_DAYS doit être supérieur ou égal à 1."
        exit 1
    fi
}

# ==============================================================================
# COPY HELPER
# ==============================================================================

copy_if_exists()
{
    local source="$1"
    local destination="$2"

    if [[ -e "${source}" || -L "${source}" ]]; then

        mkdir -p "$(dirname "${destination}")"

        cp -a \
            "${source}" \
            "${destination}"

    else
        warn "Absent, ignoré : ${source}"
    fi
}

# ==============================================================================
# INVENTORY
# ==============================================================================

collect_inventory()
{
    log "Collecte de l'inventaire système..."

    mkdir -p "${INVENTORY_DIR}"

    # --------------------------------------------------------------------------
    # Proxmox
    # --------------------------------------------------------------------------

    {
        echo "===== HOSTNAME ====="
        hostname

        echo
        echo "===== DATE ====="
        date --iso-8601=seconds

        echo
        echo "===== PVE VERSION ====="
        pveversion -v 2>&1 || true

    } > "${INVENTORY_DIR}/proxmox.txt"

    # --------------------------------------------------------------------------
    # Kernel / CPU / mémoire
    # --------------------------------------------------------------------------

    uname -a \
        > "${INVENTORY_DIR}/uname.txt" 2>&1 || true

    lscpu \
        > "${INVENTORY_DIR}/lscpu.txt" 2>&1 || true

    free -h \
        > "${INVENTORY_DIR}/memory.txt" 2>&1 || true

    cp -a /proc/cpuinfo \
        "${INVENTORY_DIR}/proc-cpuinfo" \
        2>/dev/null || true

    cp -a /proc/meminfo \
        "${INVENTORY_DIR}/proc-meminfo" \
        2>/dev/null || true

    # --------------------------------------------------------------------------
    # PCI / hardware
    # --------------------------------------------------------------------------

    lspci -nnk \
        > "${INVENTORY_DIR}/lspci.txt" 2>&1 || true

    # --------------------------------------------------------------------------
    # Disques / fichiersystems
    # --------------------------------------------------------------------------

    lsblk \
        -e7 \
        -o NAME,KNAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,UUID,MODEL,SERIAL \
        > "${INVENTORY_DIR}/lsblk.txt" 2>&1 || true

    df -hT \
        > "${INVENTORY_DIR}/df.txt" 2>&1 || true

    mount \
        > "${INVENTORY_DIR}/mount.txt" 2>&1 || true

    findmnt \
        > "${INVENTORY_DIR}/findmnt.txt" 2>&1 || true

    # --------------------------------------------------------------------------
    # Réseau
    # --------------------------------------------------------------------------

    ip -details address \
        > "${INVENTORY_DIR}/ip-address.txt" 2>&1 || true

    ip -details link \
        > "${INVENTORY_DIR}/ip-link.txt" 2>&1 || true

    ip route \
        > "${INVENTORY_DIR}/ip-route.txt" 2>&1 || true

    ip rule \
        > "${INVENTORY_DIR}/ip-rule.txt" 2>&1 || true

    # --------------------------------------------------------------------------
    # LVM
    # --------------------------------------------------------------------------

    pvs \
        > "${INVENTORY_DIR}/pvs.txt" 2>&1 || true

    vgs \
        > "${INVENTORY_DIR}/vgs.txt" 2>&1 || true

    lvs -a -o +devices \
        > "${INVENTORY_DIR}/lvs.txt" 2>&1 || true

    # --------------------------------------------------------------------------
    # Proxmox Storage
    # --------------------------------------------------------------------------

    pvesm status \
        > "${INVENTORY_DIR}/pvesm-status.txt" 2>&1 || true

    pvesh get /nodes \
        > "${INVENTORY_DIR}/pvesh-nodes.txt" 2>&1 || true

    # --------------------------------------------------------------------------
    # VM / CT inventory uniquement
    #
    # ATTENTION :
    # aucune donnée de disque VM/CT n'est copiée.
    # --------------------------------------------------------------------------

    qm list \
        > "${INVENTORY_DIR}/qm-list.txt" 2>&1 || true

    pct list \
        > "${INVENTORY_DIR}/pct-list.txt" 2>&1 || true

    # --------------------------------------------------------------------------
    # Systemd
    # --------------------------------------------------------------------------

    systemctl --failed \
        > "${INVENTORY_DIR}/systemd-failed.txt" 2>&1 || true

    systemctl list-unit-files --state=enabled \
        > "${INVENTORY_DIR}/systemd-enabled.txt" 2>&1 || true

    systemctl list-units --all \
        > "${INVENTORY_DIR}/systemd-units.txt" 2>&1 || true

    # --------------------------------------------------------------------------
    # Kernel
    # --------------------------------------------------------------------------

    lsmod \
        > "${INVENTORY_DIR}/lsmod.txt" 2>&1 || true

    dmesg \
        > "${INVENTORY_DIR}/dmesg.txt" 2>&1 || true

    # --------------------------------------------------------------------------
    # Packages
    # --------------------------------------------------------------------------

    dpkg-query \
        -W \
        -f='${binary:Package}\t${Version}\n' \
        > "${INVENTORY_DIR}/dpkg-packages.txt" 2>&1 || true

    apt-mark showmanual \
        > "${INVENTORY_DIR}/apt-manual.txt" 2>&1 || true

    # --------------------------------------------------------------------------
    # ZFS
    # --------------------------------------------------------------------------

    if command -v zpool >/dev/null 2>&1; then

        zpool status \
            > "${INVENTORY_DIR}/zpool-status.txt" 2>&1 || true

        zpool list \
            > "${INVENTORY_DIR}/zpool-list.txt" 2>&1 || true

        zfs list \
            > "${INVENTORY_DIR}/zfs-list.txt" 2>&1 || true
    fi

    # --------------------------------------------------------------------------
    # Ceph
    # --------------------------------------------------------------------------

    if command -v ceph >/dev/null 2>&1; then

        ceph -s \
            > "${INVENTORY_DIR}/ceph-status.txt" 2>&1 || true

        ceph osd tree \
            > "${INVENTORY_DIR}/ceph-osd-tree.txt" 2>&1 || true
    fi

    # --------------------------------------------------------------------------
    # iSCSI / multipath état
    # --------------------------------------------------------------------------

    if command -v iscsiadm >/dev/null 2>&1; then

        iscsiadm -m session \
            > "${INVENTORY_DIR}/iscsi-sessions.txt" 2>&1 || true
    fi

    if command -v multipath >/dev/null 2>&1; then

        multipath -ll \
            > "${INVENTORY_DIR}/multipath.txt" 2>&1 || true
    fi
}

# ==============================================================================
# PROXMOX CONFIGURATION
# ==============================================================================

backup_proxmox()
{
    log "Sauvegarde de la configuration Proxmox..."

    copy_if_exists \
        "/etc/pve" \
        "${SOURCE_DIR}/etc-pve"

    copy_if_exists \
        "/var/lib/pve-cluster" \
        "${SOURCE_DIR}/var-lib-pve-cluster"

    if [[ -f "/var/lib/pve-cluster/config.db" ]]; then

        mkdir -p "${SOURCE_DIR}/pve-cluster"

        cp -a \
            "/var/lib/pve-cluster/config.db" \
            "${SOURCE_DIR}/pve-cluster/config.db"

        log "Vérification de l'intégrité SQLite de config.db..."

        if sqlite3 \
            "/var/lib/pve-cluster/config.db" \
            "PRAGMA integrity_check;" \
            > "${INVENTORY_DIR}/config-db-integrity.txt" \
            2>&1; then

            if grep -qx "ok" \
                "${INVENTORY_DIR}/config-db-integrity.txt"; then

                log "config.db : integrity_check OK"

            else

                ERROR_MESSAGE="SQLite config.db integrity_check a échoué."

                error "${ERROR_MESSAGE}"

                cat "${INVENTORY_DIR}/config-db-integrity.txt"

                return 1
            fi

        else

            ERROR_MESSAGE="Impossible d'exécuter SQLite integrity_check."

            error "${ERROR_MESSAGE}"

            return 1
        fi

        log "Création du dump SQLite..."

        sqlite3 \
            "/var/lib/pve-cluster/config.db" \
            ".dump" \
            > "${SOURCE_DIR}/pve-cluster/config.dump.sql"

    else

        warn "/var/lib/pve-cluster/config.db absent."
    fi
}

# ==============================================================================
# NETWORK
# ==============================================================================

backup_network()
{
    log "Sauvegarde de la configuration réseau..."

    copy_if_exists \
        "/etc/network" \
        "${SOURCE_DIR}/etc-network"

    copy_if_exists \
        "/etc/hosts" \
        "${SOURCE_DIR}/etc-hosts"

    copy_if_exists \
        "/etc/hostname" \
        "${SOURCE_DIR}/etc-hostname"

    copy_if_exists \
        "/etc/resolv.conf" \
        "${SOURCE_DIR}/etc-resolv.conf"

    copy_if_exists \
        "/etc/NetworkManager" \
        "${SOURCE_DIR}/etc-networkmanager"

    copy_if_exists \
        "/etc/systemd/resolved.conf" \
        "${SOURCE_DIR}/etc-systemd-resolved.conf"
}

# ==============================================================================
# ISCSI / MULTIPATH
# ==============================================================================

backup_iscsi_multipath()
{
    log "Sauvegarde de la configuration iSCSI..."

    copy_if_exists \
        "/etc/iscsi" \
        "${SOURCE_DIR}/etc-iscsi"

    copy_if_exists \
        "/etc/target" \
        "${SOURCE_DIR}/etc-target"

    log "Sauvegarde de la configuration multipath..."

    copy_if_exists \
        "/etc/multipath.conf" \
        "${SOURCE_DIR}/etc-multipath.conf"

    copy_if_exists \
        "/etc/multipath" \
        "${SOURCE_DIR}/etc-multipath"
}

# ==============================================================================
# APT
# ==============================================================================

backup_apt()
{
    log "Sauvegarde de la configuration APT..."

    copy_if_exists \
        "/etc/apt" \
        "${SOURCE_DIR}/etc-apt"
}

# ==============================================================================
# CERTIFICATES
# ==============================================================================

backup_certificates()
{
    log "Sauvegarde des certificats..."

    copy_if_exists \
        "/etc/ssl/certs" \
        "${SOURCE_DIR}/etc-ssl-certs"

    if [[ "${BACKUP_PRIVATE_CERTS}" == "true" ]]; then

        copy_if_exists \
            "/etc/ssl/private" \
            "${SOURCE_DIR}/etc-ssl-private"
    fi

    local node

    node="$(hostname -s)"

    copy_if_exists \
        "/etc/pve/nodes/${node}/pve-ssl.pem" \
        "${SOURCE_DIR}/pve-ssl.pem"

    copy_if_exists \
        "/etc/pve/nodes/${node}/pve-ssl.key" \
        "${SOURCE_DIR}/pve-ssl.key"
}

# ==============================================================================
# SSH
# ==============================================================================

backup_ssh()
{
    if [[ "${BACKUP_SSH}" != "true" ]]; then
        return 0
    fi

    log "Sauvegarde de la configuration SSH..."

    copy_if_exists \
        "/etc/ssh" \
        "${SOURCE_DIR}/etc-ssh"

    if [[ "${BACKUP_ROOT_SSH}" == "true" ]]; then

        copy_if_exists \
            "/root/.ssh" \
            "${SOURCE_DIR}/root-ssh"
    fi
}

# ==============================================================================
# SYSTEM CONFIGURATION
# ==============================================================================

backup_system()
{
    log "Sauvegarde de la configuration système..."

    copy_if_exists \
        "/etc/fstab" \
        "${SOURCE_DIR}/etc-fstab"

    copy_if_exists \
        "/etc/modules" \
        "${SOURCE_DIR}/etc-modules"

    copy_if_exists \
        "/etc/modules-load.d" \
        "${SOURCE_DIR}/etc-modules-load"

    copy_if_exists \
        "/etc/modprobe.d" \
        "${SOURCE_DIR}/etc-modprobe"

    copy_if_exists \
        "/etc/sysctl.conf" \
        "${SOURCE_DIR}/etc-sysctl.conf"

    copy_if_exists \
        "/etc/sysctl.d" \
        "${SOURCE_DIR}/etc-sysctl"

    copy_if_exists \
        "/etc/default" \
        "${SOURCE_DIR}/etc-default"

    copy_if_exists \
        "/etc/systemd/system" \
        "${SOURCE_DIR}/etc-systemd-system"

    copy_if_exists \
        "/etc/systemd/system.conf" \
        "${SOURCE_DIR}/etc-systemd-system.conf"

    copy_if_exists \
        "/etc/systemd/logind.conf" \
        "${SOURCE_DIR}/etc-systemd-logind.conf"

    copy_if_exists \
        "/etc/cron.d" \
        "${SOURCE_DIR}/etc-cron.d"

    copy_if_exists \
        "/etc/cron.daily" \
        "${SOURCE_DIR}/etc-cron.daily"

    copy_if_exists \
        "/etc/cron.hourly" \
        "${SOURCE_DIR}/etc-cron.hourly"

    copy_if_exists \
        "/etc/cron.monthly" \
        "${SOURCE_DIR}/etc-cron.monthly"

    copy_if_exists \
        "/etc/cron.weekly" \
        "${SOURCE_DIR}/etc-cron.weekly"

    copy_if_exists \
        "/etc/crontab" \
        "${SOURCE_DIR}/etc-crontab"

    copy_if_exists \
        "/etc/logrotate.conf" \
        "${SOURCE_DIR}/etc-logrotate.conf"

    copy_if_exists \
        "/etc/logrotate.d" \
        "${SOURCE_DIR}/etc-logrotate.d"
}

# ==============================================================================
# MANIFEST
# ==============================================================================

create_manifest()
{
    log "Création du manifeste..."

    cat > "${WORK_DIR}/MANIFEST.txt" <<EOF
===============================================================================
Proxmox Node Configuration Backup
===============================================================================

Version       : v1
Author        : Alvin ARTUS
Company       : Yumaiia

Hostname      : ${HOSTNAME_SHORT}
Date          : $(date --iso-8601=seconds)

Archive       : $(basename "${ARCHIVE}")

===============================================================================
CONTENT
===============================================================================

This archive contains the configuration and inventory of the Proxmox node.

VM and CT virtual disks are NOT included.

Included:

- /etc/pve
- /var/lib/pve-cluster
- /var/lib/pve-cluster/config.db
- SQLite config.db dump
- Network configuration
- iSCSI configuration
- Multipath configuration
- APT configuration
- SSL certificates
- Proxmox certificates
- SSH configuration
- Root SSH configuration
- Systemd configuration
- Cron configuration
- Logrotate configuration
- LVM inventory
- Storage inventory
- Hardware inventory
- Network inventory
- Package inventory
- ZFS inventory if present
- Ceph inventory if present

===============================================================================
COMPRESSION
===============================================================================

Tool          : zstd
Threads       : ${ZSTD_THREADS}
Compression   : ${ZSTD_LEVEL}

===============================================================================
RETENTION
===============================================================================

Retention     : ${KEEP_DAYS} days

===============================================================================
EOF
}

# ==============================================================================
# ARCHIVE CREATION
# ==============================================================================

create_archive()
{
    log "Création de l'archive ${ARCHIVE}..."

    tar \
        --create \
        --file=- \
        --acls \
        --xattrs \
        --numeric-owner \
        --one-file-system \
        -C "${SOURCE_DIR}" . \
        -C "${WORK_DIR}" inventory \
        -C "${WORK_DIR}" MANIFEST.txt \
        | zstd \
            -T"${ZSTD_THREADS}" \
            -"${ZSTD_LEVEL}" \
            -o "${ARCHIVE}"

    chmod 600 "${ARCHIVE}"

    log "Archive créée : ${ARCHIVE}"
}

# ==============================================================================
# ARCHIVE VERIFICATION
# ==============================================================================

verify_archive()
{
    log "Calcul du SHA256..."

    sha256sum \
        "${ARCHIVE}" \
        > "${CHECKSUM}"

    chmod 600 "${CHECKSUM}"

    log "Vérification SHA256..."

    if ! sha256sum -c "${CHECKSUM}"; then

        ERROR_MESSAGE="La vérification SHA256 de l'archive a échoué."

        error "${ERROR_MESSAGE}"

        return 1
    fi

    log "SHA256 OK."

    log "Test d'intégrité ZSTD..."

    if ! zstd -t "${ARCHIVE}"; then

        ERROR_MESSAGE="Le test d'intégrité ZSTD a échoué."

        error "${ERROR_MESSAGE}"

        return 1
    fi

    log "ZSTD OK."

    log "Test de lecture de l'archive TAR..."

    if ! zstd -dc "${ARCHIVE}" | tar -tf - >/dev/null; then

        ERROR_MESSAGE="Impossible de lire le contenu de l'archive TAR."

        error "${ERROR_MESSAGE}"

        return 1
    fi

    log "Lecture TAR OK."
    log "Archive complètement vérifiée."
}

# ==============================================================================
# ROTATION
# ==============================================================================

rotate_backups()
{
    log "Rotation des sauvegardes de plus de ${KEEP_DAYS} jours..."

    find "${BACKUP_DIR}" \
        -type f \
        \( \
            -name "proxmox-node_${HOSTNAME_SHORT}_*.tar.zst" \
            -o \
            -name "proxmox-node_${HOSTNAME_SHORT}_*.tar.zst.sha256" \
        \) \
        -mtime "+${KEEP_DAYS}" \
        -print \
        -delete \
        || true
}

# ==============================================================================
# REMOTE TRANSFER
# ==============================================================================

remote_transfer()
{
    if [[ "${REMOTE_ENABLED}" != "true" ]]; then
        return 0
    fi

    log "Transfert distant activé."

    case "${REMOTE_TYPE}" in

        ssh)

            if [[ -z "${REMOTE_HOST}" ]]; then

                ERROR_MESSAGE="REMOTE_HOST n'est pas configuré."

                error "${ERROR_MESSAGE}"

                return 1
            fi

            log "Création du répertoire distant..."

            ssh \
                "${REMOTE_USER}@${REMOTE_HOST}" \
                "mkdir -p '${REMOTE_PATH}'"

            log "Transfert de l'archive..."

            scp \
                "${ARCHIVE}" \
                "${CHECKSUM}" \
                "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"

            log "Transfert SSH terminé."

            ;;

        nfs)

            if ! mountpoint -q "${BACKUP_DIR}"; then

                ERROR_MESSAGE="${BACKUP_DIR} n'est pas un point de montage."

                error "${ERROR_MESSAGE}"

                return 1
            fi

            log "Copie vers le stockage NFS..."

            cp -a \
                "${ARCHIVE}" \
                "${CHECKSUM}" \
                "${BACKUP_DIR}/"

            log "Copie NFS terminée."

            ;;

        *)

            ERROR_MESSAGE="Type de transfert inconnu : ${REMOTE_TYPE}"

            error "${ERROR_MESSAGE}"

            return 1

            ;;
    esac
}

# ==============================================================================
# MAIN
# ==============================================================================

main()
{
    require_root
    require_commands
    validate_config

    mkdir -p "${BACKUP_DIR}"
    mkdir -p "${LOG_DIR}"

    chmod 700 "${BACKUP_DIR}"
    chmod 700 "${LOG_DIR}"

    touch "${LOG_FILE}"
    chmod 600 "${LOG_FILE}"

    # Tout le contenu du script est également enregistré dans le fichier local.
    exec > >(tee -a "${LOG_FILE}") 2>&1

    log "=================================================================="
    log "Proxmox Node Configuration Backup v1"
    log "Alvin ARTUS - Yumaiia"
    log "=================================================================="

    log "Node              : ${HOSTNAME_SHORT}"
    log "Backup directory  : ${BACKUP_DIR}"
    log "Retention         : ${KEEP_DAYS} days"
    log "ZSTD threads      : ${ZSTD_THREADS}"
    log "ZSTD level        : ${ZSTD_LEVEL}"
    log "Notification mode : ${NOTIFICATION_MODE}"
    log "Remote enabled    : ${REMOTE_ENABLED}"

    WORK_DIR="$(mktemp -d /tmp/proxmox-node-backup.XXXXXX)"

    SOURCE_DIR="${WORK_DIR}/filesystem"
    INVENTORY_DIR="${WORK_DIR}/inventory"

    mkdir -p "${SOURCE_DIR}"
    mkdir -p "${INVENTORY_DIR}"

    log "Temporary directory : ${WORK_DIR}"

    # --------------------------------------------------------------------------
    # COLLECTE
    # --------------------------------------------------------------------------

    collect_inventory

    backup_proxmox

    backup_network

    backup_iscsi_multipath

    backup_apt

    backup_certificates

    backup_ssh

    backup_system

    # --------------------------------------------------------------------------
    # MANIFEST
    # --------------------------------------------------------------------------

    create_manifest

    # --------------------------------------------------------------------------
    # ARCHIVE
    # --------------------------------------------------------------------------

    create_archive

    # --------------------------------------------------------------------------
    # VERIFICATION
    # --------------------------------------------------------------------------

    verify_archive

    # --------------------------------------------------------------------------
    # TRANSFERT
    # --------------------------------------------------------------------------

    remote_transfer

    # --------------------------------------------------------------------------
    # ROTATION
    # --------------------------------------------------------------------------

    rotate_backups

    # --------------------------------------------------------------------------
    # SUCCESS
    # --------------------------------------------------------------------------

    local end_time
    local duration
    local sha256

    end_time="$(date +%s)"
    duration=$((end_time - START_TIME))

    sha256="$(cut -d' ' -f1 "${CHECKSUM}")"

    BACKUP_STATUS="SUCCESS"

    log "=================================================================="
    log "BACKUP OK"
    log "=================================================================="

    log "Archive  : ${ARCHIVE}"
    log "SHA256   : ${sha256}"
    log "Duration : ${duration}s"

    log "Configuration backup completed successfully."

    notify_success \
        "${duration}" \
        "${sha256}"

    return 0
}

# ==============================================================================
# EXECUTION
# ==============================================================================

main "$@"