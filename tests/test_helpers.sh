#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../nginx-easy-deploy.sh
source "${ROOT_DIR}/nginx-easy-deploy.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_ok() {
    "$@" || fail "expected success: $*"
}

assert_fail() {
    if "$@"; then
        fail "expected failure: $*"
    fi
}

assert_equal() {
    [[ "$1" == "$2" ]] || fail "expected '$1' to equal '$2'"
}

assert_ok validate_domain example.com
assert_ok validate_domain app.example.com
assert_ok validate_domain xn--fiqs8s.cn
assert_fail validate_domain localhost
assert_fail validate_domain '-bad.example.com'
assert_fail validate_domain 'bad..example.com'

assert_equal "$(normalize_upstream 3000)" 'http://127.0.0.1:3000'
assert_equal "$(normalize_upstream 127.0.0.1:8080)" 'http://127.0.0.1:8080'
assert_equal "$(normalize_upstream https://backend.example.com/api)" 'https://backend.example.com/api'
assert_fail normalize_upstream 0
assert_fail normalize_upstream 65536
assert_fail normalize_upstream 'http://127.0.0.1:3000;return'

assert_ok validate_static_root /var/www/example.com
assert_fail validate_static_root var/www/example.com
assert_fail validate_static_root '/var/www/bad path'
assert_fail validate_static_root /var/www/../etc

assert_ok safe_restore_path /etc/nginx
assert_ok safe_restore_path /etc/letsencrypt
assert_fail safe_restore_path /
assert_fail safe_restore_path /etc
assert_fail safe_restore_path /etc/nginx/../../root

UI_LANG="en"
assert_equal "$(ui_text 中文 English)" "English"
UI_LANG="zh"
assert_equal "$(ui_text 中文 English)" "中文"
UI_LANG="English"
normalize_ui_language
assert_equal "${UI_LANG}" "en"
UI_LANG="zh_CN"
normalize_ui_language
assert_equal "${UI_LANG}" "zh"
UI_LANG=""
select_ui_language <<< "2" >/dev/null
assert_equal "${UI_LANG}" "en"
UI_LANG="zh"

RANGE_TMP="$(mktemp -d)"
trap 'rm -rf "${RANGE_TMP}"' EXIT
cat > "${RANGE_TMP}/ips-v4" <<'EOF'
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
EOF
cat > "${RANGE_TMP}/ips-v6" <<'EOF'
2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
EOF
assert_ok validate_cloudflare_ranges "${RANGE_TMP}/ips-v4" 4
assert_ok validate_cloudflare_ranges "${RANGE_TMP}/ips-v6" 6
write_cloudflare_realip_config "${RANGE_TMP}/realip.conf" \
    "${RANGE_TMP}/ips-v4" "${RANGE_TMP}/ips-v6"
grep -Fxq 'real_ip_header CF-Connecting-IP;' "${RANGE_TMP}/realip.conf" \
    || fail "missing Cloudflare real IP header"
grep -Fxq 'set_real_ip_from 173.245.48.0/20;' "${RANGE_TMP}/realip.conf" \
    || fail "missing Cloudflare IPv4 range"
grep -Fxq 'set_real_ip_from 2606:4700::/32;' "${RANGE_TMP}/realip.conf" \
    || fail "missing Cloudflare IPv6 range"
printf 'not-a-cidr\n' >> "${RANGE_TMP}/ips-v4"
assert_fail validate_cloudflare_ranges "${RANGE_TMP}/ips-v4" 4

if command -v openssl >/dev/null 2>&1; then
    CERT_TMP="$(mktemp -d)"
    MSYS2_ARG_CONV_EXCL='/CN=' openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj '/CN=example.com' \
        -keyout "${CERT_TMP}/key.pem" -out "${CERT_TMP}/cert.pem" \
        >/dev/null 2>&1
    assert_ok openssl x509 -in "${CERT_TMP}/cert.pem" -noout -checkhost example.com
    cert_hash="$(openssl x509 -in "${CERT_TMP}/cert.pem" -pubkey -noout \
        | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    key_hash="$(openssl pkey -in "${CERT_TMP}/key.pem" -passin pass: -pubout -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}')"
    assert_equal "${cert_hash}" "${key_hash}"
    days_left="$(certificate_days_left "${CERT_TMP}/cert.pem")"
    [[ "${days_left}" =~ ^[01]$ ]] || fail "unexpected certificate days left: ${days_left}"
    rm -rf "${CERT_TMP}"
fi

printf 'All helper tests passed.\n'
