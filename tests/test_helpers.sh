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

if command -v openssl >/dev/null 2>&1; then
    CERT_TMP="$(mktemp -d)"
    trap 'rm -rf "${CERT_TMP}"' EXIT
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
fi

printf 'All helper tests passed.\n'
