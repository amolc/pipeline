#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./generate_cert.sh <email> <primary-domain> [additional-domains...]

Generates a Let's Encrypt certificate using certbot `certonly`.
This script only obtains the certificate. It does not install it into nginx or apache.

Environment overrides:
  CERTBOT_MODE=standalone|webroot   Default: standalone
  WEBROOT_PATH=/var/www/html        Required when CERTBOT_MODE=webroot
EOF
}

sudo_cmd=()
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  sudo_cmd=(sudo)
fi

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

if ! command -v certbot >/dev/null 2>&1; then
  echo "Error: certbot is not installed."
  exit 1
fi

email="$1"
shift

domains=("$@")
certbot_mode="${CERTBOT_MODE:-standalone}"
webroot_path="${WEBROOT_PATH:-}"

domain_args=()
for domain in "${domains[@]}"; do
  if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "Error: invalid domain '${domain}'."
    exit 1
  fi
  domain_args+=("-d" "$domain")
done

run_certbot() {
  if [[ "$certbot_mode" == "webroot" ]]; then
    if [[ -z "$webroot_path" ]]; then
      echo "Error: WEBROOT_PATH is required when CERTBOT_MODE=webroot."
      exit 1
    fi

    "${sudo_cmd[@]}" certbot certonly \
      --non-interactive \
      --agree-tos \
      --email "$email" \
      --webroot \
      -w "$webroot_path" \
      "${domain_args[@]}"
    return
  fi

  if [[ "$certbot_mode" != "standalone" ]]; then
    echo "Error: CERTBOT_MODE must be 'standalone' or 'webroot'."
    exit 1
  fi

  local nginx_was_active=0
  if command -v systemctl >/dev/null 2>&1; then
    if "${sudo_cmd[@]}" systemctl is-active --quiet nginx; then
      nginx_was_active=1
      echo "Stopping nginx so certbot standalone can bind to port 80..."
      "${sudo_cmd[@]}" systemctl stop nginx
    fi
  fi

  restore_nginx() {
    if [[ "$nginx_was_active" -eq 1 ]]; then
      echo "Starting nginx..."
      "${sudo_cmd[@]}" systemctl start nginx
    fi
  }

  trap restore_nginx RETURN

  "${sudo_cmd[@]}" certbot certonly \
    --non-interactive \
    --agree-tos \
    --email "$email" \
    --standalone \
    "${domain_args[@]}"
}

if run_certbot; then
  cat <<EOF
Certificate generation completed.

Primary domain: ${domains[0]}
Certificate path: /etc/letsencrypt/live/${domains[0]}
Mode: ${certbot_mode}
EOF
fi
