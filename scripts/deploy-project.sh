#!/usr/bin/env bash
# deploy-project.sh — provisionne un nouveau projet (VPC + NAT + namespace K8s + intégration Wazuh)
# Version publique (anonymisée). La version prod est privée.
set -euo pipefail

PROJECT_NAME="${1:?Usage: $0 <project-name>}"

echo "[1/5] Création du VPC pour $PROJECT_NAME..."
echo "[2/5] Configuration NAT / SNAT / DNAT..."
echo "[3/5] Provisionnement namespace Kubernetes..."
echo "[4/5] Déploiement des workloads..."
echo "[5/5] Intégration au SIEM Wazuh..."
echo "✓ Projet $PROJECT_NAME prêt."
