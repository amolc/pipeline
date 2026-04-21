#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./generate_nginx.sh <react|django>

Prompts for:
  - domain names (space-separated)
  - root path
  - certificate directory

Writes:
  - nginx/<primary-domain>.conf
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

app_type="$1"
case "$app_type" in
  react|django)
    ;;
  *)
    echo "Error: argument must be 'react' or 'django'."
    exit 1
    ;;
esac

template_file="${app_type}.conf"
if [[ ! -f "$template_file" ]]; then
  echo "Error: template file '$template_file' was not found."
  exit 1
fi

prompt() {
  local label="$1"
  local default_value="${2:-}"
  local value

  if [[ -n "$default_value" ]]; then
    read -r -p "${label} [${default_value}]: " value
    printf '%s\n' "${value:-$default_value}"
    return
  fi

  read -r -p "${label}: " value
  printf '%s\n' "$value"
}

domains_input="$(prompt "Enter domain names (space-separated)")"
if [[ -z "$domains_input" ]]; then
  echo "Error: at least one domain is required."
  exit 1
fi

read -r -a domains <<<"$domains_input"
primary_domain="${domains[0]}"

for domain in "${domains[@]}"; do
  if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "Error: invalid domain '$domain'."
    exit 1
  fi
done

server_names="${domains[*]}"

default_root="/var/www/${primary_domain}"
if [[ "$app_type" == "react" ]]; then
  default_root="/var/www/${primary_domain}/dist"
fi

root_path="$(prompt "Enter root path" "$default_root")"
if [[ -z "$root_path" ]]; then
  echo "Error: root path is required."
  exit 1
fi

default_cert_dir="/etc/letsencrypt/live/${primary_domain}"
cert_dir="$(prompt "Enter certificate directory" "$default_cert_dir")"
if [[ -z "$cert_dir" ]]; then
  echo "Error: certificate directory is required."
  exit 1
fi

safe_name="$(printf '%s' "$primary_domain" | tr -c 'A-Za-z0-9.-' '-')"
output_dir="nginx"
output_file="${output_dir}/${primary_domain}.conf"

mkdir -p "$output_dir"

python3 - "$template_file" "$output_file" "$server_names" "$root_path" "$cert_dir" "$safe_name" <<'PY'
from pathlib import Path
import re
import sys

template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
server_names = sys.argv[3]
root_path = sys.argv[4]
cert_dir = sys.argv[5].rstrip("/")
safe_name = sys.argv[6]

content = template_path.read_text()

content = re.sub(r'(^\s*server_name\s+).+?(\s*;\s*(?:#.*)?$)', rf'\1{server_names}\2', content, flags=re.MULTILINE)
content = re.sub(r'(^\s*root\s+).+?(\s*;\s*$)', rf'\1{root_path}\2', content, flags=re.MULTILINE)
content = re.sub(r'(^\s*ssl_certificate\s+).+?(\s*;\s*(?:#.*)?$)', rf'\1{cert_dir}/fullchain.pem\2', content, flags=re.MULTILINE)
content = re.sub(r'(^\s*ssl_certificate_key\s+).+?(\s*;\s*(?:#.*)?$)', rf'\1{cert_dir}/privkey.pem\2', content, flags=re.MULTILINE)
content = re.sub(r'(^\s*access_log\s+/var/log/nginx/).+?(\.access\.log\s*;\s*$)', rf'\1{safe_name}\2', content, flags=re.MULTILINE)
content = re.sub(r'(^\s*error_log\s+/var/log/nginx/).+?(\.error\.log\s+error\s*;\s*$)', rf'\1{safe_name}\2', content, flags=re.MULTILINE)

upstream_match = re.search(r'(^upstream\s+)([^\s{]+)(\s*\{)', content, flags=re.MULTILINE)
if upstream_match:
    upstream_name = safe_name.replace(".", "-")
    content = re.sub(r'(^upstream\s+)[^\s{]+(\s*\{)', rf'\1{upstream_name}\2', content, count=1, flags=re.MULTILINE)
    content = re.sub(r'(\bproxy_pass\s+http://)[^;]+(;)', rf'\1{upstream_name}\2', content, count=1)

output_path.write_text(content)
PY

echo "Generated ${output_file}"
