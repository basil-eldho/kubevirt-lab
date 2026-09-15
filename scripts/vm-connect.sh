#!/usr/bin/env bash
# Publish a VM's desktop through Guacamole and print an auto-login URL.
#
# Usage: ./scripts/vm-connect.sh <vm-name> <ubuntu|windows>
#        make vm-url NAME=<vm-name> OS=<ubuntu|windows>
#
# `make vm` runs this at the end, so it is rarely called directly — reach for it
# when a token has expired and you want a fresh link.
#
# Idempotent, but it needs Guacamole and the nginx proxy running (`make vm`
# deploys them). The URL only works through that proxy, which adds the
# WebSocket upgrade headers Guacamole's tunnel requires.

set -euo pipefail

NAME="${1:?usage: vm-connect.sh <vm-name> <ubuntu|windows>}"
OS="${2:?usage: vm-connect.sh <vm-name> <ubuntu|windows>}"

NAMESPACE="${NAMESPACE:-default}"
PORTAL_PORT="${PORTAL_PORT:-30000}"
GUAC_USER="${GUACAMOLE_USER:-guacadmin}"
GUAC_PASS="${GUACAMOLE_PASS:-guacadmin}"
GUAC_DS="${GUACAMOLE_DATA_SOURCE:-mysql}"

# Throwaway lab values matching the golden images. VNC truncates to 8 bytes, so
# Ubuntu's must stay 8 chars — see golden/ubuntu/scripts/setup-desktop.sh.
UBUNTU_VNC_PASS="${UBUNTU_VNC_PASS:-Lab@2024}"
WINDOWS_USER="${WINDOWS_USER:-student}"
WINDOWS_PASS="${WINDOWS_PASS:-Lab@2024!}"

case "$OS" in
  ubuntu)  PROTOCOL=vnc; PORT=5900 ;;
  windows) PROTOCOL=rdp; PORT=3389 ;;
  *) echo "OS must be ubuntu or windows" >&2; exit 1 ;;
esac

NODE_IP=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
GUAC="http://${NODE_IP}:${PORTAL_PORT}/guacamole"
SVC="desktop-${NAME}"

# ── 1. ClusterIP Service so guacd can reach the in-guest listener ─────────────
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
  namespace: ${NAMESPACE}
  labels:
    app: lab-vm
spec:
  type: ClusterIP
  selector:
    kubevirt.io/vm: ${NAME}
  ports:
  - name: ${PROTOCOL}
    port: ${PORT}
    targetPort: ${PORT}
    protocol: TCP
EOF

HOSTNAME="${SVC}.${NAMESPACE}.svc.cluster.local"

# ── 2. Wait until the desktop actually answers ────────────────────────────────
# The OS booting is not enough: x11vnc reattaches after the autologin X restart,
# and guacd gives up after ~5s of nothing listening, leaving a black canvas.
# Step 2a below gates on a real session; this only waits for the Service to have
# an endpoint to route to.
for i in $(seq 60); do
  [ -n "$(kubectl get endpoints "$SVC" -n "$NAMESPACE" \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ] && break
  sleep 2
done

# ── 2a. Wait for a desktop session, not just a listening port ─────────────────
# Windows binds 3389 early in boot, long before the shell is up, so the TCP probe
# below can pass while guacd still times out on the RDP handshake — a link that
# opens on a timeout or a black canvas. The guest agent's userlist reports the
# autologin session both golden images create, which is the signal that there is
# actually a desktop to serve.
#
# Best-effort: an image whose guest agent never reports users would otherwise
# block here forever, so a timeout warns and falls through to the TCP probe.
USERLIST="/apis/subresources.kubevirt.io/v1/namespaces/${NAMESPACE}/virtualmachineinstances/${NAME}/userlist"
SESSION=no
for i in $(seq 150); do
  USERS=$(kubectl get --raw "$USERLIST" 2>/dev/null |
    python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("items") or []))' \
    2>/dev/null || echo 0)
  if [ "${USERS:-0}" -gt 0 ] 2>/dev/null; then SESSION=yes; break; fi
  sleep 2
done

if [ "$SESSION" != yes ]; then
  printf '\033[1;33m! %s: no logged-in session reported after 5 min — the desktop may\n' \
    "$NAME" >&2
  printf '  still be booting, and the link below can open on a black screen.\033[0m\n' >&2
fi

kubectl port-forward -n "$NAMESPACE" "svc/${SVC}" ":${PORT}" >/tmp/pf-$$.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true; rm -f /tmp/pf-$$.log' EXIT
for i in $(seq 30); do
  LOCAL_PORT=$(sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p' "/tmp/pf-$$.log" | head -1)
  [ -n "$LOCAL_PORT" ] && break
  sleep 1
done

READY=no
if [ -n "$LOCAL_PORT" ]; then
  for i in $(seq 90); do
    if timeout 2 bash -c ">/dev/tcp/127.0.0.1/${LOCAL_PORT}" 2>/dev/null; then
      READY=yes; break
    fi
    sleep 2
  done
fi
kill $PF_PID 2>/dev/null || true

if [ "$READY" != yes ]; then
  printf '\033[1;33m! %s:%s never started answering — the link would show a black screen.\n' \
    "$NAME" "$PORT" >&2
  printf '  Check the guest: virtctl console %s\033[0m\n' "$NAME" >&2
  exit 1
fi

# ── 3. Guacamole token ────────────────────────────────────────────────────────
TOKEN=$(curl -sS -X POST "${GUAC}/api/tokens" \
  -d "username=${GUAC_USER}&password=${GUAC_PASS}" |
  python3 -c 'import sys,json; print(json.load(sys.stdin)["authToken"])')

[ -n "$TOKEN" ] || { echo "guacamole returned no token" >&2; exit 1; }

CONNS_URL="${GUAC}/api/session/data/${GUAC_DS}/connections"

# ── 4. Reuse the connection if this VM already has one ────────────────────────
CONN_ID=$(curl -sS -H "Guacamole-Token: ${TOKEN}" "$CONNS_URL" |
  NAME="$NAME" python3 -c '
import sys, json, os
want = os.environ["NAME"]
for cid, c in json.load(sys.stdin).items():
    if c.get("name") == want:
        print(cid); break
')

if [ "$PROTOCOL" = vnc ]; then
  PARAMS=$(HOSTNAME="$HOSTNAME" PORT="$PORT" PW="$UBUNTU_VNC_PASS" python3 -c '
import json, os
print(json.dumps({"hostname": os.environ["HOSTNAME"], "port": os.environ["PORT"],
                  "password": os.environ["PW"], "color-depth": "24", "autoretry": "5"}))')
else
  PARAMS=$(HOSTNAME="$HOSTNAME" PORT="$PORT" U="$WINDOWS_USER" PW="$WINDOWS_PASS" python3 -c '
import json, os
print(json.dumps({"hostname": os.environ["HOSTNAME"], "port": os.environ["PORT"],
                  "username": os.environ["U"], "password": os.environ["PW"],
                  "security": "any", "ignore-cert": "true",
                  "resize-method": "display-update", "enable-drive": "false"}))')
fi

BODY=$(NAME="$NAME" PROTOCOL="$PROTOCOL" PARAMS="$PARAMS" python3 -c '
import json, os
print(json.dumps({"name": os.environ["NAME"], "protocol": os.environ["PROTOCOL"],
                  "parameters": json.loads(os.environ["PARAMS"]),
                  "attributes": {"max-connections": "1",
                                 "max-connections-per-user": "1"}}))')

if [ -z "$CONN_ID" ]; then
  CONN_ID=$(curl -sS -X POST "$CONNS_URL" \
    -H "Guacamole-Token: ${TOKEN}" -H 'Content-Type: application/json' \
    -d "$BODY" |
    python3 -c 'import sys,json; print(json.load(sys.stdin)["identifier"])')
else
  # Overwrite rather than reuse: a stale hostname or password shows as a black
  # screen, not an error.
  curl -sS -o /dev/null -X PUT "${CONNS_URL}/${CONN_ID}" \
    -H "Guacamole-Token: ${TOKEN}" -H 'Content-Type: application/json' \
    -d "$BODY"
fi

[ -n "$CONN_ID" ] || { echo "failed to create guacamole connection" >&2; exit 1; }

# ── 5. Scoped account so the link cannot reach any other VM ──────────────────
# The URL below must not carry the guacadmin token: it would let whoever opens
# it list every other connection, read its parameters (desktop hostname and
# password come back in plaintext), and connect. A throwaway account holding
# READ on this one connection turns all of that into 404s.
#
# Recreated on every run so the password rotates and the grant is never stale.
VM_USER="lab-vm-${NAME}"
VM_PASS=$(python3 -c 'import base64,os; print(base64.urlsafe_b64encode(os.urandom(24)).decode().rstrip("="))')

curl -sS -o /dev/null -X DELETE "${GUAC}/api/session/data/${GUAC_DS}/users/${VM_USER}" \
  -H "Guacamole-Token: ${TOKEN}" || true

USER_BODY=$(U="$VM_USER" P="$VM_PASS" python3 -c '
import json, os
print(json.dumps({"username": os.environ["U"], "password": os.environ["P"],
                  "attributes": {}}))')

curl -sS -o /dev/null -f -X POST "${GUAC}/api/session/data/${GUAC_DS}/users" \
  -H "Guacamole-Token: ${TOKEN}" -H 'Content-Type: application/json' \
  -d "$USER_BODY" || { echo "failed to create guacamole user ${VM_USER}" >&2; exit 1; }

PERM_BODY=$(CONN_ID="$CONN_ID" python3 -c '
import json, os
print(json.dumps([{"op": "add",
                   "path": "/connectionPermissions/" + os.environ["CONN_ID"],
                   "value": "READ"}]))')

curl -sS -o /dev/null -f -X PATCH \
  "${GUAC}/api/session/data/${GUAC_DS}/users/${VM_USER}/permissions" \
  -H "Guacamole-Token: ${TOKEN}" -H 'Content-Type: application/json' \
  -d "$PERM_BODY" || { echo "failed to grant ${VM_USER} access to ${NAME}" >&2; exit 1; }

# Swap the admin token for the scoped one — this is what goes in the URL.
TOKEN=$(curl -sS -X POST "${GUAC}/api/tokens" \
  -d "username=${VM_USER}&password=${VM_PASS}" |
  python3 -c 'import sys,json; print(json.load(sys.stdin)["authToken"])')

[ -n "$TOKEN" ] || { echo "guacamole returned no token for ${VM_USER}" >&2; exit 1; }

# Guacamole client ID is base64("{connID}\0c\0{dataSource}")
CLIENT_ID=$(CONN_ID="$CONN_ID" GUAC_DS="$GUAC_DS" python3 -c '
import base64, os
print(base64.b64encode(
    (os.environ["CONN_ID"] + "\0c\0" + os.environ["GUAC_DS"]).encode()).decode())')

printf '\n  \033[1m%s\033[0m — open in a browser:\n\n' "$NAME"
printf '  http://%s:%s/guacamole/#/client/%s?token=%s\n\n' \
  "$NODE_IP" "$PORTAL_PORT" "$CLIENT_ID" "$TOKEN"
printf '  Token expires after 60 min idle. Re-run for a fresh link:\n'
printf '    make vm-url NAME=%s OS=%s\n\n' "$NAME" "$OS"
