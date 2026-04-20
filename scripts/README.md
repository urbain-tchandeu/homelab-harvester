# Scripts

Scripts d'automatisation utilisés dans mon homelab (Harvester + Kubernetes + CloudStack).

> ⚠️ **Versions anonymisées.** Les IPs, noms de domaine et hostnames ont été remplacés par des placeholders :
> - Réseau : `192.0.2.0/24` (RFC 5737 — plage de documentation)
> - Domaine : `lab.example`
> - Hostname : `cloudstack`
>
> Adapte-les à ton contexte avant exécution.

---

## `install_cloudstack.sh`

Installation **all-in-one** d'Apache CloudStack 4.22 sur Dell PowerEdge R630 sous Ubuntu 22.04/24.04 — Management Server + KVM Agent sur la même machine.

### Ce que fait le script

- **Pré-checks** : root, version Ubuntu supportée, virtualisation matérielle (VT-x/AMD-V), espace disque `/var` > 20 Go
- **Garde-fou disque** : refuse de wipe le disque système (celui qui porte `/`)
- **Réseau** : configure netplan avec un bridge `cloudbr0` sur NIC physique
- **NFS** : expose `/export/primary` et `/export/secondary` restreint au subnet local
- **MySQL 8** : installation + tuning CloudStack (`max_connections`, `innodb_rollback_on_timeout`…)
- **CloudStack** : repo officiel, management server + agent KVM + usage
- **SystemVM template** : seed x86_64 pour KVM
- **Firewall** : règles iptables idempotentes (ports management 8080/8250, NFS, MySQL local)
- **Time sync** : chrony (pas de conflit avec openntpd)
- **Timezone** : `America/Toronto`

### Utilisation

```bash
# 1. (Optionnel) — mots de passe MySQL depuis un fichier .env
cat > /root/.cloudstack-install.env <<EOF
MYSQL_ROOT_PASS='votre_mdp_root'
MYSQL_CLOUD_PASS='votre_mdp_cloud'
EOF
chmod 600 /root/.cloudstack-install.env

# 2. Exécution
chmod +x install_cloudstack.sh
sudo bash install_cloudstack.sh
```

Sans `.env`, les mots de passe sont **générés aléatoirement** et affichés en fin d'exécution (à noter tout de suite !).

### ⚠️ Précautions avant de lancer

1. **Démarrer via console locale / iDRAC**, pas via SSH. Le script bascule la NIC sur le bridge `cloudbr0` → coupure réseau courte.
2. **Vérifier les disques** avec `lsblk` :
   - `/` doit être sur le SSD système
   - `/dev/sda` doit être le disque primary (volumes VMs)
   - `/dev/nvme0n1` doit être le disque secondary (templates, ISO)
3. **Adapter les variables** en haut du script : `NIC`, `HOST_IP`, `GATEWAY`, `DNS1`, `SEARCH_DOMAIN`, `HOSTNAME`, `PRIMARY_DISK`, `SECONDARY_DISK`.

### Post-install

Interface web : `http://<HOST_IP>:8080/client`
Credentials par défaut : `admin` / `password` (à changer immédiatement).

Un runbook post-install (création Zone / Pod / Cluster / template OS) est prévu dans `docs/`.

---

## `deploy-project.sh`

Squelette de déploiement multi-projet (WIP).
