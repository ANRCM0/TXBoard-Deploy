#!/usr/bin/env bash
# Synthetic Docker CLI state machine: no Docker daemon, network, Node or DB.
set -Eeuo pipefail
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/bin"
export GW_TEST_STATE="$tmp/docker-state.json"
export GW_TEST_TRACE="$tmp/docker-trace"
cat > "$tmp/bin/docker" <<'PY'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
a=sys.argv[1:]; p=Path(os.environ['GW_TEST_STATE'])
s=json.loads(p.read_text()) if p.exists() else {'exists':False,'image':'sha256:'+'1'*64,'running':False,'health':'healthy'}
with open(os.environ['GW_TEST_TRACE'],'a') as f:f.write(json.dumps(a)+'\n')
def save():p.write_text(json.dumps(s))
if a[0]=='info':pass
elif a[0]=='ps':
    if s['exists']:print('fixture-container')
elif a[0]=='inspect':
    fmt=a[a.index('--format')+1]
    if fmt=='{{.Image}}':print(s['image'])
    elif 'working_dir' in fmt:print(s['dir']+'|gateway|gateway' if not os.getenv('GW_TEST_FOREIGN') else '/foreign|gateway|gateway')
    else:print(('running' if s['running'] else 'exited')+'|'+s['health'])
elif a[:2]==['image','inspect']:pass
elif a[0]=='compose':
    if a[1]=='version':sys.exit(0)
    d=a[a.index('--project-directory')+1]
    args=a[a.index('-f')+2:]
    cmd=args[0]
    env=dict(line.split('=',1) for line in (Path(d)/'.env').read_text().splitlines() if '=' in line)
    if cmd=='config':
        if os.getenv('GW_TEST_BAD_CONFIG'):print('private-parser-diagnostic');sys.exit(1)
    elif cmd=='pull':
        if os.getenv('GW_TEST_PULL_FAIL'):sys.exit(1)
    elif cmd=='up':
        image=env['TXGATEWAY_IMAGE']
        s.update(exists=True,running=True,dir=d,image=image if image.startswith('sha256:') else 'sha256:'+('2' if ':bad' in image else '1')*64,
            health='unhealthy' if ':bad' in image or os.getenv('GW_TEST_ALWAYS_UNHEALTHY') else 'healthy')
    elif cmd=='ps':
        if s['exists']:print('fixture-container')
    elif cmd=='stop':s['running']=False
    elif cmd=='down':s['exists']=False;s['running']=False
    elif cmd=='logs':print('synthetic Gateway logs')
    else:sys.exit(43)
    save()
else:sys.exit(44)
PY
chmod 700 "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH"
gateway=(bash "$repo/gateway/deploy.sh")
dir="$tmp/gateway"
printf '%s\n' 'GATEWAY_METRICS_TOKEN="fixture-secret-$value"' 'GATEWAY_ALLOWED_HOSTS=gateway.example.com' > "$tmp/operator.env"
"${gateway[@]}" install --dir "$dir" --upstream https://core.example.com --origins https://site.example.com --operator-env "$tmp/operator.env" --render-only > "$tmp/output"
grep -Fq 'TXGATEWAY_IMAGE=ghcr.io/anrcm0/txboard-gateway:latest' "$dir/.env"
grep -Fq 'TXGATEWAY_BIND=127.0.0.1' "$dir/.env"
grep -q "GATEWAY_HPKE_MODE: disabled" "$dir/compose.yaml"
grep -q "GATEWAY_ORDER_WRITE_ENABLED: 'false'" "$dir/compose.yaml"
for file in .env gateway.env compose.yaml diagnostic.log; do [[ "$(stat -c %a "$dir/$file")" == 600 ]]; done
! grep -q 'fixture-secret' "$tmp/output"
! grep -q '"pull"\|"up"' "$GW_TEST_TRACE"
cp "$dir/gateway.env" "$tmp/env-original"
"${gateway[@]}" start --dir "$dir"
"${gateway[@]}" status --dir "$dir" | grep -q fixture-container
"${gateway[@]}" logs --dir "$dir" | grep -q synthetic
"${gateway[@]}" stop --dir "$dir"
"${gateway[@]}" restart --dir "$dir"
"${gateway[@]}" upgrade --dir "$dir" --tag dev
grep -q 'TXGATEWAY_IMAGE_REF=ghcr.io/anrcm0/txboard-gateway:dev' "$dir/.env"
cmp "$tmp/env-original" "$dir/gateway.env"
if GW_TEST_PULL_FAIL=1 "${gateway[@]}" upgrade --dir "$dir" --tag newer > "$tmp/output" 2>&1; then exit 1; fi
grep -q 'TXGATEWAY_IMAGE=ghcr.io/anrcm0/txboard-gateway:dev' "$dir/.env"
[[ ! -e "$dir/.gateway-update" ]]
if "${gateway[@]}" upgrade --dir "$dir" --tag bad > "$tmp/output" 2>&1; then exit 1; fi
grep -q "TXGATEWAY_IMAGE=sha256:$(printf '1%.0s' {1..64})" "$dir/.env"
grep -q 'previous image restored' "$tmp/output"
[[ ! -e "$dir/.gateway-update" ]]

# A failed rollback keeps the marker, blocks start/remove, and can be recovered.
if GW_TEST_ALWAYS_UNHEALTHY=1 "${gateway[@]}" upgrade --dir "$dir" --tag bad > "$tmp/output" 2>&1; then exit 1; fi
[[ -d "$dir/.gateway-update" ]]
if "${gateway[@]}" start --dir "$dir" > "$tmp/output" 2>&1; then exit 1; fi
if "${gateway[@]}" remove --dir "$dir" --yes > "$tmp/output" 2>&1; then exit 1; fi
"${gateway[@]}" recover --dir "$dir"
[[ ! -e "$dir/.gateway-update" ]]

# Ownership and serialization reject without changing saved configuration.
cp "$dir/.env" "$tmp/metadata-original"
if GW_TEST_FOREIGN=1 "${gateway[@]}" upgrade --dir "$dir" --tag dev > "$tmp/output" 2>&1; then exit 1; fi
cmp "$tmp/metadata-original" "$dir/.env"
exec 9> "$dir/.gateway.lock"; flock -n 9
if "${gateway[@]}" stop --dir "$dir" > "$tmp/output" 2>&1; then exit 1; fi
flock -u 9; exec 9>&-
if "${gateway[@]}" remove --dir "$dir" > "$tmp/output" 2>&1; then exit 1; fi
"${gateway[@]}" remove --dir "$dir" --yes
[[ -f "$dir/gateway.env" && -f "$dir/.env" && -f "$dir/gateway.sh" ]]

# Preflight errors do not render files or echo supplied private data.
for url in http://public.example.com https://user:secret@example.com https://core.example.com/path 'https://core.example.com?secret'; do
  if "${gateway[@]}" install --dir "$tmp/reject" --upstream "$url" --origins https://site.example.com > "$tmp/output" 2>&1; then exit 1; fi
  [[ ! -e "$tmp/reject" ]]
done
if "${gateway[@]}" install --dir "$tmp/reject" --upstream http://8.8.8.8 --allow-private-http --origins https://site.example.com > "$tmp/output" 2>&1; then exit 1; fi
printf '%s\n' 'GATEWAY_HPKE_KEY_FILE=fixture-secret' > "$tmp/bad-operator.env"
if "${gateway[@]}" install --dir "$tmp/reject" --upstream https://core.example.com --origins https://site.example.com --operator-env "$tmp/bad-operator.env" > "$tmp/output" 2>&1; then exit 1; fi
! grep -q fixture-secret "$tmp/output"
rm -f -- "$GW_TEST_STATE"
"${gateway[@]}" install --dir "$tmp/private" --upstream http://core:80 --allow-private-http --origins https://site.example.com --render-only
if "${gateway[@]}" install --dir "$dir" --upstream https://core.example.com --origins https://site.example.com > "$tmp/output" 2>&1; then exit 1; fi
echo 'Gateway synthetic install/lifecycle/rollback/ownership/secret/default-off tests: passed'
