#!/usr/bin/env bash
#
# install-immich.sh — Déploiement d'Immich via Docker Compose, en utilisant
# les fichiers docker-compose.yml et .env officiels publiés par le projet
# (pas de réécriture maison de la stack, pour rester à jour avec les
# changements internes d'Immich — Postgres, Redis/Valkey, ML, etc.)
#
# PRÉREQUIS : Docker Engine doit être installé (voir install-docker-engine.sh).
#
# Usage :
#   sudo ./install-immich.sh
#   sudo ./install-immich.sh --upload-dir /srv/photos
#   sudo ./install-immich.sh --dry-run
#
# ⚠️  MATÉRIEL : Immich recommande officiellement 8 Go de RAM et 4 cœurs CPU
#   pour un usage confortable (reconnaissance faciale, recherche IA). Le
#   script vérifie et affiche vos ressources réelles mais n'empêche pas
#   l'installation sur du matériel plus modeste — attendez-vous seulement à
#   un premier scan de bibliothèque plus lent.

set -Eeuo pipefail

UPLOAD_DIR="/srv/photos"
COMPOSE_DIR="/opt/immich"
CONFIGURE_FIREWALL=1
DRY_RUN=0
IMMICH_PORT=2283

if [[ -t 1 ]]; then
  C_OK=$'\033[0;32m'; C_ERR=$'\033[0;31m'; C_WARN=$'\033[0;33m'
  C_INFO=$'\033[0;36m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_ERR=""; C_WARN=""; C_INFO=""; C_OFF=""
fi

info()  { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
ok()    { printf '%s [OK]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()   { trap - ERR; printf '%s[ERREUR]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
dry()   { printf '%s[dry-run]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }

run() { if [[ "$DRY_RUN" -eq 1 ]]; then dry "$*"; else "$@"; fi; }

trap 'die "Échec à la ligne $LINENO (commande : $BASH_COMMAND)"' ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upload-dir) UPLOAD_DIR="${2:?chemin manquant}"; shift 2 ;;
    --no-firewall) CONFIGURE_FIREWALL=0; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Option inconnue : $1" ;;
  esac
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s[MODE SIMULATION]%s\n' "$C_WARN" "$C_OFF"
fi

info "Vérifications préalables"
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  [[ "$DRY_RUN" -eq 1 ]] && warn "Pas root : vérifications limitées." || die "Lancez avec sudo."
fi

command -v docker >/dev/null 2>&1 || die "Docker n'est pas installé. Lancez d'abord install-docker-engine.sh."
docker compose version >/dev/null 2>&1 || die "Le plugin 'docker compose' est introuvable."
ok "Docker et le plugin Compose sont disponibles"

# Ressources matérielles — informatif, non bloquant
TOTAL_RAM_MB="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"
CPU_CORES="$(nproc 2>/dev/null || echo '?')"
if [[ -n "${TOTAL_RAM_MB:-}" ]]; then
  TOTAL_RAM_GB=$(( TOTAL_RAM_MB / 1024 ))
  if [[ "$TOTAL_RAM_GB" -lt 8 || "$CPU_CORES" -lt 4 ]]; then
    warn "Ressources sous la recommandation officielle Immich (8 Go RAM / 4 cœurs).
      Détecté : ${TOTAL_RAM_GB} Go RAM, ${CPU_CORES} cœurs.
      Immich fonctionnera, mais la reconnaissance faciale et la recherche IA
      seront lentes lors du premier scan d'une grosse bibliothèque."
  else
    ok "Ressources : ${TOTAL_RAM_GB} Go RAM, ${CPU_CORES} cœurs (confortable)"
  fi
fi

if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${IMMICH_PORT}\$"; then
  die "Le port $IMMICH_PORT est déjà occupé."
fi

COMPOSE_URL="https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml"
ENV_URL="https://github.com/immich-app/immich/releases/latest/download/example.env"

if ! curl -fsSI --max-time 15 "$COMPOSE_URL" >/dev/null; then
  die "Impossible de joindre GitHub — vérifiez DNS / réseau / proxy."
fi
ok "Accès réseau à GitHub confirmé"

info "Préparation des répertoires"
run install -d -m 0755 "$COMPOSE_DIR"
run install -d -m 0750 "$UPLOAD_DIR"

# ----------------------------------------------------------------------------
# Récupération des fichiers OFFICIELS (pas de réécriture maison)
# ----------------------------------------------------------------------------
info "Téléchargement des fichiers officiels Immich (docker-compose.yml, .env)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "curl -fsSL -o $COMPOSE_DIR/docker-compose.yml $COMPOSE_URL"
  dry "curl -fsSL -o $COMPOSE_DIR/.env $ENV_URL"
else
  curl -fsSL --retry 3 --retry-delay 2 --max-time 30 -o "$COMPOSE_DIR/docker-compose.yml" "$COMPOSE_URL"
  curl -fsSL --retry 3 --retry-delay 2 --max-time 30 -o "$COMPOSE_DIR/.env" "$ENV_URL"
  ok "Fichiers officiels téléchargés dans $COMPOSE_DIR"
fi

# ----------------------------------------------------------------------------
# Personnalisation du .env (mot de passe DB aléatoire, chemin, fuseau horaire)
# ----------------------------------------------------------------------------
info "Personnalisation du fichier .env"
DB_PASS="$(openssl rand -hex 16)"
SYSTEM_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"

if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "UPLOAD_LOCATION=$UPLOAD_DIR"
  dry "DB_PASSWORD=<généré aléatoirement, 32 caractères>"
  [[ -n "$SYSTEM_TZ" ]] && dry "TZ=$SYSTEM_TZ"
else
  sed -i "s|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=${UPLOAD_DIR}|" "$COMPOSE_DIR/.env"
  sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" "$COMPOSE_DIR/.env"
  if [[ -n "$SYSTEM_TZ" ]]; then
    sed -i "s|^# TZ=.*|TZ=${SYSTEM_TZ}|" "$COMPOSE_DIR/.env"
    ok "Fuseau horaire détecté et appliqué : $SYSTEM_TZ"
  fi
  chmod 600 "$COMPOSE_DIR/.env"
  ok "Fichier .env personnalisé (permissions restreintes 600)"
fi

# ----------------------------------------------------------------------------
# Démarrage
# ----------------------------------------------------------------------------
info "Démarrage de la stack Immich (peut prendre plusieurs minutes au premier lancement — téléchargement des images)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "cd $COMPOSE_DIR && docker compose up -d"
else
  (cd "$COMPOSE_DIR" && docker compose up -d)
fi

READY=0
if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "attente du port $IMMICH_PORT (ignorée en simulation)"
else
  info "Attente du démarrage sur le port $IMMICH_PORT… (patience, plusieurs services démarrent)"
  for _ in $(seq 1 120); do
    if curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:${IMMICH_PORT}/"; then
      READY=1; break
    fi
    sleep 2
  done
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  :
elif [[ "$READY" -eq 1 ]]; then
  ok "Immich répond sur http://127.0.0.1:${IMMICH_PORT}"
else
  warn "Immich ne répond pas encore (normal si RAM/CPU limités au premier démarrage). Diagnostic :
      cd $COMPOSE_DIR && docker compose ps
      cd $COMPOSE_DIR && docker compose logs -f immich-server"
fi

if [[ "$CONFIGURE_FIREWALL" -eq 1 ]] && command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q "^Status: active"; then
    info "Ouverture du port Immich dans UFW"
    run ufw allow "${IMMICH_PORT}/tcp" comment 'Immich - acces web'
    ok "Règle UFW appliquée"
  fi
fi

IP_LAN="$(hostname -I 2>/dev/null | awk '{print $1}')"
IP_LAN="${IP_LAN:-<ip-du-serveur>}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF

────────────────────────────────────────────────────────────────
 Simulation terminée — rien n'a été modifié
────────────────────────────────────────────────────────────────
 Fichiers officiels accessibles, répertoires vérifiés.
 Pour lancer l'installation :  sudo $0 ${*:-}
────────────────────────────────────────────────────────────────
EOF
  exit 0
fi

cat <<EOF

────────────────────────────────────────────────────────────────
 ${C_OK}Immich installé${C_OFF}
────────────────────────────────────────────────────────────────
 Compose file  : $COMPOSE_DIR/docker-compose.yml
 Config (.env) : $COMPOSE_DIR/.env
 Dossier photos: $UPLOAD_DIR
 Port          : $IMMICH_PORT

 ${C_INFO}Accès${C_OFF}
   Local  : http://127.0.0.1:${IMMICH_PORT}
   Réseau : http://${IP_LAN}:${IMMICH_PORT}

 Le premier compte créé devient administrateur — connectez-vous
 tout de suite. Installez ensuite l'appli mobile (iOS/Android) et
 activez la sauvegarde automatique des photos.

 ${C_INFO}Commandes utiles${C_OFF}
   cd $COMPOSE_DIR && docker compose ps
   cd $COMPOSE_DIR && docker compose logs -f
   cd $COMPOSE_DIR && docker compose down     (données conservées)
────────────────────────────────────────────────────────────────
EOF
