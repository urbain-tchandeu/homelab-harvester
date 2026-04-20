#!/bin/bash
# =============================================================================
#  SCRIPT D'INSTALLATION APACHE CLOUDSTACK 4.22 — Homelab
#  Dell PowerEdge R630 — Ubuntu 22.04 LTS (Jammy) ou 24.04 (Noble)
#  Architecture : Management Server + KVM Agent (all-in-one)
#
#  Disques :
#    OS        : SSD 1 To (détecté auto via /)
#    Primary   : /dev/sda     (3.6 To)  → volumes VMs
#    Secondary : /dev/nvme0n1 (469 Go)  → templates, ISO, SystemVM
#
#  Réseau :
#    IP       : 192.0.2.25/24
#    Gateway  : 192.0.2.254
#    DNS      : 192.0.2.10 (fallback 8.8.8.8)
#    Domaine  : lab.example
#    NIC      : eno1  →  bridge cloudbr0
#    Hostname : cloudstack
#
#  Version v2 — corrections :
#    - Garde-fou : refuse de wipe le disque contenant /
#    - Mots de passe MySQL hors script (fichier .env 600 ou génération auto)
#    - Log protégé (chmod 600)
#    - NFS exports restreints au /24
#    - iptables idempotent
#    - URL SystemVM corrigée (x86_64)
#    - netplan apply (sans try, car CloudStack all-in-one → console locale)
#    - Doublons évités dans les fichiers de conf
#    - chrony seul (pas openntpd)
#    - timezone America/Toronto
#    - Permissions /export → 755
#    - Check espace disque /var (>20 Go libres)
# =============================================================================
#
#  UTILISATION :
#    1. (Optionnel) Créer /root/.cloudstack-install.env avec MYSQL_ROOT_PASS / MYSQL_CLOUD_PASS
#       chmod 600 /root/.cloudstack-install.env
#       Sinon les mots de passe seront générés automatiquement.
#    2. chmod +x install_cloudstack.sh
#    3. sudo bash install_cloudstack.sh
# =============================================================================

set -euo pipefail

# --- Log protégé dès le début ---
LOG="/var/log/cloudstack_install.log"
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1

# =============================================================================
#  CONFIGURATION
# =============================================================================

# --- Réseau ---
NIC="eno1"
HOST_IP="192.0.2.25"
GATEWAY="192.0.2.254"
CIDR="24"
SUBNET="192.0.2.0/24"            # pour NFS exports restreints
DNS1="192.0.2.10"
DNS2="8.8.8.8"
SEARCH_DOMAIN="lab.example"
HOSTNAME="cloudstack"

# --- Stockage ---
PRIMARY_DISK="/dev/sda"
SECONDARY_DISK="/dev/nvme0n1"

PRIMARY_DIR="/export/primary"
SECONDARY_DIR="/export/secondary"
PRIMARY_MNT="/mnt/primary"
SECONDARY_MNT="/mnt/secondary"

# --- MySQL (depuis .env si présent, sinon généré) ---
ENV_FILE="/root/.cloudstack-install.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    PASS_SOURCE="fichier .env"
else
    MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)}"
    MYSQL_CLOUD_PASS="${MYSQL_CLOUD_PASS:-$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)}"
    PASS_SOURCE="généré automatiquement (affiché en fin de script, NOTER !)"
fi

# --- CloudStack ---
MGMT_SERVER_KEY="mgmtKey$(openssl rand -hex 8)"
DB_KEY="dbKey$(openssl rand -hex 8)"
CS_VERSION="4.22"
TIMEZONE="America/Toronto"

# =============================================================================
#  FONCTIONS UTILITAIRES
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERREUR]${NC} $1"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || error "Ce script doit être exécuté en tant que root (sudo bash $0)"
}

detect_ubuntu_version() {
    . /etc/os-release
    OS_VERSION="$VERSION_CODENAME"
    OS_VERSION_NUM="$VERSION_ID"
    info "Système : Ubuntu $OS_VERSION_NUM ($OS_VERSION)"
    [[ "$OS_VERSION" == "jammy" || "$OS_VERSION" == "noble" ]] || \
        error "Ce script supporte uniquement Ubuntu 22.04 (jammy) et 24.04 (noble)"
}

check_virtualization() {
    info "Vérification VT-x/AMD-V..."
    egrep -qc '(vmx|svm)' /proc/cpuinfo || \
        error "Virtualisation matérielle non activée dans le BIOS."
    success "Virtualisation OK ($(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs))"
}

check_disks_safety() {
    info "=== Garde-fou disques (vérif que les disques de stockage ≠ disque système) ==="

    # Disque racine
    local root_src root_disk
    root_src=$(findmnt -n -o SOURCE /)
    root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null || echo "")
    if [[ -z "$root_disk" ]]; then
        root_disk=$(echo "$root_src" | sed -E 's|/dev/||; s|p?[0-9]+$||')
    fi
    local root_disk_path="/dev/$root_disk"

    info "Disque OS détecté : $root_disk_path  (racine montée depuis $root_src)"

    [[ -b "$PRIMARY_DISK" ]]   || error "PRIMARY_DISK $PRIMARY_DISK introuvable (lsblk pour vérifier)"
    [[ -b "$SECONDARY_DISK" ]] || error "SECONDARY_DISK $SECONDARY_DISK introuvable (lsblk pour vérifier)"

    for disk in "$PRIMARY_DISK" "$SECONDARY_DISK"; do
        if [[ "$disk" == "$root_disk_path" ]]; then
            error "STOP — $disk est le disque système ! Refus de le wiper."
        fi
    done

    success "Garde-fou OK : $PRIMARY_DISK et $SECONDARY_DISK ne contiennent pas l'OS"
}

check_disk_space() {
    info "Vérif espace /var (>20 Go libres requis pour SystemVM + templates)..."
    local free_gb
    free_gb=$(df -BG --output=avail /var | tail -1 | tr -dc '0-9')
    [[ "$free_gb" -ge 20 ]] || error "Seulement ${free_gb}Go libres sur /var. Minimum 20Go."
    success "Espace /var : ${free_gb}Go libres"
}

print_banner() {
    echo ""
    echo "============================================================"
    echo "  INSTALLATION APACHE CLOUDSTACK $CS_VERSION — homelab"
    echo "  Host   : $HOSTNAME.$SEARCH_DOMAIN  ($HOST_IP/$CIDR)"
    echo "  NIC    : $NIC  →  bridge cloudbr0"
    echo "  DNS    : $DNS1 (fallback $DNS2) — search $SEARCH_DOMAIN"
    echo "  Primary   : $PRIMARY_DISK (3.6 To)   → $PRIMARY_DIR"
    echo "  Secondary : $SECONDARY_DISK (469 Go) → $SECONDARY_DIR"
    echo "  MySQL pwd : $PASS_SOURCE"
    echo "  Log       : $LOG (chmod 600)"
    echo "============================================================"
    warn "Le script va EFFACER $PRIMARY_DISK et $SECONDARY_DISK"
    warn "Le disque système a été identifié automatiquement et protégé."
    warn ""
    warn "⚠️  Si tu es en SSH distant : netplan apply va couper/recréer la connexion"
    warn "    quand le bridge cloudbr0 sera créé. Reconnecte-toi via la console iDRAC"
    warn "    ou exécute ce script en console locale pour éviter toute coupure."
    echo ""
    read -rp "Appuyer sur ENTREE pour continuer (CTRL+C pour annuler)..."
}

# =============================================================================
#  ÉTAPE 1 — PRÉREQUIS SYSTÈME
# =============================================================================
step1_prerequisites() {
    info "=== ÉTAPE 1 : Mise à jour système et prérequis ==="

    # Timezone
    timedatectl set-timezone "$TIMEZONE"

    apt update && apt upgrade -y

    # chrony seulement (pas openntpd — conflit)
    apt install -y \
        vim curl wget git net-tools bridge-utils \
        openssh-server chrony \
        python3 python3-pip \
        ufw iptables-persistent \
        htop iotop sysstat \
        lvm2 parted gdisk

    # Retirer openntpd s'il existe par erreur
    apt remove -y openntpd 2>/dev/null || true

    # Hostname + FQDN
    hostnamectl set-hostname "$HOSTNAME"
    grep -q "$HOST_IP" /etc/hosts || \
        echo "$HOST_IP  $HOSTNAME.$SEARCH_DOMAIN  $HOSTNAME" >> /etc/hosts

    # systemd-resolved (domaine + DNS)
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/homelab.conf <<EOF
[Resolve]
DNS=$DNS1
FallbackDNS=$DNS2
Domains=$SEARCH_DOMAIN
EOF
    systemctl restart systemd-resolved

    success "Prérequis OK"
}

# =============================================================================
#  ÉTAPE 1b — PARTITIONNEMENT DES DISQUES DE STOCKAGE
# =============================================================================
step1b_disks() {
    info "=== ÉTAPE 1b : Partitionnement ==="
    lsblk "$PRIMARY_DISK" "$SECONDARY_DISK" 2>/dev/null || true

    # --- PRIMARY ---
    info "Partitionnement $PRIMARY_DISK..."
    wipefs -a "$PRIMARY_DISK"
    parted -s "$PRIMARY_DISK" mklabel gpt
    parted -s "$PRIMARY_DISK" mkpart primary ext4 0% 100%
    partprobe "$PRIMARY_DISK"; sleep 2
    if   [[ -b "${PRIMARY_DISK}1"  ]]; then PRIMARY_PART="${PRIMARY_DISK}1"
    elif [[ -b "${PRIMARY_DISK}p1" ]]; then PRIMARY_PART="${PRIMARY_DISK}p1"
    else error "Partition $PRIMARY_DISK introuvable"; fi
    mkfs.ext4 -F -L "cs-primary" "$PRIMARY_PART"
    success "Primary formaté : $PRIMARY_PART"

    # --- SECONDARY ---
    info "Partitionnement $SECONDARY_DISK..."
    wipefs -a "$SECONDARY_DISK"
    parted -s "$SECONDARY_DISK" mklabel gpt
    parted -s "$SECONDARY_DISK" mkpart primary ext4 0% 100%
    partprobe "$SECONDARY_DISK"; sleep 2
    if   [[ -b "${SECONDARY_DISK}p1" ]]; then SECONDARY_PART="${SECONDARY_DISK}p1"
    elif [[ -b "${SECONDARY_DISK}1"  ]]; then SECONDARY_PART="${SECONDARY_DISK}1"
    else error "Partition $SECONDARY_DISK introuvable"; fi
    mkfs.ext4 -F -L "cs-secondary" "$SECONDARY_PART"
    success "Secondary formaté : $SECONDARY_PART"

    # --- Montage (fstab par LABEL) ---
    mkdir -p "$PRIMARY_DIR" "$SECONDARY_DIR"
    sed -i '/cs-primary\|cs-secondary/d' /etc/fstab
    cat >> /etc/fstab <<EOF
LABEL=cs-primary    $PRIMARY_DIR    ext4    defaults,nofail    0 2
LABEL=cs-secondary  $SECONDARY_DIR  ext4    defaults,nofail    0 2
EOF
    systemctl daemon-reload
    mount -a
    chmod 755 "$PRIMARY_DIR" "$SECONDARY_DIR"

    df -h "$PRIMARY_DIR" "$SECONDARY_DIR"
    success "Disques stockage montés"
}

# =============================================================================
#  ÉTAPE 2 — CONFIGURATION SSH
# =============================================================================
step2_ssh() {
    info "=== ÉTAPE 2 : SSH ==="

    # Idempotent : retirer marqueur précédent avant d'ajouter
    sed -i '/# CloudStack requirements START/,/# CloudStack requirements END/d' /etc/ssh/sshd_config
    cat >> /etc/ssh/sshd_config <<'EOF'

# CloudStack requirements START
PermitRootLogin yes
# CloudStack requirements END
EOF

    systemctl enable ssh
    systemctl restart ssh
    success "SSH OK (PermitRootLogin yes — penser à fail2ban si exposé)"
}

# =============================================================================
#  ÉTAPE 3 — RÉSEAU (bridge cloudbr0)
# =============================================================================
step3_network() {
    info "=== ÉTAPE 3 : bridge cloudbr0 ==="

    local ts
    ts="$(date +%s)"
    for f in /etc/netplan/*.yaml; do
        [[ -f "$f" ]] && cp "$f" "${f}.bak.${ts}" 2>/dev/null || true
    done

    # Désactiver cloud-init networking
    if [ -d /etc/cloud/cloud.cfg.d ]; then
        echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    fi

    rm -f /etc/netplan/00-installer-config.yaml \
          /etc/netplan/01-network-manager-all.yaml

    cat > /etc/netplan/01-cloudstack-network.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${NIC}:
      dhcp4: false
      dhcp6: false
  bridges:
    cloudbr0:
      dhcp4: false
      dhcp6: false
      interfaces: [${NIC}]
      addresses: [${HOST_IP}/${CIDR}]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS1}, ${DNS2}]
        search: [${SEARCH_DOMAIN}]
      parameters:
        stp: false
        forward-delay: 0
EOF
    chmod 600 /etc/netplan/01-cloudstack-network.yaml

    # Pas de netplan try (interactif) — apply direct
    netplan generate
    netplan apply
    sleep 3
    ip -br addr show cloudbr0 || warn "cloudbr0 pas encore visible, vérifier manuellement"
    success "Réseau configuré"
}

# =============================================================================
#  ÉTAPE 4 — NFS
# =============================================================================
step4_nfs() {
    info "=== ÉTAPE 4 : NFS ==="

    apt install -y nfs-kernel-server nfs-common

    mkdir -p "$PRIMARY_DIR" "$SECONDARY_DIR" "$PRIMARY_MNT" "$SECONDARY_MNT"
    chmod 755 "$PRIMARY_DIR" "$SECONDARY_DIR"

    # Exports restreints au sous-réseau mgmt
    sed -i "\|${PRIMARY_DIR}|d"   /etc/exports
    sed -i "\|${SECONDARY_DIR}|d" /etc/exports
    cat >> /etc/exports <<EOF
${PRIMARY_DIR}    ${SUBNET}(rw,async,no_root_squash,no_subtree_check)
${SECONDARY_DIR}  ${SUBNET}(rw,async,no_root_squash,no_subtree_check)
EOF

    # Ports NFS figés — idempotent
    sed -i '/# CloudStack NFS ports START/,/# CloudStack NFS ports END/d' /etc/default/nfs-kernel-server
    cat >> /etc/default/nfs-kernel-server <<'EOF'

# CloudStack NFS ports START
LOCKD_TCPPORT=32803
LOCKD_UDPPORT=32769
MOUNTD_PORT=892
RQUOTAD_PORT=875
STATD_PORT=662
STATD_OUTGOING_PORT=2020
# CloudStack NFS ports END
EOF

    systemctl enable nfs-kernel-server rpcbind
    systemctl restart nfs-kernel-server rpcbind
    exportfs -a

    # Auto-mount local (all-in-one)
    sed -i "\|${PRIMARY_MNT}|d"   /etc/fstab
    sed -i "\|${SECONDARY_MNT}|d" /etc/fstab
    cat >> /etc/fstab <<EOF
${HOST_IP}:${PRIMARY_DIR}    ${PRIMARY_MNT}    nfs    defaults    0 0
${HOST_IP}:${SECONDARY_DIR}  ${SECONDARY_MNT}  nfs    defaults    0 0
EOF
    systemctl daemon-reload
    mount -a || warn "mount -a a échoué, vérifier manuellement"

    success "NFS OK — exports limités à ${SUBNET}"
}

# =============================================================================
#  ÉTAPE 5 — MYSQL
# =============================================================================
step5_mysql() {
    info "=== ÉTAPE 5 : MySQL ==="

    apt install -y mysql-server

    cat > /etc/mysql/conf.d/cloudstack.cnf <<EOF
[mysqld]
server-id                = 1
innodb_rollback_on_timeout = 1
innodb_lock_wait_timeout = 600
max_connections          = 350
log-bin                  = mysql-bin
binlog-format            = ROW
character-set-server     = utf8mb4
collation-server         = utf8mb4_general_ci
default-storage-engine   = InnoDB
EOF

    systemctl enable mysql
    systemctl restart mysql

    # Sécurisation — passé via stdin pour éviter d'exposer les mdp en cmdline
    mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

    success "MySQL sécurisé"
}

# =============================================================================
#  ÉTAPE 6 — CLOUDSTACK MANAGEMENT
# =============================================================================
step6_cloudstack_management() {
    info "=== ÉTAPE 6 : CloudStack Management ==="

    echo "deb https://download.cloudstack.org/ubuntu ${OS_VERSION} ${CS_VERSION}" \
        > /etc/apt/sources.list.d/cloudstack.list
    wget -q -O - https://download.cloudstack.org/release.asc | \
        tee /etc/apt/trusted.gpg.d/cloudstack.asc > /dev/null
    apt update
    apt install -y cloudstack-management

    cloudstack-setup-databases "cloud:${MYSQL_CLOUD_PASS}@localhost" \
        --deploy-as="root:${MYSQL_ROOT_PASS}" \
        -e file \
        -m "${MGMT_SERVER_KEY}" \
        -k "${DB_KEY}" \
        -i "${HOST_IP}" \
        || error "Échec cloudstack-setup-databases"

    cloudstack-setup-management || error "Échec cloudstack-setup-management"

    grep -q "Defaults:cloud !requiretty" /etc/sudoers || \
        echo "Defaults:cloud !requiretty" >> /etc/sudoers

    success "Management Server installé"
}

# =============================================================================
#  ÉTAPE 7 — SYSTEMVM TEMPLATE
# =============================================================================
step7_systemvm() {
    info "=== ÉTAPE 7 : SystemVM template (~600 Mo) ==="

    # URL corrigée : x86_64-kvm pour CloudStack 4.22+
    local SYSVM_URL="https://download.cloudstack.org/systemvm/${CS_VERSION}/systemvmtemplate-${CS_VERSION}.0-x86_64-kvm.qcow2.bz2"

    if ! wget -q --spider "$SYSVM_URL"; then
        # Fallback : ancien format sans x86_64
        SYSVM_URL="https://download.cloudstack.org/systemvm/${CS_VERSION}/systemvmtemplate-${CS_VERSION}.0-kvm.qcow2.bz2"
        if ! wget -q --spider "$SYSVM_URL"; then
            error "URL SystemVM introuvable. Vérifier sur https://download.cloudstack.org/systemvm/${CS_VERSION}/"
        fi
    fi
    info "URL SystemVM : $SYSVM_URL"

    /usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt \
        -m "${SECONDARY_MNT}" \
        -u "${SYSVM_URL}" \
        -h kvm \
        -s "${MGMT_SERVER_KEY}" \
        -F \
        || error "Échec installation SystemVM template"

    success "SystemVM installé dans $SECONDARY_MNT"
}

# =============================================================================
#  ÉTAPE 8 — CLOUDSTACK AGENT (KVM)
# =============================================================================
step8_kvm_agent() {
    info "=== ÉTAPE 8 : CloudStack Agent (KVM) ==="

    apt install -y \
        qemu-kvm libvirt-clients libvirt-daemon-system \
        virtinst bridge-utils cpu-checker

    kvm-ok || warn "kvm-ok failed — vérifier BIOS"

    apt install -y cloudstack-agent

    # QEMU VNC
    sed -i 's/#*vnc_listen.*/vnc_listen = "0.0.0.0"/' /etc/libvirt/qemu.conf
    grep -q '^vnc_listen' /etc/libvirt/qemu.conf || \
        echo 'vnc_listen = "0.0.0.0"' >> /etc/libvirt/qemu.conf

    # libvirtd conf — idempotent
    for param in listen_tls listen_tcp tcp_port auth_tcp mdns_adv; do
        sed -i "/^#*${param}[[:space:]]*=/d" /etc/libvirt/libvirtd.conf
    done
    cat >> /etc/libvirt/libvirtd.conf <<'EOF'
listen_tls = 0
listen_tcp = 1
tcp_port = "16509"
auth_tcp = "none"
mdns_adv = 0
EOF

    if [[ "$OS_VERSION" == "noble" ]]; then
        info "Ubuntu 24.04 : libvirt mode traditionnel"
        systemctl mask libvirtd.socket libvirtd-ro.socket \
            libvirtd-admin.socket libvirtd-tls.socket libvirtd-tcp.socket 2>/dev/null || true
        grep -q 'uri_default' /etc/libvirt/libvirt.conf 2>/dev/null || \
            echo 'uri_default = "qemu:///system"' >> /etc/libvirt/libvirt.conf
    else
        if grep -q "LIBVIRTD_ARGS" /etc/default/libvirtd 2>/dev/null; then
            sed -i 's/.*LIBVIRTD_ARGS.*/LIBVIRTD_ARGS="--listen"/' /etc/default/libvirtd
        else
            echo 'LIBVIRTD_ARGS="--listen"' >> /etc/default/libvirtd
        fi
    fi

    # UFW forward
    if [[ -f /etc/default/ufw ]]; then
        sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
    fi

    systemctl enable libvirtd cloudstack-agent
    systemctl restart libvirtd
    systemctl restart cloudstack-agent

    success "Agent KVM OK"
}

# =============================================================================
#  ÉTAPE 9 — FIREWALL (iptables idempotent)
# =============================================================================
step9_firewall() {
    info "=== ÉTAPE 9 : Firewall ==="

    # Helper idempotent
    add_rule() {
        local chain="$1"; shift
        iptables -C "$chain" "$@" 2>/dev/null || iptables -I "$chain" "$@"
    }

    # Ports Management Server
    add_rule INPUT -p tcp --dport 8080  -j ACCEPT
    add_rule INPUT -p tcp --dport 8443  -j ACCEPT
    add_rule INPUT -p tcp --dport 8250  -j ACCEPT
    add_rule INPUT -p tcp --dport 9090  -j ACCEPT
    add_rule INPUT -p tcp --dport 16509 -j ACCEPT

    # NFS
    add_rule INPUT -p tcp --dport 111   -j ACCEPT
    add_rule INPUT -p udp --dport 111   -j ACCEPT
    add_rule INPUT -p tcp --dport 2049  -j ACCEPT
    add_rule INPUT -p tcp --dport 32803 -j ACCEPT
    add_rule INPUT -p udp --dport 32769 -j ACCEPT
    add_rule INPUT -p tcp --dport 892   -j ACCEPT
    add_rule INPUT -p tcp --dport 875   -j ACCEPT
    add_rule INPUT -p tcp --dport 662   -j ACCEPT

    # Forward VMs
    add_rule FORWARD -i cloudbr0 -j ACCEPT
    add_rule FORWARD -o cloudbr0 -j ACCEPT

    mkdir -p /etc/iptables
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
    else
        iptables-save > /etc/iptables/rules.v4
    fi

    success "Firewall OK (règles idempotentes)"
}

# =============================================================================
#  ÉTAPE 10 — DÉMARRAGE
# =============================================================================
step10_start_verify() {
    info "=== ÉTAPE 10 : Démarrage ==="

    systemctl enable cloudstack-management
    systemctl restart cloudstack-management

    info "Attente du Management Server (jusqu'à 3 min)..."
    local ok=0
    for _ in $(seq 1 36); do
        if curl -fsS "http://localhost:8080/client" &>/dev/null; then
            success "CloudStack UP !"
            ok=1; break
        fi
        echo -n "."
        sleep 5
    done
    echo ""
    [[ "$ok" -eq 1 ]] || warn "Management Server pas encore prêt — vérifier /var/log/cloudstack/management/"

    info "=== ÉTAT DES SERVICES ==="
    for svc in mysql nfs-kernel-server libvirtd cloudstack-management cloudstack-agent; do
        if systemctl is-active --quiet "$svc"; then
            success "$svc : actif"
        else
            warn "$svc : inactif"
        fi
    done
}

# =============================================================================
#  RÉSUMÉ
# =============================================================================
print_summary() {
    # Sauver les mdp générés dans un fichier root-only
    local CREDS_FILE="/root/.cloudstack-credentials"
    umask 077
    cat > "$CREDS_FILE" <<EOF
# Généré le $(date -Iseconds) par install_cloudstack.sh
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS}"
MYSQL_CLOUD_PASS="${MYSQL_CLOUD_PASS}"
MGMT_SERVER_KEY="${MGMT_SERVER_KEY}"
DB_KEY="${DB_KEY}"
EOF
    chmod 600 "$CREDS_FILE"

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}INSTALLATION TERMINÉE${NC}"
    echo "============================================================"
    echo "  Interface Web : ${GREEN}http://${HOST_IP}:8080/client${NC}"
    echo "  Login par défaut : admin / password  (À CHANGER immédiatement)"
    echo ""
    echo "  Credentials sauvegardés dans : $CREDS_FILE  (chmod 600)"
    echo "    - MYSQL_ROOT_PASS, MYSQL_CLOUD_PASS, MGMT_SERVER_KEY, DB_KEY"
    echo ""
    echo "  Stockage NFS :"
    echo "    Primary   : ${HOST_IP}:${PRIMARY_DIR}"
    echo "    Secondary : ${HOST_IP}:${SECONDARY_DIR}"
    echo ""
    echo "  Log : $LOG (chmod 600)"
    echo ""
    echo "  Prochaines étapes :"
    echo "    1. Se connecter à http://${HOST_IP}:8080/client"
    echo "    2. Changer le mot de passe admin"
    echo "    3. Créer Zone → Pod → Cluster KVM"
    echo "    4. Ajouter Primary + Secondary Storage"
    echo "    5. Enregistrer un template OS"
    echo "    6. Déployer ta première VM"
    echo "============================================================"
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
    check_root
    detect_ubuntu_version
    check_virtualization
    check_disks_safety
    check_disk_space
    print_banner

    step1_prerequisites
    step1b_disks
    step2_ssh
    step3_network
    step4_nfs
    step5_mysql
    step6_cloudstack_management
    step7_systemvm
    step8_kvm_agent
    step9_firewall
    step10_start_verify
    print_summary
}

main "$@"
