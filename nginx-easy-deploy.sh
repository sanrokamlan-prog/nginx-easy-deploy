#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION="0.1.0"
PROGRAM="${0##*/}"
WORK_DIR=""
CHANGES_STARTED=0
ROLLBACK_ROOT=""
ROLLBACK_ARCHIVE=""
RESTORE_PATHS_FILE=""
PRE_EXISTING_FILE=""

log()  { printf '[ngx-migrate] %s\n' "$*"; }
warn() { printf '[ngx-migrate] WARNING: %s\n' "$*" >&2; }
die()  { printf '[ngx-migrate] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
nginx-easy-deploy v${VERSION} - 原生 Nginx 一键部署与迁移

直接打开中文菜单：
  sudo bash ${PROGRAM}

常用命令：
  sudo bash ${PROGRAM} install
  sudo bash ${PROGRAM} proxy example.com 127.0.0.1:3000 --email you@example.com
  sudo bash ${PROGRAM} static example.com /var/www/example.com --email you@example.com
  sudo bash ${PROGRAM} cert example.com fullchain.pem privkey.pem
  sudo bash ${PROGRAM} cert example.com cert.pem privkey.pem --chain chain.pem
  sudo bash ${PROGRAM} sites
  sudo bash ${PROGRAM} status
  sudo bash ${PROGRAM} renew
  sudo bash ${PROGRAM} delete example.com

旧服务器导出：
  sudo bash ${PROGRAM} export
  sudo bash ${PROGRAM} export -o /root/nginx-backup.tar.gz
  sudo bash ${PROGRAM} export --encrypt
  sudo bash ${PROGRAM} export --with-webroot
  sudo bash ${PROGRAM} export --include /path/to/extra/files

新服务器恢复：
  sudo bash ${PROGRAM} restore nginx-backup.tar.gz
  sudo bash ${PROGRAM} restore nginx-backup.tar.gz.enc

站点选项：
  --email ADDRESS       申请 Let's Encrypt 证书使用的邮箱
  --no-ssl              只部署 HTTP
  --force               覆盖脚本已管理的同名站点

迁移选项：
  -o, --output FILE     指定导出文件
  --encrypt             使用 OpenSSL 密码加密迁移包
  --with-webroot        同时打包 Nginx root/alias 指向的静态站点目录
  --include PATH        额外打包文件或目录，可重复使用
  --force               导出无效配置，或允许跨发行版恢复
  -h, --help            显示帮助

支持 Debian、Ubuntu、CentOS、RHEL、Rocky Linux、AlmaLinux。
仅管理原生 Nginx，不支持 Docker、Nginx Proxy Manager、Kubernetes；
OpenResty 配置可以导出，但新机需要先自行安装兼容版本。
EOF
}

cleanup() {
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        rm -rf -- "${WORK_DIR}"
    fi
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this command as root (use sudo)."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

safe_restore_path() {
    local path="$1"
    [[ "${path}" == /* ]] || return 1
    [[ "${path}" != *$'\n'* && "${path}" != *$'\t'* ]] || return 1
    case "/${path#/}/" in
        */../*) return 1 ;;
    esac
    case "${path%/}" in
        ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var)
            return 1
            ;;
    esac
    return 0
}

normalize_path() {
    local path="$1"
    while [[ "${path}" == *'//'* ]]; do
        path="${path//\/\//\/}"
    done
    [[ "${path}" == "/" ]] || path="${path%/}"
    printf '%s\n' "${path}"
}

metadata_value() {
    local file="$1" key="$2"
    awk -F '\t' -v wanted="${key}" '$1 == wanted {sub(/^[^\t]*\t/, ""); print; exit}' "${file}"
}

write_os_metadata() {
    local destination="$1"
    local os_id="unknown" os_version="unknown"
    if [[ -r /etc/os-release ]]; then
        os_id="$(sed -n 's/^ID=//p' /etc/os-release | head -n 1 | tr -d '\"')"
        os_version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -n 1 | tr -d '\"')"
        os_id="${os_id:-unknown}"
        os_version="${os_version:-unknown}"
    fi
    printf 'os_id\t%s\n' "${os_id}" >> "${destination}"
    printf 'os_version\t%s\n' "${os_version}" >> "${destination}"
}

discover_nginx() {
    NGINX_BIN="$(command -v nginx || true)"
    [[ -n "${NGINX_BIN}" ]] || die "Nginx was not found. This script exports native Nginx installations only."

    NGINX_VERSION_OUTPUT="$(${NGINX_BIN} -V 2>&1)"
    NGINX_PREFIX="$(printf '%s\n' "${NGINX_VERSION_OUTPUT}" | sed -n 's/.*--prefix=\([^ ]*\).*/\1/p' | tail -n 1)"
    NGINX_CONF="$(printf '%s\n' "${NGINX_VERSION_OUTPUT}" | sed -n 's/.*--conf-path=\([^ ]*\).*/\1/p' | tail -n 1)"
    NGINX_PREFIX="${NGINX_PREFIX:-/usr/share/nginx}"
    NGINX_CONF="${NGINX_CONF:-/etc/nginx/nginx.conf}"
    if [[ "${NGINX_CONF}" != /* ]]; then
        NGINX_CONF="${NGINX_PREFIX%/}/${NGINX_CONF}"
    fi
    [[ -f "${NGINX_CONF}" ]] || die "Nginx main config not found: ${NGINX_CONF}"
    NGINX_CONFIG_ROOT="$(dirname "${NGINX_CONF}")"
}

export_bundle() {
    local output="" encrypt=0 with_webroot=0 force=0
    local -a extra_paths=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                [[ $# -ge 2 ]] || die "$1 requires a file path."
                output="$2"
                shift 2
                ;;
            --encrypt)
                encrypt=1
                shift
                ;;
            --with-webroot)
                with_webroot=1
                shift
                ;;
            --include)
                [[ $# -ge 2 ]] || die "$1 requires a path."
                extra_paths+=("$2")
                shift 2
                ;;
            --force)
                force=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown export option: $1"
                ;;
        esac
    done

    require_root
    require_command tar
    require_command sha256sum
    require_command awk
    require_command sed
    discover_nginx

    if ! "${NGINX_BIN}" -t; then
        [[ "${force}" -eq 1 ]] || die "Nginx config is invalid. Fix it first, or use --force to export anyway."
        warn "Exporting even though nginx -t failed."
    fi

    WORK_DIR="$(mktemp -d /tmp/ngx-migrate-export.XXXXXX)"
    trap cleanup EXIT
    mkdir -p "${WORK_DIR}/stage/manifest" "${WORK_DIR}/stage/rootfs"
    local stage="${WORK_DIR}/stage"
    local nginx_dump="${stage}/manifest/nginx-T.txt"
    "${NGINX_BIN}" -T > "${nginx_dump}" 2>&1 || true
    printf '%s\n' "${NGINX_VERSION_OUTPUT}" > "${stage}/manifest/nginx-V.txt"

    local metadata="${stage}/manifest/metadata.tsv"
    printf 'format_version\t1\n' > "${metadata}"
    printf 'script_version\t%s\n' "${VERSION}" >> "${metadata}"
    printf 'created_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${metadata}"
    printf 'hostname\t%s\n' "$(hostname 2>/dev/null || printf unknown)" >> "${metadata}"
    printf 'nginx_bin\t%s\n' "${NGINX_BIN}" >> "${metadata}"
    printf 'nginx_conf\t%s\n' "${NGINX_CONF}" >> "${metadata}"
    printf 'nginx_config_root\t%s\n' "${NGINX_CONFIG_ROOT}" >> "${metadata}"
    if printf '%s\n' "${NGINX_VERSION_OUTPUT}" | grep -qi openresty; then
        printf 'nginx_flavor\topenresty\n' >> "${metadata}"
    else
        printf 'nginx_flavor\tnginx\n' >> "${metadata}"
    fi
    write_os_metadata "${metadata}"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-enabled nginx > "${stage}/manifest/nginx-enabled.txt" 2>/dev/null || true
        systemctl is-active nginx > "${stage}/manifest/nginx-active.txt" 2>/dev/null || true
    fi
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -F '.acme.sh' > "${stage}/manifest/acme-root-crontab.txt" || true
    fi
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null \
            | awk '$1 ~ /^(nginx|nginx-|libnginx-mod-|certbot|python3-certbot)/' \
            > "${stage}/manifest/packages.tsv" || true
    elif command -v rpm >/dev/null 2>&1; then
        rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' 2>/dev/null \
            | awk '$1 ~ /^(nginx|nginx-|openresty|certbot|python3-certbot)/' \
            > "${stage}/manifest/packages.tsv" || true
    fi

    local -a selected_paths=()
    add_export_path() {
        local path
        path="$(normalize_path "$1")"
        [[ -e "${path}" || -L "${path}" ]] || return 0
        safe_restore_path "${path}" || die "Refusing unsafe or overly broad export path: ${path}"
        local existing
        for existing in "${selected_paths[@]}"; do
            if [[ "${path}" == "${existing}" || "${path}" == "${existing}/"* ]]; then
                return 0
            fi
        done
        selected_paths+=("${path}")
    }

    add_export_path "${NGINX_CONFIG_ROOT}"
    [[ -d /etc/letsencrypt ]] && add_export_path /etc/letsencrypt
    [[ -d /var/lib/letsencrypt ]] && add_export_path /var/lib/letsencrypt
    [[ -e /etc/systemd/system/nginx.service ]] && add_export_path /etc/systemd/system/nginx.service
    [[ -d /etc/systemd/system/nginx.service.d ]] && add_export_path /etc/systemd/system/nginx.service.d
    [[ -e /etc/logrotate.d/nginx ]] && add_export_path /etc/logrotate.d/nginx

    local acme_dir
    for acme_dir in /root/.acme.sh /home/*/.acme.sh; do
        [[ -d "${acme_dir}" ]] && add_export_path "${acme_dir}"
    done

    # nginx -T labels every loaded configuration file with an absolute path.
    while IFS= read -r path; do
        [[ -n "${path}" ]] && add_export_path "${path}"
    done < <(sed -n 's/^# configuration file \(\/.*\):$/\1/p' "${nginx_dump}")

    # Capture TLS material and other common files referenced by absolute path.
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        add_export_path "${path}"
        if [[ -L "${path}" ]]; then
            local resolved
            resolved="$(readlink -f -- "${path}" 2>/dev/null || true)"
            [[ -n "${resolved}" ]] && add_export_path "${resolved}"
        fi
    done < <(
        awk '
            $1 ~ /^(ssl_certificate|ssl_certificate_key|ssl_trusted_certificate|ssl_client_certificate|ssl_crl|ssl_dhparam|ssl_password_file|ssl_session_ticket_key|proxy_ssl_certificate|proxy_ssl_certificate_key|proxy_ssl_trusted_certificate|proxy_ssl_crl|proxy_ssl_password_file|auth_basic_user_file)$/ {
                value=$2
                sub(/;$/, "", value)
                gsub(/^\047|\047$/, "", value)
                gsub(/^\042|\042$/, "", value)
                if (value ~ /^\// && value !~ /\$/) print value
            }
        ' "${nginx_dump}" | sort -u
    )

    if [[ "${with_webroot}" -eq 1 ]]; then
        while IFS= read -r path; do
            [[ -n "${path}" ]] && add_export_path "${path}"
        done < <(
            awk '
                $1 ~ /^(root|alias)$/ {
                    value=$2
                    sub(/;$/, "", value)
                    gsub(/^\047|\047$/, "", value)
                    gsub(/^\042|\042$/, "", value)
                    if (value ~ /^\// && value !~ /\$/) print value
                }
            ' "${nginx_dump}" | sort -u
        )
    fi

    local path
    for path in "${extra_paths[@]}"; do
        [[ "${path}" == /* ]] || path="$(pwd)/${path}"
        add_export_path "${path}"
    done

    local paths_file="${stage}/manifest/paths.txt"
    : > "${paths_file}"
    for path in "${selected_paths[@]}"; do
        printf '%s\n' "${path}" >> "${paths_file}"
        log "Collecting ${path}"
        cp -a --parents -- "${path}" "${stage}/rootfs"
    done

    (
        cd "${stage}"
        find manifest rootfs -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
    )

    local host_slug timestamp plain_archive
    host_slug="$(hostname 2>/dev/null | tr -cs 'A-Za-z0-9._-' '_' || printf host)"
    timestamp="$(date +%Y%m%d-%H%M%S)"
    output="${output:-$(pwd)/ngx-migrate-${host_slug}-${timestamp}.tar.gz}"
    mkdir -p "$(dirname "${output}")"

    if [[ "${encrypt}" -eq 1 ]]; then
        require_command openssl
        [[ "${output}" == *.enc ]] || output="${output}.enc"
        plain_archive="${WORK_DIR}/payload.tar.gz"
        tar --numeric-owner -czf "${plain_archive}" -C "${stage}" manifest rootfs SHA256SUMS
        log "Enter an encryption passphrase when OpenSSL prompts."
        openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 \
            -in "${plain_archive}" -out "${output}"
    else
        tar --numeric-owner -czf "${output}" -C "${stage}" manifest rootfs SHA256SUMS
        warn "The archive contains TLS private keys. Transfer it securely or use --encrypt."
    fi

    chmod 600 "${output}"
    log "Export complete: ${output}"
    log "Upload this archive and ${PROGRAM} to the new server, then run:"
    log "  sudo bash ${PROGRAM} restore $(basename "${output}")"
    cleanup
    WORK_DIR=""
}

install_nginx() {
    local flavor="$1"
    if command -v nginx >/dev/null 2>&1; then
        return 0
    fi
    if [[ "${flavor}" == "openresty" ]]; then
        die "This backup uses OpenResty. Install a compatible OpenResty build first, then rerun restore."
    fi

    log "Nginx 未安装，正在使用系统软件源安装。"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nginx
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nginx
    elif command -v apk >/dev/null 2>&1; then
        apk add nginx
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install nginx
    else
        die "No supported package manager found. Install Nginx and rerun restore."
    fi
}

install_certbot() {
    if command -v certbot >/dev/null 2>&1 \
        && certbot plugins 2>/dev/null | grep -q 'nginx'; then
        return 0
    fi

    log "正在安装 Certbot 和 Nginx 插件。"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx
    elif command -v dnf >/dev/null 2>&1; then
        if ! dnf install -y certbot python3-certbot-nginx; then
            dnf install -y epel-release
            dnf install -y certbot python3-certbot-nginx
        fi
    elif command -v yum >/dev/null 2>&1; then
        if ! yum install -y certbot python3-certbot-nginx; then
            yum install -y epel-release
            yum install -y certbot python3-certbot-nginx
        fi
    elif command -v apk >/dev/null 2>&1; then
        apk add certbot certbot-nginx
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install certbot python3-certbot-nginx
    else
        return 1
    fi

    command -v certbot >/dev/null 2>&1 \
        && certbot plugins 2>/dev/null | grep -q 'nginx'
}

open_firewall_ports() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow 'Nginx Full' >/dev/null 2>&1 \
            || { ufw allow 80/tcp && ufw allow 443/tcp; }
        log "已在 UFW 放行 80/443 端口。"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 \
        && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-service=http >/dev/null
        firewall-cmd --permanent --add-service=https >/dev/null
        firewall-cmd --reload >/dev/null
        log "已在 firewalld 放行 80/443 端口。"
    fi
}

start_nginx() {
    nginx -t
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable nginx >/dev/null
        systemctl restart nginx
        systemctl is-active --quiet nginx
    else
        nginx -s reload 2>/dev/null || nginx
    fi
}

reload_nginx() {
    nginx -t
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx; then
            systemctl reload nginx
        else
            systemctl enable --now nginx
        fi
    else
        nginx -s reload 2>/dev/null || nginx
    fi
}

ensure_managed_config_dir() {
    discover_nginx
    MANAGED_CONFIG_DIR="${NGINX_CONFIG_ROOT}/conf.d"
    local config_dump
    config_dump="$(nginx -T 2>&1 || true)"
    if ! printf '%s\n' "${config_dump}" \
        | grep -Eq '^[[:space:]]*include[[:space:]]+[^;]*conf\.d/\*\.conf;'; then
        die "当前 nginx.conf 未加载 conf.d/*.conf，脚本不会冒险自动改写非标准主配置。"
    fi
    mkdir -p "${MANAGED_CONFIG_DIR}"
}

install_stack() {
    require_root
    install_nginx nginx
    if ! install_certbot; then
        warn "Certbot 安装失败，Nginx 已可使用，但自动 HTTPS 暂不可用。"
    fi
    ensure_managed_config_dir
    open_firewall_ports
    start_nginx
    log "原生 Nginx 安装完成。"
    nginx -v 2>&1
}

validate_domain() {
    local domain="$1" label
    local -a labels=()
    [[ ${#domain} -le 253 && "${domain}" == *.* ]] || return 1
    [[ "${domain}" != *'..'* && "${domain}" != .* && "${domain}" != *. ]] || return 1
    local old_ifs="${IFS}"
    IFS='.' read -r -a labels <<< "${domain}"
    IFS="${old_ifs}"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
    return 0
}

validate_email() {
    [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

safe_nginx_value() {
    local value="$1"
    [[ ! "${value}" =~ [[:space:]] ]] || return 1
    [[ "${value}" != *";"* ]] || return 1
    [[ "${value}" != *"{"* && "${value}" != *"}"* ]] || return 1
    [[ "${value}" != *'"'* && "${value}" != *"'"* ]] || return 1
    [[ "${value}" != *\\* && "${value}" != *'$'* ]] || return 1
    return 0
}

normalize_upstream() {
    local upstream="$1"
    if [[ "${upstream}" =~ ^[0-9]{1,5}$ ]]; then
        local numeric_port=$((10#${upstream}))
        (( numeric_port >= 1 && numeric_port <= 65535 )) || return 1
        printf 'http://127.0.0.1:%s\n' "${upstream}"
        return 0
    fi
    if [[ "${upstream}" == http://* || "${upstream}" == https://* ]]; then
        safe_nginx_value "${upstream}" || return 1
        [[ "${upstream}" =~ ^https?://(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?(/[^[:space:]]*)?$ ]] \
            || return 1
        printf '%s\n' "${upstream%/}"
        return 0
    fi
    if [[ "${upstream}" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]]; then
        local port="${upstream##*:}"
        local numeric_port=$((10#${port}))
        (( numeric_port >= 1 && numeric_port <= 65535 )) || return 1
        printf 'http://%s\n' "${upstream}"
        return 0
    fi
    return 1
}

validate_static_root() {
    local root="$1"
    [[ "${root}" == /* ]] || return 1
    safe_nginx_value "${root}" || return 1
    case "/${root#/}/" in
        */../*) return 1 ;;
    esac
    return 0
}

site_config_path() {
    printf '%s/ngx-easy-%s.conf\n' "${MANAGED_CONFIG_DIR}" "$1"
}

ensure_websocket_map() {
    local dump map_file temp
    dump="$(nginx -T 2>&1 || true)"
    if printf '%s\n' "${dump}" | grep -Eq 'map[[:space:]]+\$http_upgrade[[:space:]]+\$connection_upgrade'; then
        return 0
    fi

    map_file="${MANAGED_CONFIG_DIR}/00-ngx-easy-websocket.conf"
    temp="$(mktemp "${MANAGED_CONFIG_DIR}/.ngx-easy-map.XXXXXX")"
    cat > "${temp}" <<'EOF'
# Managed by nginx-easy-deploy.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
    chmod 644 "${temp}"
    mv -f "${temp}" "${map_file}"
}

enable_https_domain() {
    local domain="${1:-}" email="${2:-}"
    require_root
    validate_domain "${domain}" || die "域名格式不正确: ${domain}"
    validate_email "${email}" || die "邮箱格式不正确: ${email}"
    command -v nginx >/dev/null 2>&1 || install_nginx nginx
    ensure_managed_config_dir
    open_firewall_ports
    [[ -f "$(site_config_path "${domain}")" ]] \
        || die "没有找到脚本管理的站点: ${domain}"
    install_certbot || die "Certbot 或其 Nginx 插件安装失败。"

    log "正在为 ${domain} 申请并配置 Let's Encrypt 证书。"
    certbot --nginx --non-interactive --agree-tos --redirect \
        --email "${email}" --domains "${domain}"
    reload_nginx
    log "HTTPS 已启用: https://${domain}"
}

install_custom_certificate() {
    [[ $# -ge 3 ]] || die "用法: ${PROGRAM} cert DOMAIN CERT_FILE KEY_FILE [--chain CHAIN_FILE] [--force]"
    local domain="$1" cert_file="$2" key_file="$3"
    shift 3
    local chain_file="" force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --chain)
                [[ $# -ge 2 ]] || die "--chain 需要证书链文件。"
                chain_file="$2"
                shift 2
                ;;
            --force)
                force=1
                shift
                ;;
            *)
                die "未知证书选项: $1"
                ;;
        esac
    done

    require_root
    require_command openssl
    require_command sha256sum
    domain="$(printf '%s' "${domain}" | tr 'A-Z' 'a-z')"
    validate_domain "${domain}" || die "域名格式不正确: ${domain}"
    [[ -f "${cert_file}" && -r "${cert_file}" ]] || die "证书文件不可读: ${cert_file}"
    [[ -f "${key_file}" && -r "${key_file}" ]] || die "私钥文件不可读: ${key_file}"
    if [[ -n "${chain_file}" ]]; then
        [[ -f "${chain_file}" && -r "${chain_file}" ]] || die "证书链文件不可读: ${chain_file}"
    fi

    openssl x509 -in "${cert_file}" -noout >/dev/null \
        || die "无法解析证书文件。"
    openssl pkey -in "${key_file}" -passin pass: -noout >/dev/null 2>&1 \
        || die "无法解析私钥，或私钥带有密码。Nginx 自动启动需要无密码私钥。"

    local cert_hash key_hash
    cert_hash="$(openssl x509 -in "${cert_file}" -pubkey -noout \
        | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    key_hash="$(openssl pkey -in "${key_file}" -passin pass: -pubout -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}')"
    [[ -n "${cert_hash}" && "${cert_hash}" == "${key_hash}" ]] \
        || die "证书与私钥不匹配。"

    if ! openssl x509 -in "${cert_file}" -checkend 0 -noout >/dev/null; then
        [[ "${force}" -eq 1 ]] || die "证书已经过期；确认继续时添加 --force。"
        warn "正在安装已过期证书，因为使用了 --force。"
    fi
    if openssl x509 -help 2>&1 | grep -q -- '-checkhost'; then
        if ! openssl x509 -in "${cert_file}" -checkhost "${domain}" -noout >/dev/null 2>&1; then
            [[ "${force}" -eq 1 ]] || die "证书不匹配域名 ${domain}；确认继续时添加 --force。"
            warn "证书域名不匹配，因为使用了 --force 仍将继续。"
        fi
    else
        warn "当前 OpenSSL 版本过旧，无法自动检查证书域名。"
    fi

    command -v nginx >/dev/null 2>&1 || install_nginx nginx
    ensure_managed_config_dir
    open_firewall_ports
    local config
    config="$(site_config_path "${domain}")"
    [[ -f "${config}" ]] || die "没有找到脚本管理的站点: ${domain}"
    if grep -Fq '# managed by Certbot' "${config}"; then
        die "该站点正由 Certbot 管理。请先删除其 Certbot HTTPS 配置，或新建 --no-ssl 站点后上传自有证书。"
    fi

    local cert_dir="/etc/nginx/ssl/${domain}"
    local work cert_backup config_backup base_config new_config
    work="$(mktemp -d /tmp/ngx-easy-cert.XXXXXX)"
    cert_backup="${work}/cert-backup"
    config_backup="${work}/site.conf"
    base_config="${work}/base.conf"
    new_config="${work}/new.conf"
    cp -a "${config}" "${config_backup}"
    if [[ -d "${cert_dir}" ]]; then
        cp -a "${cert_dir}" "${cert_backup}"
    fi

    mkdir -p "${cert_dir}"
    chmod 700 "${cert_dir}"
    if [[ -n "${chain_file}" ]]; then
        cat "${cert_file}" "${chain_file}" > "${work}/fullchain.pem"
        install -m 644 "${work}/fullchain.pem" "${cert_dir}/fullchain.pem"
    else
        install -m 644 "${cert_file}" "${cert_dir}/fullchain.pem"
    fi
    install -m 600 "${key_file}" "${cert_dir}/privkey.pem"

    awk '
        /^    # ngx-easy-custom-tls-begin$/ {skip=1; next}
        /^    # ngx-easy-custom-tls-end$/ {skip=0; next}
        !skip {print}
    ' "${config}" > "${base_config}"
    awk -v cert="${cert_dir}/fullchain.pem" -v key="${cert_dir}/privkey.pem" '
        !inserted && /^[[:space:]]*server[[:space:]]*\{/ {
            print
            print "    # ngx-easy-custom-tls-begin"
            print "    listen 443 ssl http2;"
            print "    listen [::]:443 ssl http2;"
            print "    ssl_certificate " cert ";"
            print "    ssl_certificate_key " key ";"
            print "    if ($scheme = http) { return 301 https://$host$request_uri; }"
            print "    # ngx-easy-custom-tls-end"
            inserted=1
            next
        }
        {print}
        END {if (!inserted) exit 42}
    ' "${base_config}" > "${new_config}" || {
        rm -rf "${cert_dir}"
        [[ -d "${cert_backup}" ]] && cp -a "${cert_backup}" "${cert_dir}"
        rm -rf "${work}"
        die "无法识别站点配置结构。"
    }
    install -m 644 "${new_config}" "${config}"

    if ! nginx -t; then
        cp -a "${config_backup}" "${config}"
        rm -rf "${cert_dir}"
        [[ -d "${cert_backup}" ]] && cp -a "${cert_backup}" "${cert_dir}"
        rm -rf "${work}"
        die "自有证书配置校验失败，已恢复原配置和证书。"
    fi
    reload_nginx
    rm -rf "${work}"
    log "自有证书已安装: https://${domain}"
    warn "自有证书不会由 Certbot 自动续签，到期前请重新运行 cert 命令更新。"
}

create_site() {
    local kind="$1"
    shift
    [[ $# -ge 2 ]] || die "缺少参数。请查看 ${PROGRAM} --help。"
    local domain="$1" target="$2"
    shift 2
    local email="" no_ssl=0 force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --email)
                [[ $# -ge 2 ]] || die "--email 需要邮箱地址。"
                email="$2"
                shift 2
                ;;
            --no-ssl)
                no_ssl=1
                shift
                ;;
            --force)
                force=1
                shift
                ;;
            *)
                die "未知站点选项: $1"
                ;;
        esac
    done

    require_root
    domain="$(printf '%s' "${domain}" | tr 'A-Z' 'a-z')"
    validate_domain "${domain}" || die "域名格式不正确: ${domain}"
    if [[ -n "${email}" ]]; then
        validate_email "${email}" || die "邮箱格式不正确: ${email}"
    fi

    command -v nginx >/dev/null 2>&1 || install_nginx nginx
    ensure_managed_config_dir
    open_firewall_ports

    if [[ "${kind}" == "proxy" ]]; then
        target="$(normalize_upstream "${target}")" || die "反代地址不正确: ${target}"
        ensure_websocket_map
    else
        validate_static_root "${target}" || die "静态目录必须是安全的绝对路径: ${target}"
        mkdir -p "${target}"
        chmod 755 "${target}"
    fi

    local config backup="" temp
    config="$(site_config_path "${domain}")"
    if [[ -e "${config}" && "${force}" -ne 1 ]]; then
        die "站点已存在: ${domain}。确认覆盖时添加 --force。"
    fi
    if [[ -e "${config}" ]]; then
        backup="$(mktemp /tmp/ngx-easy-site-backup.XXXXXX)"
        cp -a "${config}" "${backup}"
    fi
    temp="$(mktemp "${MANAGED_CONFIG_DIR}/.ngx-easy-site.XXXXXX")"

    if [[ "${kind}" == "proxy" ]]; then
        cat > "${temp}" <<EOF
# Managed by nginx-easy-deploy.
# ngx-easy-domain: ${domain}
# ngx-easy-kind: proxy
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    location / {
        proxy_pass ${target};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF
    else
        cat > "${temp}" <<EOF
# Managed by nginx-easy-deploy.
# ngx-easy-domain: ${domain}
# ngx-easy-kind: static
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    root ${target};
    index index.html index.htm;
    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    fi

    chmod 644 "${temp}"
    mv -f "${temp}" "${config}"
    if ! nginx -t; then
        rm -f "${config}"
        [[ -n "${backup}" ]] && mv -f "${backup}" "${config}"
        die "新配置校验失败，已恢复原配置。"
    fi
    [[ -n "${backup}" ]] && rm -f "${backup}"
    reload_nginx
    log "HTTP 站点已部署: http://${domain}"

    if [[ "${no_ssl}" -eq 0 && -n "${email}" ]]; then
        if ! enable_https_domain "${domain}" "${email}"; then
            warn "HTTPS 申请失败，但 HTTP 站点仍然可用。请检查域名解析和 80/443 端口。"
        fi
    elif [[ "${no_ssl}" -eq 0 ]]; then
        warn "未提供邮箱，本次只部署 HTTP。之后可运行: ${PROGRAM} ssl ${domain} you@example.com"
    fi
}

list_sites() {
    require_root
    command -v nginx >/dev/null 2>&1 || die "Nginx 尚未安装。"
    ensure_managed_config_dir
    local found=0 file domain kind target
    shopt -s nullglob
    local -a files=("${MANAGED_CONFIG_DIR}"/ngx-easy-*.conf)
    printf '%-32s %-10s %s\n' "DOMAIN" "TYPE" "TARGET"
    printf '%-32s %-10s %s\n' "------" "----" "------"
    for file in "${files[@]}"; do
        domain="$(sed -n 's/^# ngx-easy-domain: //p' "${file}" | head -n 1)"
        kind="$(sed -n 's/^# ngx-easy-kind: //p' "${file}" | head -n 1)"
        if [[ "${kind}" == "proxy" ]]; then
            target="$(awk '$1 == "proxy_pass" {gsub(/;$/, "", $2); print $2; exit}' "${file}")"
        else
            target="$(awk '$1 == "root" {gsub(/;$/, "", $2); print $2; exit}' "${file}")"
        fi
        printf '%-32s %-10s %s\n' "${domain:-unknown}" "${kind:-unknown}" "${target:--}"
        found=1
    done
    shopt -u nullglob
    [[ "${found}" -eq 1 ]] || log "暂无脚本管理的站点。"
}

delete_site() {
    local domain="${1:-}" delete_cert=0
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --delete-cert) delete_cert=1; shift ;;
            *) die "未知删除选项: $1" ;;
        esac
    done
    require_root
    validate_domain "${domain}" || die "域名格式不正确: ${domain}"
    ensure_managed_config_dir
    local config backup
    config="$(site_config_path "${domain}")"
    [[ -f "${config}" ]] || die "站点不存在: ${domain}"
    grep -Fq '# Managed by nginx-easy-deploy.' "${config}" \
        || die "该文件不是脚本创建的，拒绝自动删除: ${config}"
    backup="$(mktemp /tmp/ngx-easy-delete-backup.XXXXXX)"
    cp -a "${config}" "${backup}"
    rm -f "${config}"
    if ! nginx -t; then
        mv -f "${backup}" "${config}"
        die "删除后 Nginx 校验失败，已恢复站点。"
    fi
    rm -f "${backup}"
    reload_nginx
    if [[ "${delete_cert}" -eq 1 ]] && command -v certbot >/dev/null 2>&1; then
        certbot delete --non-interactive --cert-name "${domain}" || true
    fi
    if [[ "${delete_cert}" -eq 1 && -d "/etc/nginx/ssl/${domain}" ]]; then
        rm -rf -- "/etc/nginx/ssl/${domain}"
    fi
    log "站点已删除: ${domain}"
}

renew_certificates() {
    require_root
    install_certbot || die "Certbot 或其 Nginx 插件安装失败。"
    certbot renew
    command -v nginx >/dev/null 2>&1 && reload_nginx
}

show_status() {
    require_root
    if ! command -v nginx >/dev/null 2>&1; then
        log "Nginx 尚未安装。"
        return 0
    fi
    nginx -v 2>&1
    nginx -t
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx; then
            log "Nginx 服务状态: running"
        else
            warn "Nginx 服务状态: stopped"
        fi
    fi
    if command -v certbot >/dev/null 2>&1; then
        certbot certificates || true
    else
        warn "Certbot 尚未安装。"
    fi
}

remove_path_for_restore() {
    local path="$1"
    safe_restore_path "${path}" || die "Refusing to replace unsafe path: ${path}"
    if [[ -d "${path}" && ! -L "${path}" ]]; then
        rm -rf --one-file-system -- "${path}"
    else
        rm -f -- "${path}"
    fi
}

copy_staged_path() {
    local root="$1" path="$2"
    local source="${root}${path}"
    [[ -e "${source}" || -L "${source}" ]] || die "Archive is missing staged path: ${path}"
    mkdir -p -- "$(dirname "${path}")"
    cp -a -- "${source}" "$(dirname "${path}")/"
}

rollback_restore() {
    [[ "${CHANGES_STARTED}" -eq 1 ]] || return 0
    warn "Restore failed; rolling filesystem changes back."
    set +e
    trap - ERR

    local path
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        remove_path_for_restore "${path}"
    done < "${RESTORE_PATHS_FILE}"

    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        if [[ -e "${ROLLBACK_ROOT}${path}" || -L "${ROLLBACK_ROOT}${path}" ]]; then
            copy_staged_path "${ROLLBACK_ROOT}" "${path}"
        fi
    done < "${PRE_EXISTING_FILE}"

    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart nginx >/dev/null 2>&1 || true
        else
            nginx -s reload >/dev/null 2>&1 || nginx >/dev/null 2>&1 || true
        fi
    fi
    warn "Rollback archive retained at: ${ROLLBACK_ARCHIVE}"
}

on_restore_error() {
    local status="$1" line="$2"
    warn "Command failed at line ${line} with exit code ${status}."
    rollback_restore
    exit "${status}"
}

restore_acme_crontab() {
    local saved="$1"
    [[ -s "${saved}" ]] || return 0
    command -v crontab >/dev/null 2>&1 || {
        warn "crontab is unavailable; restore the saved acme.sh cron entry manually."
        return 0
    }

    local merged="${WORK_DIR}/root-crontab.txt"
    crontab -l > "${merged}" 2>/dev/null || true
    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        grep -Fqx -- "${line}" "${merged}" || printf '%s\n' "${line}" >> "${merged}"
    done < "${saved}"
    crontab "${merged}"
}

install_certbot_best_effort() {
    [[ -d /etc/letsencrypt ]] || return 0
    if command -v certbot >/dev/null 2>&1 \
        && certbot plugins 2>/dev/null | grep -q 'nginx'; then
        return 0
    fi
    warn "Certbot is not installed; attempting to install it for certificate renewal."
    install_certbot \
        || warn "Install Certbot manually to keep Let's Encrypt certificates renewing."
}

restore_bundle() {
    [[ $# -ge 1 ]] || die "restore requires a backup archive."
    local archive="$1"
    shift
    local force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                force=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown restore option: $1"
                ;;
        esac
    done

    require_root
    require_command tar
    require_command sha256sum
    [[ -f "${archive}" ]] || die "Backup archive not found: ${archive}"
    archive="$(cd "$(dirname "${archive}")" && pwd)/$(basename "${archive}")"

    WORK_DIR="$(mktemp -d /tmp/ngx-migrate-restore.XXXXXX)"
    trap cleanup EXIT
    trap 'on_restore_error $? $LINENO' ERR
    local payload="${archive}"
    if [[ "$(head -c 8 "${archive}" 2>/dev/null || true)" == "Salted__" ]]; then
        require_command openssl
        payload="${WORK_DIR}/payload.tar.gz"
        log "Encrypted archive detected; enter its passphrase."
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "${archive}" -out "${payload}"
    fi

    local listing="${WORK_DIR}/archive-list.txt"
    tar -tzf "${payload}" > "${listing}"
    local entry
    while IFS= read -r entry; do
        [[ "${entry}" != /* ]] || die "Archive contains an absolute path: ${entry}"
        case "/${entry}/" in
            */../*|*/./../*|*/.././*) die "Archive contains path traversal: ${entry}" ;;
        esac
    done < "${listing}"

    mkdir -p "${WORK_DIR}/extracted"
    tar --numeric-owner -xzf "${payload}" -C "${WORK_DIR}/extracted"
    local extracted="${WORK_DIR}/extracted"
    [[ -f "${extracted}/manifest/metadata.tsv" ]] || die "Invalid archive: metadata is missing."
    [[ -f "${extracted}/manifest/paths.txt" ]] || die "Invalid archive: path manifest is missing."
    [[ -f "${extracted}/SHA256SUMS" ]] || die "Invalid archive: checksums are missing."
    (
        cd "${extracted}"
        sha256sum -c SHA256SUMS
    )

    local metadata="${extracted}/manifest/metadata.tsv"
    local format_version backup_os backup_flavor backup_host
    format_version="$(metadata_value "${metadata}" format_version)"
    [[ "${format_version}" == "1" ]] || die "Unsupported backup format: ${format_version:-unknown}"
    backup_os="$(metadata_value "${metadata}" os_id)"
    backup_flavor="$(metadata_value "${metadata}" nginx_flavor)"
    backup_host="$(metadata_value "${metadata}" hostname)"

    local current_os="unknown"
    if [[ -r /etc/os-release ]]; then
        current_os="$(sed -n 's/^ID=//p' /etc/os-release | head -n 1 | tr -d '\"')"
        current_os="${current_os:-unknown}"
    fi
    if [[ "${backup_os}" != "unknown" && "${current_os}" != "unknown" && "${backup_os}" != "${current_os}" ]]; then
        if [[ "${force}" -eq 0 ]]; then
            die "OS mismatch: backup=${backup_os}, current=${current_os}. Use the same distribution or rerun with --force."
        fi
        warn "Continuing across an OS mismatch because --force was supplied."
    fi

    install_nginx "${backup_flavor:-nginx}"

    RESTORE_PATHS_FILE="${extracted}/manifest/paths.txt"
    local path
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        safe_restore_path "${path}" || die "Archive requests an unsafe restore path: ${path}"
        [[ -e "${extracted}/rootfs${path}" || -L "${extracted}/rootfs${path}" ]] \
            || die "Archive payload is missing: ${path}"
    done < "${RESTORE_PATHS_FILE}"

    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p /var/backups/ngx-migrate
    ROLLBACK_ROOT="${WORK_DIR}/rollback-rootfs"
    PRE_EXISTING_FILE="${WORK_DIR}/pre-existing-paths.txt"
    mkdir -p "${ROLLBACK_ROOT}"
    : > "${PRE_EXISTING_FILE}"
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        if [[ -e "${path}" || -L "${path}" ]]; then
            printf '%s\n' "${path}" >> "${PRE_EXISTING_FILE}"
            cp -a --parents -- "${path}" "${ROLLBACK_ROOT}"
        fi
    done < "${RESTORE_PATHS_FILE}"

    ROLLBACK_ARCHIVE="/var/backups/ngx-migrate/pre-restore-${timestamp}.tar.gz"
    tar --numeric-owner -czf "${ROLLBACK_ARCHIVE}" \
        -C "${WORK_DIR}" rollback-rootfs pre-existing-paths.txt
    chmod 600 "${ROLLBACK_ARCHIVE}"
    log "Pre-restore rollback archive: ${ROLLBACK_ARCHIVE}"

    CHANGES_STARTED=1
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        log "Restoring ${path}"
        remove_path_for_restore "${path}"
        copy_staged_path "${extracted}/rootfs" "${path}"
    done < "${RESTORE_PATHS_FILE}"

    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
    log "Validating restored Nginx configuration."
    nginx -t

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable nginx
        systemctl restart nginx
        systemctl is-active --quiet nginx
    else
        nginx -s reload 2>/dev/null || nginx
    fi

    restore_acme_crontab "${extracted}/manifest/acme-root-crontab.txt"
    install_certbot_best_effort

    CHANGES_STARTED=0
    trap - ERR
    log "Restore complete. Source host: ${backup_host:-unknown}"
    log "Nginx configuration is valid and the service is running."
    log "Rollback archive retained at: ${ROLLBACK_ARCHIVE}"
    warn "This migrates Nginx, certificates and selected files only. Update DNS and deploy upstream applications separately."
    cleanup
    WORK_DIR=""
}

pause_menu() {
    printf '\n'
    read -r -p "按回车键返回菜单..." _ || true
}

run_menu_action() {
    local status
    set +e
    (
        set -Eeuo pipefail
        "$@"
    )
    status=$?
    set -e
    if [[ "${status}" -ne 0 ]]; then
        warn "操作失败，请根据上面的错误信息检查后重试。"
    fi
    return 0
}

interactive_create_site() {
    local kind="$1" domain target use_ssl email=""
    read -r -p "域名（例如 app.example.com）: " domain
    if [[ "${kind}" == "proxy" ]]; then
        read -r -p "本机服务端口或反代地址 [3000]: " target
        target="${target:-3000}"
    else
        read -r -p "静态文件目录 [/var/www/${domain}]: " target
        target="${target:-/var/www/${domain}}"
    fi
    read -r -p "现在申请 HTTPS？[Y/n]: " use_ssl
    if [[ ! "${use_ssl}" =~ ^[Nn]$ ]]; then
        read -r -p "证书通知邮箱: " email
        run_menu_action create_site "${kind}" "${domain}" "${target}" --email "${email}"
    else
        run_menu_action create_site "${kind}" "${domain}" "${target}" --no-ssl
    fi
}

interactive_export() {
    local output encrypt webroot
    local -a args=()
    read -r -p "输出文件（留空自动命名）: " output
    [[ -n "${output}" ]] && args+=(--output "${output}")
    read -r -p "是否用密码加密迁移包？[Y/n]: " encrypt
    [[ ! "${encrypt}" =~ ^[Nn]$ ]] && args+=(--encrypt)
    read -r -p "是否同时打包静态站点目录？[y/N]: " webroot
    [[ "${webroot}" =~ ^[Yy]$ ]] && args+=(--with-webroot)
    run_menu_action export_bundle "${args[@]}"
}

interactive_delete() {
    local domain cert answer
    read -r -p "要删除的域名: " domain
    read -r -p "同时删除 Certbot 证书？[y/N]: " cert
    read -r -p "确认删除 ${domain}？输入 yes 继续: " answer
    if [[ "${answer}" != "yes" ]]; then
        log "已取消。"
        return 0
    fi
    if [[ "${cert}" =~ ^[Yy]$ ]]; then
        run_menu_action delete_site "${domain}" --delete-cert
    else
        run_menu_action delete_site "${domain}"
    fi
}

interactive_custom_certificate() {
    local domain cert_file key_file chain_file
    read -r -p "域名: " domain
    read -r -p "证书文件路径（cert.pem 或 fullchain.pem）: " cert_file
    read -r -p "私钥文件路径（privkey.pem/key.pem）: " key_file
    read -r -p "单独的证书链路径（没有请留空）: " chain_file
    if [[ -n "${chain_file}" ]]; then
        run_menu_action install_custom_certificate \
            "${domain}" "${cert_file}" "${key_file}" --chain "${chain_file}"
    else
        run_menu_action install_custom_certificate "${domain}" "${cert_file}" "${key_file}"
    fi
}

interactive_menu() {
    require_root
    [[ -t 0 ]] || {
        usage
        return 0
    }

    local choice domain email archive
    while true; do
        command -v clear >/dev/null 2>&1 && clear || true
        cat <<'EOF'
============================================================
 nginx-easy-deploy - 原生 Nginx 一键部署与迁移
 不安装面板，不常驻额外服务
============================================================
  1. 安装/修复 Nginx + Certbot
  2. 新建反向代理站点
  3. 新建静态网站
  4. 给已有站点启用 HTTPS
  5. 上传并安装自有证书
  6. 查看站点
  7. 删除站点
  8. 续签全部证书
  9. 导出配置和证书
 10. 从迁移包恢复
 11. 查看运行状态
  0. 退出
------------------------------------------------------------
EOF
        read -r -p "请选择 [0-11]: " choice || return 0
        printf '\n'
        case "${choice}" in
            1) run_menu_action install_stack ;;
            2) interactive_create_site proxy ;;
            3) interactive_create_site static ;;
            4)
                read -r -p "域名: " domain
                read -r -p "证书通知邮箱: " email
                run_menu_action enable_https_domain "${domain}" "${email}"
                ;;
            5) interactive_custom_certificate ;;
            6) run_menu_action list_sites ;;
            7) interactive_delete ;;
            8) run_menu_action renew_certificates ;;
            9) interactive_export ;;
            10)
                read -r -p "迁移包路径: " archive
                run_menu_action restore_bundle "${archive}"
                ;;
            11) run_menu_action show_status ;;
            0) return 0 ;;
            *) warn "无效选项。" ;;
        esac
        pause_menu
    done
}

main() {
    local command="${1:-}"
    [[ $# -gt 0 ]] && shift || true
    case "${command}" in
        install)
            install_stack "$@"
            ;;
        proxy)
            create_site proxy "$@"
            ;;
        static)
            create_site static "$@"
            ;;
        ssl|https)
            [[ $# -ge 2 ]] || die "用法: ${PROGRAM} ssl DOMAIN EMAIL"
            enable_https_domain "$1" "$2"
            ;;
        cert|certificate)
            install_custom_certificate "$@"
            ;;
        sites|list)
            list_sites
            ;;
        delete|remove)
            delete_site "$@"
            ;;
        renew)
            renew_certificates
            ;;
        status)
            show_status
            ;;
        export|backup)
            export_bundle "$@"
            ;;
        restore|import)
            restore_bundle "$@"
            ;;
        -h|--help|help)
            usage
            ;;
        "")
            interactive_menu
            ;;
        --version|version)
            printf '%s\n' "${VERSION}"
            ;;
        *)
            die "Unknown command: ${command}. Run ${PROGRAM} --help."
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
