#!/usr/bin/env bash
# hosting-dns.sh - Record DNS base per un hosting myVesta (Exim) con DNS esterno Hetzner.
# Uso: hosting-dns.sh <dominio> [--mx <sub>] [--no-mx] [--regen [bit]]
#   --mx <sub>   host di posta del cliente (default: mail -> mail.<dominio>)
#   --no-mx      posta in arrivo su altro provider: niente MX/mail/webmail/SRV
#   --regen [n]  rigenera la chiave DKIM via pannello (default 2048 bit)
# Env: PUB_DNS IP4 IP6 SPF_ALL DMARC_POLICY DMARC_RUA CAA_CA SELECTOR TTL ZONE_DIR
set -euo pipefail
trap 'echo "ERR: errore alla riga $LINENO" >&2' ERR
export PATH="$PATH:/usr/local/vesta/bin:/usr/local/hestia/bin"

usage(){ sed -n '3,7p' "$0"; exit 1; }
[[ $# -ge 1 ]] || usage
D="${1,,}"; shift
[[ "$D" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$ ]] \
  || { echo "ERR: '$D' non e' un nome di dominio valido" >&2; exit 1; }
REGEN=0; BITS=2048; MX_SUB="mail"; DO_MX=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --regen) REGEN=1; [[ "${2:-}" =~ ^[0-9]+$ ]] && { BITS="$2"; shift; } ;;
    --mx)    MX_SUB="${2:?--mx richiede un sottodominio}"; MX_SUB="${MX_SUB,,}"; shift ;;
    --no-mx) DO_MX=0 ;;
    *) usage ;;
  esac; shift
done

# ---------------- Configurazione ----------------
PUB_DNS="${PUB_DNS:-1.1.1.1}"                 # resolver pubblico (ignora zone locali)
SRV_HOST="$(hostname -f)"
# IP del server: la risposta DNS non e' autenticata, quindi deve coincidere con un indirizzo
# pubblico configurato sulle interfacce (se leggibili). Divergenza = stop; IP4=/IP6= forzano.
loc_ips(){ # $1 4|6: indirizzi globali, esclusi privati/CGNAT/ULA (server dietro NAT -> vuoto)
  ip -"$1" -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
    | grep -Eiv '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|f[cd])' || true
}
pick_ip(){ # $1 A|AAAA, $2 4|6, $3 filtro
  local dns loc; dns=$(dig +short "$1" "$SRV_HOST" @"$PUB_DNS" | grep -E "$3" | tail -1 || true); loc=$(loc_ips "$2")
  if [[ -n "$dns" && -n "$loc" ]] && ! grep -qxF "$dns" <<<"$loc"; then
    echo "ERR: $SRV_HOST risolve $dns ma le interfacce hanno $(paste -sd',' - <<<"$loc"): DNS alterato? imposta IP$2=..." >&2
    return 1
  fi
  echo "$dns"
}
IP4="${IP4:-$(pick_ip A 4 '^[0-9.]+$')}"
IP6="${IP6:-$(pick_ip AAAA 6 ':')}"
SELECTOR="${SELECTOR:-mail}"
SPF_ALL="${SPF_ALL:--all}"
DMARC_POLICY="${DMARC_POLICY:-quarantine}"
DMARC_RUA="${DMARC_RUA:-postmaster@$D}"
CAA_CA="${CAA_CA:-letsencrypt.org}"
TTL="${TTL:-300}"
ZONE_DIR="${ZONE_DIR:-/root/dns-zones}"
MX_HOST="${MX_SUB}.${D}"
KEY="/etc/exim4/domains/$D/dkim.pem"

# --mx e SELECTOR finiscono in query dig e in pattern grep: solo etichette DNS
LAB='^[a-z0-9]([a-z0-9.-]{0,61}[a-z0-9])?$'
[[ "$MX_SUB"   =~ $LAB ]] || { echo "ERR: --mx '$MX_SUB' non e' un nome valido" >&2; exit 1; }
[[ "$SELECTOR" =~ $LAB ]] || { echo "ERR: SELECTOR '$SELECTOR' non e' un nome valido" >&2; exit 1; }

[[ -n "$IP4" ]] || { echo "ERR: IPv4 di $SRV_HOST non risolto (imposta IP4=...)"; exit 1; }

# ---------------- DKIM ----------------
if (( REGEN )); then
  OWNER=$(v-search-domain-owner "$D" mail 2>/dev/null || true)
  [[ -n "$OWNER" ]] || { echo "ERR: proprietario di $D non trovato nel pannello"; exit 1; }
  echo ">> Rigenero DKIM a $BITS bit per $D (utente $OWNER)"
  v-delete-mail-domain-dkim "$OWNER" "$D" >/dev/null 2>&1 || true
  v-add-mail-domain-dkim "$OWNER" "$D" "$BITS"
fi
PUB=""; SIZE=""
if [[ -r "$KEY" ]]; then
  SIZE=$(openssl rsa -in "$KEY" -noout -text 2>/dev/null | sed -n 's/.*(\([0-9]*\) bit.*/\1/p' | head -1)
  PUB=$(openssl rsa -in "$KEY" -pubout -outform der 2>/dev/null | openssl base64 -A)
fi

# ---------------- Helper ----------------
NS=$(dig +short NS "$D" @"$PUB_DNS" | head -1); [[ "$NS" =~ ^[a-zA-Z0-9.-]+$ ]] || NS="$PUB_DNS"
# DNSSEC: flag AD dal resolver se la zona e' firmata e valida. Solo informativo: senza firma
# il verdetto vale quanto la fiducia nel percorso verso PUB_DNS e NS.
if dig +adflag NS "$D" @"$PUB_DNS" 2>/dev/null | grep -Eq '^;; flags:[a-z ]* ad[ ;]'; then DNSSEC="validata"
else DNSSEC="zona non firmata, controllo non autenticato"; fi
fq(){ [[ "$1" == "@" ]] && echo "$D" || echo "$1.$D"; }
q(){ dig +short "$1" "$(fq "$2")" @"$NS" 2>/dev/null || true; }
txt(){ q TXT "$1" | sed 's/" "//g; s/"//g'; }
fmt(){ if (( ${#1} > 255 )); then printf '%s' "$1" | fold -w 250 | sed 's/.*/"&"/' | paste -sd' ' -; else echo "\"$1\""; fi; }
cnt(){ grep -c . <<<"$1" || true; }
chk(){ # $1 attuale (multi-riga), $2 atteso: record di cui deve esistere una sola istanza
  local n; n=$(cnt "$1")
  if   (( n == 0 )); then echo "ASSENTE"
  elif (( n > 1 ));  then echo "$n RECORD -> lasciane uno"
  elif [[ "$1" == "$2" ]]; then echo "OK"
  else echo "DIVERSO -> $1"; fi
}
ip_ok(){ # $1 nome, $2 tipo A|AAAA, $3 atteso (segue i CNAME; piu' indirizzi = DIVERSO, non duplicato)
  local re='^[0-9.]+$' cur; [[ "$2" == AAAA ]] && re=':'
  cur=$(q "$2" "$1" | grep -E "$re" | sort -u)
  if   [[ -z "$cur" ]]; then echo "ASSENTE"
  elif [[ "$cur" == "$3" ]]; then echo "OK"
  else echo "DIVERSO -> $(paste -sd',' - <<<"$cur")"; fi
}

T=(); N=(); V=(); S=()
add(){ T+=("$1"); N+=("$2"); V+=("$3"); S+=("$4"); }

# ---------------- Record ----------------
add A     "@"    "$IP4"   "$(ip_ok @ A "$IP4")"
[[ -n "$IP6" ]] && add AAAA "@" "$IP6" "$(ip_ok @ AAAA "$IP6")"
add CNAME "www"  "$D."    "$(ip_ok www A "$IP4")"
add CNAME "ftp"  "$D."    "$(ip_ok ftp A "$IP4")"

if (( DO_MX )); then
  add A "$MX_SUB" "$IP4" "$(ip_ok "$MX_SUB" A "$IP4")"
  [[ -n "$IP6" ]] && add AAAA "$MX_SUB" "$IP6" "$(ip_ok "$MX_SUB" AAAA "$IP6")"
  add CNAME "webmail" "$D." "$(ip_ok webmail A "$IP4")"

  CUR_MX=$(q MX @)
  if [[ -z "$CUR_MX" ]]; then ST="ASSENTE"
  elif [[ "$(cnt "$CUR_MX")" == 1 ]] && grep -qi " ${MX_HOST}\.$" <<<"$CUR_MX"; then ST="OK"
  else ST="DIVERSO -> $(paste -sd',' - <<<"$CUR_MX") (posta in arrivo oggi li')"; fi
  add MX "@" "10 ${MX_HOST}." "$ST"

  add SRV "_imaps._tcp"       "0 1 993 ${MX_HOST}." "$(chk "$(q SRV _imaps._tcp)" "0 1 993 ${MX_HOST}.")"
  add SRV "_submission._tcp"  "0 1 587 ${MX_HOST}." "$(chk "$(q SRV _submission._tcp)" "0 1 587 ${MX_HOST}.")"
fi

SPF="v=spf1$( (( DO_MX )) && echo " mx") ip4:${IP4}${IP6:+ ip6:$IP6} ${SPF_ALL}"
add TXT "@" "$(fmt "$SPF")" "$(chk "$(txt @ | grep -i '^v=spf1' || true)" "$SPF")"

if [[ -n "$PUB" ]]; then
  DKIM="v=DKIM1; k=rsa; p=${PUB}"
  CUR=$(txt "${SELECTOR}._domainkey")
  if   [[ -z "$CUR" ]]; then ST="ASSENTE"
  elif (( $(cnt "$CUR") > 1 )); then ST="$(cnt "$CUR") RECORD -> lasciane uno"
  elif [[ "$(tr -d ' ' <<<"$CUR" | sed -n 's/.*p=\([^;]*\).*/\1/p')" == "$PUB" ]]; then ST="OK"
  else ST="DIVERSO dalla chiave di Exim"; fi
  # s=mail non e' valido (s= accetta solo "email" o "*"): segnalalo e non contarlo come OK
  if grep -q 's=mail' <<<"$CUR"; then [[ "$ST" == OK ]] && ST="CHIAVE OK"; ST+=" (rimuovi s=mail)"; fi
  add TXT "${SELECTOR}._domainkey" "$(fmt "$DKIM")" "$ST [$SIZE bit]"
else
  echo "ATTENZIONE: chiave DKIM assente ($KEY) -> attiva DKIM nel pannello o usa --regen"
fi

DMARC="v=DMARC1; p=${DMARC_POLICY}; rua=mailto:${DMARC_RUA}; adkim=r; aspf=r"
add TXT "_dmarc" "$(fmt "$DMARC")" "$(chk "$(txt _dmarc | grep -i '^v=DMARC1' || true)" "$DMARC")"

CUR_CAA=$(q CAA @)
if [[ -z "$CUR_CAA" ]]; then ST="ASSENTE"
elif grep -q "issue \"$CAA_CA\"" <<<"$CUR_CAA"; then ST="OK"
else ST="DIVERSO -> $(paste -sd',' - <<<"$CUR_CAA")"; fi
add CAA "@" "0 issue \"$CAA_CA\"" "$ST"

# ---------------- Output ----------------
mkdir -p "$ZONE_DIR"; ZF="$ZONE_DIR/$D.zone"
{
  echo "; $D - generato $(date '+%F %T') da hosting-dns.sh (SOA/NS gestiti da Hetzner)"
  echo "\$ORIGIN $D."
  echo "\$TTL $TTL"
} > "$ZF"

KO=0
echo "================ $D  (NS: $NS; DNSSEC: $DNSSEC) ================"
printf '%-6s %-20s %s\n' "TIPO" "NOME" "VALORE"
for i in "${!T[@]}"; do
  printf '%-6s %-20s %s\n' "${T[$i]}" "${N[$i]}" "${V[$i]}"
  printf '%27s %s\n' "->" "${S[$i]}"
  [[ "${S[$i]}" == OK* ]] || KO=$((KO+1))
  printf '%-24s %s IN %-5s %s\n' "${N[$i]}" "$TTL" "${T[$i]}" "${V[$i]}" >> "$ZF"
done

PTR=$(dig +short -x "$IP4" @"$PUB_DNS" | sed 's/\.$//')
echo
[[ "$PTR" == "$SRV_HOST" ]] && echo "PTR $IP4 -> $PTR : OK" \
  || echo "PTR $IP4 -> ${PTR:-assente} : deve essere $SRV_HOST (reverse dal pannello del server)"
echo "Record da sistemare: $KO / ${#T[@]}"
echo "File zona importabile su Hetzner: $ZF"
exit 0
