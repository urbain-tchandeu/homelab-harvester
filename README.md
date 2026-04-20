# 🏠 Homelab Harvester — Cloud privé maison

> Un cloud privé complet qui tourne à la maison, utilisé comme laboratoire d'apprentissage et comme vitrine technique.

[![Harvester](https://img.shields.io/badge/Harvester-rc6-0095C8)](https://harvesterhci.io/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-K8s-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Rancher](https://img.shields.io/badge/Rancher-2.x-0075A8?logo=rancher&logoColor=white)](https://rancher.com/)
[![Wazuh](https://img.shields.io/badge/Wazuh-SIEM-3B82F6)](https://wazuh.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## 🎯 Pourquoi ce lab existe

Ce dépôt documente l'infrastructure que j'opère chez moi pour :

- **Me former** en continu (AZ-104, CLF-C02, CKA en préparation)
- **Tester** avant de proposer quoi que ce soit à un client
- **Démontrer** concrètement ce que je sais faire

Tout ce que je propose en mission freelance, je l'ai d'abord cassé et réparé ici.

## 🏗️ Architecture

![Architecture du lab](images/architecture.png)

### Composants principaux

| Couche | Techno | Rôle |
|---|---|---|
| Virtualisation | **Harvester rc6** | Hyperviseur cloud-native |
| Orchestration | **Rancher** | Gestion multi-cluster Kubernetes |
| Clusters | **k8s-cloud** | Cluster Kubernetes principal |
| Réseau | **5 VPCs** | Isolation des projets, NAT Gateway, SNAT/DNAT |
| Sécurité | **Wazuh** + **Sophos** | SIEM/XDR + pare-feu périmétrique |

## 🌐 Réseau — 5 VPCs isolés

Chaque projet tourne dans son propre VPC avec :

- Son propre range IP
- Une NAT Gateway sortante
- Des règles SNAT/DNAT pour exposer uniquement ce qui doit l'être
- Isolation stricte entre projets (zero trust par défaut)

Détails : [docs/networking.md](docs/networking.md)

## 🔒 Sécurité

- **Wazuh** — collecte de logs, détection d'anomalies, alertes temps réel
- **Sophos** — pare-feu périmétrique, filtrage applicatif, VPN
- Rapports de sécurité quotidiens automatisés
- Principe : logguer tout, alerter sur ce qui compte

Détails : [docs/security.md](docs/security.md)

## 🚀 Déploiement automatisé

Le script [`scripts/deploy-project.sh`](scripts/deploy-project.sh) provisionne un nouveau projet complet :

1. Création du VPC dédié
2. Configuration NAT / SNAT / DNAT
3. Provisionnement du namespace Kubernetes
4. Déploiement des workloads
5. Intégration au SIEM Wazuh

Durée moyenne : ~5 minutes (vs ~30 min en manuel).

## 📖 Ce que ce lab m'a appris

- **Harvester rc6 en prod maison** : pièges, workarounds, stabilité
- **Kubernetes multi-tenant** : comment bien isoler sans se compliquer la vie
- **SIEM sur petite infra** : configurer Wazuh pour ne pas crouler sous les faux positifs
- **NAT complexe** : 5 VPCs, ça se gère, mais il faut documenter

## 🛠️ Stack complète

- **OS** : Linux (Ubuntu / SLE)
- **Hyperviseur** : Harvester rc6
- **Orchestration** : Kubernetes, Rancher
- **Réseau** : VPC, NAT Gateway, SNAT/DNAT
- **Sécurité** : Wazuh (SIEM), Sophos (firewall), Active Directory
- **Automatisation** : Bash, kubectl, YAML manifests

## 📬 Me contacter

Je prends des missions freelance en Cloud, Kubernetes et sécurité.
**Disponibilité :** 15–20 h/semaine, soirs et weekends.

- 🔗 [LinkedIn](https://linkedin.com/in/urbain-tchandeu)
- 📧 urbaintchandeu@yahoo.com
- 🏢 Société par actions (.inc) — facturation professionnelle

---

## 📄 Licence

MIT — voir [LICENSE](LICENSE).

Les détails spécifiques à ma production (IPs, noms de domaine, secrets) ne sont **pas** dans ce dépôt. Seuls les patterns et l'architecture sont publics.
