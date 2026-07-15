#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION="0.3.0"
PROGRAM="${0##*/}"
UI_LANG="${NGX_EASY_LANG:-}"
WORK_DIR=""
CHANGES_STARTED=0
ROLLBACK_ROOT=""
ROLLBACK_ARCHIVE=""
RESTORE_PATHS_FILE=""
PRE_EXISTING_FILE=""

log()  { printf '[ngx-migrate] %s\n' "$*"; }
warn() { printf '[ngx-migrate] WARNING: %s\n' "$*" >&2; }
die()  { printf '[ngx-migrate] ERROR: %s\n' "$*" >&2; exit 1; }

ui_text() {
    if [[ "${UI_LANG:-zh}" == "en" ]]; then
        printf '%s' "$2"
    else
        printf '%s' "$1"
    fi
}

log_ui()  { log "$(ui_text "$1" "$2")"; }
warn_ui() { warn "$(ui_text "$1" "$2")"; }
die_ui()  { die "$(ui_text "$1" "$2")"; }

normalize_ui_language() {
    local language
    language="$(printf '%s' "${UI_LANG:-}" | tr 'A-Z' 'a-z')"
    case "${language}" in
        en|en_*|english) UI_LANG="en" ;;
        zh|zh_*|cn|chinese|"") UI_LANG="zh" ;;
        *) die "Unsupported language: ${UI_LANG}. Use zh or en." ;;
    esac
}

select_ui_language() {
    local force="${1:-0}" choice
    if [[ "${force}" -eq 0 && -n "${UI_LANG}" ]]; then
        normalize_ui_language
        return 0
    fi
    cat <<'EOF'
请选择语言 / Select language
  1. 中文
  2. English
EOF
    read -r -p "> " choice || choice="1"
    case "${choice}" in
        2|en|EN|English|english) UI_LANG="en" ;;
        *) UI_LANG="zh" ;;
    esac
}

usage_zh() {
    cat <<EOF
nginx-easy-deploy v${VERSION} - 原生 Nginx 一键部署与迁移

语言切换：
  sudo bash ${PROGRAM} --lang en
  sudo NGX_EASY_LANG=en bash ${PROGRAM}

直接打开中文菜单：
  sudo bash ${PROGRAM}

常用命令：
  sudo bash ${PROGRAM} install
  sudo bash ${PROGRAM} proxy example.com 127.0.0.1:3000 --email you@example.com
  sudo bash ${PROGRAM} static example.com /var/www/example.com --email you@example.com
  sudo bash ${PROGRAM} cert example.com fullchain.pem privkey.pem
  sudo bash ${PROGRAM} cert example.com cert.pem privkey.pem --chain chain.pem
  sudo bash ${PROGRAM} dns-ssl example.com you@example.com cloudflare.ini --wildcard
  sudo bash ${PROGRAM} doctor [example.com]
  sudo bash ${PROGRAM} certs
  sudo bash ${PROGRAM} cf-realip [--schedule]
  sudo bash ${PROGRAM} tune [--bbr]
  sudo bash ${PROGRAM} update
  sudo bash ${PROGRAM} sites
  sudo bash ${PROGRAM} status
  sudo bash ${PROGRAM} renew
  sudo bash ${PROGRAM} delete example.com [--delete-cert] [--backup-files]

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

Cloudflare DNS 证书：
  dns-ssl DOMAIN EMAIL CREDENTIALS_FILE [--wildcard] [--staging]
  CREDENTIALS_FILE 内容：dns_cloudflare_api_token = YOUR_TOKEN
  Token 只需目标区域的 Zone:DNS:Edit 权限

运维选项：
  cf-realip             更新 Cloudflare 真实访客 IP 配置
  cf-realip --schedule  更新并安装每周自动更新任务（非守护进程）
  cf-realip --remove    删除脚本管理的 Cloudflare 配置和任务
  tune [--bbr]           保守调优；BBR 仅在明确添加选项时启用
  tune --restore latest  恢复最近一次调优前的设置
  update                 备份后使用系统软件源更新 Nginx

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

usage_en() {
    cat <<EOF
nginx-easy-deploy v${VERSION} - native Nginx deployment and migration

Open the interactive menu:
  sudo bash ${PROGRAM} --lang en
  sudo NGX_EASY_LANG=en bash ${PROGRAM}

Common commands:
  sudo bash ${PROGRAM} install
  sudo bash ${PROGRAM} proxy example.com 127.0.0.1:3000 --email you@example.com
  sudo bash ${PROGRAM} static example.com /var/www/example.com --email you@example.com
  sudo bash ${PROGRAM} cert example.com fullchain.pem privkey.pem
  sudo bash ${PROGRAM} dns-ssl example.com you@example.com cloudflare.ini --wildcard
  sudo bash ${PROGRAM} doctor [example.com]
  sudo bash ${PROGRAM} certs
  sudo bash ${PROGRAM} cf-realip [--schedule]
  sudo bash ${PROGRAM} tune [--bbr]
  sudo bash ${PROGRAM} update
  sudo bash ${PROGRAM} sites
  sudo bash ${PROGRAM} status
  sudo bash ${PROGRAM} renew
  sudo bash ${PROGRAM} delete example.com [--delete-cert] [--backup-files]

Export on the old server:
  sudo bash ${PROGRAM} export
  sudo bash ${PROGRAM} export -o /root/nginx-backup.tar.gz
  sudo bash ${PROGRAM} export --encrypt
  sudo bash ${PROGRAM} export --with-webroot
  sudo bash ${PROGRAM} export --include /path/to/extra/files

Restore on the new server:
  sudo bash ${PROGRAM} restore nginx-backup.tar.gz
  sudo bash ${PROGRAM} restore nginx-backup.tar.gz.enc

Site options:
  --email ADDRESS       Email used for Let's Encrypt registration
  --no-ssl              Deploy HTTP only
  --force               Replace an existing script-managed site

Cloudflare DNS certificate:
  dns-ssl DOMAIN EMAIL CREDENTIALS_FILE [--wildcard] [--staging]
  CREDENTIALS_FILE: dns_cloudflare_api_token = YOUR_TOKEN
  Use a token restricted to Zone:DNS:Edit for the target zone

Operations:
  cf-realip             Refresh the trusted Cloudflare IP ranges
  cf-realip --schedule  Refresh now and install a weekly update task
  cf-realip --remove    Remove the managed real-IP config and task
  tune [--bbr]          Apply conservative tuning; BBR is opt-in
  tune --restore latest Restore the latest pre-tuning state
  update                 Back up and update Nginx from system packages

Migration options:
  -o, --output FILE     Set the archive path
  --encrypt             Encrypt the archive with an OpenSSL passphrase
  --with-webroot        Include static roots and aliases referenced by Nginx
  --include PATH        Include another file or directory; repeatable
  --force               Export invalid config or restore across distributions
  -h, --help            Show this help

Supported: Debian, Ubuntu, CentOS, RHEL, Rocky Linux and AlmaLinux.
Native Nginx only; Docker, Nginx Proxy Manager and Kubernetes are out of scope.
OpenResty configs can be exported, but a compatible build must exist before restore.
EOF
}

usage() {
    if [[ "${UI_LANG:-zh}" == "en" ]]; then
        usage_en
    else
        usage_zh
    fi
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

    log_ui "Nginx 未安装，正在使用系统软件源安装。" \
        "Nginx is not installed; installing it from the system package repository."
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

    log_ui "正在安装 Certbot 和 Nginx 插件。" \
        "Installing Certbot and its Nginx plugin."
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

install_cloudflare_certbot() {
    install_certbot || return 1
    if certbot plugins 2>/dev/null | grep -q 'dns-cloudflare'; then
        return 0
    fi

    log_ui "正在安装 Certbot Cloudflare DNS 插件。" \
        "Installing the Certbot Cloudflare DNS plugin."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3-certbot-dns-cloudflare
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3-certbot-dns-cloudflare
    elif command -v yum >/dev/null 2>&1; then
        yum install -y python3-certbot-dns-cloudflare
    elif command -v apk >/dev/null 2>&1; then
        apk add certbot-dns-cloudflare
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install python3-certbot-dns-cloudflare
    else
        return 1
    fi

    certbot plugins 2>/dev/null | grep -q 'dns-cloudflare'
}

open_firewall_ports() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow 'Nginx Full' >/dev/null 2>&1 \
            || { ufw allow 80/tcp && ufw allow 443/tcp; }
        log_ui "已在 UFW 放行 80/443 端口。" \
            "Opened ports 80 and 443 in UFW."
    fi
    if command -v firewall-cmd >/dev/null 2>&1 \
        && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-service=http >/dev/null
        firewall-cmd --permanent --add-service=https >/dev/null
        firewall-cmd --reload >/dev/null
        log_ui "已在 firewalld 放行 80/443 端口。" \
            "Opened HTTP and HTTPS services in firewalld."
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
        die_ui "当前 nginx.conf 未加载 conf.d/*.conf，脚本不会冒险自动改写非标准主配置。" \
            "The current nginx.conf does not include conf.d/*.conf. Refusing to rewrite a non-standard main config."
    fi
    mkdir -p "${MANAGED_CONFIG_DIR}"
}

install_stack() {
    require_root
    install_nginx nginx
    if ! install_certbot; then
        warn_ui "Certbot 安装失败，Nginx 已可使用，但自动 HTTPS 暂不可用。" \
            "Certbot installation failed. Nginx is usable, but automatic HTTPS is unavailable."
    fi
    ensure_managed_config_dir
    open_firewall_ports
    start_nginx
    log_ui "原生 Nginx 安装完成。" "Native Nginx installation completed."
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
    validate_domain "${domain}" || die_ui "域名格式不正确: ${domain}" "Invalid domain: ${domain}"
    validate_email "${email}" || die_ui "邮箱格式不正确: ${email}" "Invalid email address: ${email}"
    command -v nginx >/dev/null 2>&1 || install_nginx nginx
    ensure_managed_config_dir
    open_firewall_ports
    [[ -f "$(site_config_path "${domain}")" ]] \
        || die_ui "没有找到脚本管理的站点: ${domain}" "No script-managed site was found for: ${domain}"
    install_certbot || die_ui "Certbot 或其 Nginx 插件安装失败。" \
        "Certbot or its Nginx plugin could not be installed."

    log_ui "正在为 ${domain} 申请并配置 Let's Encrypt 证书。" \
        "Requesting and configuring a Let's Encrypt certificate for ${domain}."
    certbot --nginx --non-interactive --agree-tos --redirect \
        --email "${email}" --domains "${domain}"
    reload_nginx
    log_ui "HTTPS 已启用: https://${domain}" "HTTPS enabled: https://${domain}"
}

install_custom_certificate() {
    [[ $# -ge 3 ]] || die_ui \
        "用法: ${PROGRAM} cert DOMAIN CERT_FILE KEY_FILE [--chain CHAIN_FILE] [--force]" \
        "Usage: ${PROGRAM} cert DOMAIN CERT_FILE KEY_FILE [--chain CHAIN_FILE] [--force]"
    local domain="$1" cert_file="$2" key_file="$3"
    shift 3
    local chain_file="" force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --chain)
                [[ $# -ge 2 ]] || die_ui "--chain 需要证书链文件。" \
                    "--chain requires a certificate chain file."
                chain_file="$2"
                shift 2
                ;;
            --force)
                force=1
                shift
                ;;
            *)
                die_ui "未知证书选项: $1" "Unknown certificate option: $1"
                ;;
        esac
    done

    require_root
    require_command openssl
    require_command sha256sum
    domain="$(printf '%s' "${domain}" | tr 'A-Z' 'a-z')"
    validate_domain "${domain}" || die_ui "域名格式不正确: ${domain}" "Invalid domain: ${domain}"
    [[ -f "${cert_file}" && -r "${cert_file}" ]] \
        || die_ui "证书文件不可读: ${cert_file}" "Certificate file is not readable: ${cert_file}"
    [[ -f "${key_file}" && -r "${key_file}" ]] \
        || die_ui "私钥文件不可读: ${key_file}" "Private key file is not readable: ${key_file}"
    if [[ -n "${chain_file}" ]]; then
        [[ -f "${chain_file}" && -r "${chain_file}" ]] \
            || die_ui "证书链文件不可读: ${chain_file}" "Certificate chain file is not readable: ${chain_file}"
    fi

    openssl x509 -in "${cert_file}" -noout >/dev/null \
        || die_ui "无法解析证书文件。" "The certificate file could not be parsed."
    openssl pkey -in "${key_file}" -passin pass: -noout >/dev/null 2>&1 \
        || die_ui "无法解析私钥，或私钥带有密码。Nginx 自动启动需要无密码私钥。" \
            "The private key is invalid or encrypted. Nginx requires an unencrypted private key for unattended startup."

    local cert_hash key_hash
    cert_hash="$(openssl x509 -in "${cert_file}" -pubkey -noout \
        | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    key_hash="$(openssl pkey -in "${key_file}" -passin pass: -pubout -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}')"
    [[ -n "${cert_hash}" && "${cert_hash}" == "${key_hash}" ]] \
        || die_ui "证书与私钥不匹配。" "The certificate and private key do not match."

    if ! openssl x509 -in "${cert_file}" -checkend 0 -noout >/dev/null; then
        [[ "${force}" -eq 1 ]] || die_ui "证书已经过期；确认继续时添加 --force。" \
            "The certificate has expired. Add --force only if you intend to continue."
        warn_ui "正在安装已过期证书，因为使用了 --force。" \
            "Installing an expired certificate because --force was supplied."
    fi
    if openssl x509 -help 2>&1 | grep -q -- '-checkhost'; then
        if ! openssl x509 -in "${cert_file}" -checkhost "${domain}" -noout >/dev/null 2>&1; then
            [[ "${force}" -eq 1 ]] || die_ui \
                "证书不匹配域名 ${domain}；确认继续时添加 --force。" \
                "The certificate does not match ${domain}. Add --force only if you intend to continue."
            warn_ui "证书域名不匹配，因为使用了 --force 仍将继续。" \
                "The certificate hostname does not match, but --force was supplied."
        fi
    else
        warn_ui "当前 OpenSSL 版本过旧，无法自动检查证书域名。" \
            "This OpenSSL version is too old to verify the certificate hostname automatically."
    fi

    command -v nginx >/dev/null 2>&1 || install_nginx nginx
    ensure_managed_config_dir
    open_firewall_ports
    local config
    config="$(site_config_path "${domain}")"
    [[ -f "${config}" ]] || die_ui "没有找到脚本管理的站点: ${domain}" \
        "No script-managed site was found for: ${domain}"
    if grep -Fq '# managed by Certbot' "${config}"; then
        die_ui "该站点正由 Certbot 管理。请先删除其 Certbot HTTPS 配置，或新建 --no-ssl 站点后上传自有证书。" \
            "This site is managed by Certbot. Remove its Certbot HTTPS changes or create an HTTP-only site before installing a custom certificate."
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
        die_ui "无法识别站点配置结构。" "The site configuration structure was not recognized."
    }
    install -m 644 "${new_config}" "${config}"

    if ! nginx -t; then
        cp -a "${config_backup}" "${config}"
        rm -rf "${cert_dir}"
        [[ -d "${cert_backup}" ]] && cp -a "${cert_backup}" "${cert_dir}"
        rm -rf "${work}"
        die_ui "自有证书配置校验失败，已恢复原配置和证书。" \
            "Custom certificate validation failed; the previous configuration and certificate were restored."
    fi
    reload_nginx
    rm -rf "${work}"
    log_ui "自有证书已安装: https://${domain}" "Custom certificate installed: https://${domain}"
    warn_ui "自有证书不会由 Certbot 自动续签，到期前请重新运行 cert 命令更新。" \
        "Custom certificates are not renewed by Certbot. Run the cert command again before expiry."
}

create_site() {
    local kind="$1"
    shift
    [[ $# -ge 2 ]] || die_ui "缺少参数。请查看 ${PROGRAM} --help。" \
        "Missing arguments. Run ${PROGRAM} --help."
    local domain="$1" target="$2"
    shift 2
    local email="" no_ssl=0 force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --email)
                [[ $# -ge 2 ]] || die_ui "--email 需要邮箱地址。" \
                    "--email requires an email address."
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
                die_ui "未知站点选项: $1" "Unknown site option: $1"
                ;;
        esac
    done

    require_root
    domain="$(printf '%s' "${domain}" | tr 'A-Z' 'a-z')"
    validate_domain "${domain}" || die_ui "域名格式不正确: ${domain}" "Invalid domain: ${domain}"
    if [[ -n "${email}" ]]; then
        validate_email "${email}" || die_ui "邮箱格式不正确: ${email}" "Invalid email address: ${email}"
    fi

    command -v nginx >/dev/null 2>&1 || install_nginx nginx
    ensure_managed_config_dir
    open_firewall_ports

    if [[ "${kind}" == "proxy" ]]; then
        target="$(normalize_upstream "${target}")" \
            || die_ui "反代地址不正确: ${target}" "Invalid reverse proxy upstream: ${target}"
        ensure_websocket_map
    else
        validate_static_root "${target}" \
            || die_ui "静态目录必须是安全的绝对路径: ${target}" \
                "The static root must be a safe absolute path: ${target}"
        mkdir -p "${target}"
        chmod 755 "${target}"
    fi

    local config backup="" temp
    config="$(site_config_path "${domain}")"
    if [[ -e "${config}" && "${force}" -ne 1 ]]; then
        die_ui "站点已存在: ${domain}。确认覆盖时添加 --force。" \
            "The site already exists: ${domain}. Add --force to replace it."
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
        die_ui "新配置校验失败，已恢复原配置。" \
            "The new configuration failed validation; the previous file was restored."
    fi
    [[ -n "${backup}" ]] && rm -f "${backup}"
    reload_nginx
    log_ui "HTTP 站点已部署: http://${domain}" "HTTP site deployed: http://${domain}"

    if [[ "${no_ssl}" -eq 0 && -n "${email}" ]]; then
        if ! enable_https_domain "${domain}" "${email}"; then
            warn_ui "HTTPS 申请失败，但 HTTP 站点仍然可用。请检查域名解析和 80/443 端口。" \
                "HTTPS issuance failed, but the HTTP site remains available. Check DNS and ports 80/443."
        fi
    elif [[ "${no_ssl}" -eq 0 ]]; then
        warn_ui "未提供邮箱，本次只部署 HTTP。之后可运行: ${PROGRAM} ssl ${domain} you@example.com" \
            "No email was provided, so only HTTP was deployed. Enable HTTPS later with: ${PROGRAM} ssl ${domain} you@example.com"
    fi
}

list_sites() {
    require_root
    command -v nginx >/dev/null 2>&1 || die_ui "Nginx 尚未安装。" "Nginx is not installed."
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
    [[ "${found}" -eq 1 ]] || log_ui "暂无脚本管理的站点。" "No script-managed sites were found."
}

delete_site() {
    local domain="${1:-}" delete_cert=0 backup_files=0
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --delete-cert) delete_cert=1; shift ;;
            --backup-files) backup_files=1; shift ;;
            *) die_ui "未知删除选项: $1" "Unknown delete option: $1" ;;
        esac
    done
    require_root
    validate_domain "${domain}" || die_ui "域名格式不正确: ${domain}" "Invalid domain: ${domain}"
    ensure_managed_config_dir
    local config backup
    config="$(site_config_path "${domain}")"
    [[ -f "${config}" ]] || die_ui "站点不存在: ${domain}" "Site not found: ${domain}"
    grep -Fq '# Managed by nginx-easy-deploy.' "${config}" \
        || die_ui "该文件不是脚本创建的，拒绝自动删除: ${config}" \
            "Refusing to delete a file that was not created by this script: ${config}"
    backup_site "${domain}" "${config}" "${backup_files}"
    backup="$(mktemp /tmp/ngx-easy-delete-backup.XXXXXX)"
    cp -a "${config}" "${backup}"
    rm -f "${config}"
    if ! nginx -t; then
        mv -f "${backup}" "${config}"
        die_ui "删除后 Nginx 校验失败，已恢复站点。" \
            "Nginx validation failed after deletion; the site was restored."
    fi
    rm -f "${backup}"
    reload_nginx
    if [[ "${delete_cert}" -eq 1 ]] && command -v certbot >/dev/null 2>&1; then
        certbot delete --non-interactive --cert-name "${domain}" || true
    fi
    if [[ "${delete_cert}" -eq 1 && -d "/etc/nginx/ssl/${domain}" ]]; then
        rm -rf -- "/etc/nginx/ssl/${domain}"
    fi
    log_ui "站点已删除: ${domain}" "Site deleted: ${domain}"
}

backup_site() {
    local domain="$1" config="$2" include_files="${3:-0}"
    local timestamp backup_dir item webroot=""
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="/var/backups/nginx-easy-deploy/sites/${domain}-${timestamp}"
    mkdir -p "${backup_dir}/rootfs"

    local -a items=("${config}")
    [[ -d "/etc/nginx/ssl/${domain}" ]] && items+=("/etc/nginx/ssl/${domain}")
    [[ -d "/etc/letsencrypt/live/${domain}" ]] && items+=("/etc/letsencrypt/live/${domain}")
    [[ -d "/etc/letsencrypt/archive/${domain}" ]] && items+=("/etc/letsencrypt/archive/${domain}")
    [[ -f "/etc/letsencrypt/renewal/${domain}.conf" ]] && items+=("/etc/letsencrypt/renewal/${domain}.conf")

    if [[ "${include_files}" -eq 1 ]]; then
        webroot="$(awk '$1 == "root" {gsub(/;$/, "", $2); print $2; exit}' "${config}")"
        if [[ -n "${webroot}" ]] && validate_static_root "${webroot}" \
            && [[ -d "${webroot}" ]]; then
            items+=("${webroot}")
        fi
    fi

    for item in "${items[@]}"; do
        cp -a --parents -- "${item}" "${backup_dir}/rootfs"
    done
    printf 'domain\t%s\ncreated_utc\t%s\ninclude_files\t%s\n' \
        "${domain}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${include_files}" \
        > "${backup_dir}/metadata.tsv"
    chmod -R go-rwx "${backup_dir}"
    log_ui "站点备份已保存: ${backup_dir}" "Site backup saved: ${backup_dir}"
}

renew_certificates() {
    require_root
    install_certbot || die_ui "Certbot 或其 Nginx 插件安装失败。" \
        "Certbot or its Nginx plugin could not be installed."
    certbot renew
    command -v nginx >/dev/null 2>&1 && reload_nginx
}

show_status() {
    require_root
    if ! command -v nginx >/dev/null 2>&1; then
        log_ui "Nginx 尚未安装。" "Nginx is not installed."
        return 0
    fi
    nginx -v 2>&1
    nginx -t
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx; then
            log_ui "Nginx 服务状态: running" "Nginx service: running"
        else
            warn_ui "Nginx 服务状态: stopped" "Nginx service: stopped"
        fi
    fi
    if command -v certbot >/dev/null 2>&1; then
        certbot certificates || true
    else
        warn_ui "Certbot 尚未安装。" "Certbot is not installed."
    fi
}

certificate_days_left() {
    local cert_file="$1" end_date end_epoch now_epoch delta
    end_date="$(openssl x509 -in "${cert_file}" -noout -enddate 2>/dev/null | cut -d= -f2-)"
    [[ -n "${end_date}" ]] || return 1
    end_epoch="$(date -d "${end_date}" +%s 2>/dev/null)" || return 1
    now_epoch="$(date -u +%s)"
    delta=$((end_epoch - now_epoch))
    if (( delta < 0 )); then
        printf '%s\n' "$(( -((-delta + 86399) / 86400) ))"
    else
        printf '%s\n' "$(( delta / 86400 ))"
    fi
}

check_certificates() {
    [[ $# -eq 0 ]] || die_ui "用法: ${PROGRAM} certs" "Usage: ${PROGRAM} certs"
    require_root
    require_command openssl
    command -v nginx >/dev/null 2>&1 || die_ui "Nginx 尚未安装。" "Nginx is not installed."
    local dump path end_date days status found=0
    dump="$(nginx -T 2>&1 || true)"
    printf '%-7s %-8s %-24s %s\n' "STATUS" "DAYS" "EXPIRES" "CERTIFICATE"
    printf '%-7s %-8s %-24s %s\n' "------" "----" "-------" "-----------"
    while IFS= read -r path; do
        [[ -f "${path}" ]] || continue
        found=1
        end_date="$(openssl x509 -in "${path}" -noout -enddate 2>/dev/null | cut -d= -f2- || true)"
        days="$(certificate_days_left "${path}" 2>/dev/null || true)"
        if [[ -z "${days}" ]]; then
            status="ERROR"
            days="-"
        elif (( days < 0 )); then
            status="EXPIRED"
        elif (( days <= 7 )); then
            status="URGENT"
        elif (( days <= 30 )); then
            status="WARN"
        else
            status="OK"
        fi
        printf '%-7s %-8s %-24s %s\n' "${status}" "${days}" "${end_date:--}" "${path}"
    done < <(
        printf '%s\n' "${dump}" \
            | awk '$1 == "ssl_certificate" {value=$2; sub(/;$/, "", value); if (value ~ /^\// && value !~ /\$/) print value}' \
            | sort -u
    )
    [[ "${found}" -eq 1 ]] || log_ui "没有发现 Nginx 正在使用的本地证书。" \
        "No local certificate referenced by Nginx was found."
}

detect_public_ipv4() {
    local service result
    command -v curl >/dev/null 2>&1 || return 1
    for service in \
        https://api.ipify.org \
        https://checkip.amazonaws.com \
        https://icanhazip.com; do
        result="$(curl -4fsS --connect-timeout 2 --max-time 4 "${service}" 2>/dev/null | tr -d '\r\n ' || true)"
        if [[ "${result}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s\n' "${result}"
            return 0
        fi
    done
    return 1
}

doctor() {
    [[ $# -le 1 ]] || die_ui "用法: ${PROGRAM} doctor [DOMAIN]" \
        "Usage: ${PROGRAM} doctor [DOMAIN]"
    local domain="${1:-}" os_id="unknown" os_version="unknown"
    local public_ip="unknown" local_ips="unknown" memory_mb="unknown" cpu_count="unknown"
    if [[ -r /etc/os-release ]]; then
        os_id="$(sed -n 's/^ID=//p' /etc/os-release | head -n1 | tr -d '\"')"
        os_version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -n1 | tr -d '\"')"
    fi
    command -v nproc >/dev/null 2>&1 && cpu_count="$(nproc)"
    [[ -r /proc/meminfo ]] && memory_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
    command -v hostname >/dev/null 2>&1 && local_ips="$(hostname -I 2>/dev/null | xargs || true)"
    public_ip="$(detect_public_ipv4 2>/dev/null || printf unknown)"

    log_ui "环境诊断" "Environment diagnostics"
    printf '  %-16s %s %s\n' "OS" "${os_id}" "${os_version}"
    printf '  %-16s %s\n' "CPU" "${cpu_count}"
    printf '  %-16s %s MB\n' "Memory" "${memory_mb}"
    printf '  %-16s %s\n' "Local IPv4" "${local_ips:-unknown}"
    printf '  %-16s %s\n' "Public IPv4" "${public_ip}"

    if command -v nginx >/dev/null 2>&1; then
        printf '  %-16s %s\n' "Nginx" "$(nginx -v 2>&1)"
        if nginx -t >/dev/null 2>&1; then
            printf '  %-16s %s\n' "Config" "OK"
        else
            printf '  %-16s %s\n' "Config" "FAILED"
            nginx -t || true
        fi
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
            printf '  %-16s %s\n' "Service" "running"
        else
            printf '  %-16s %s\n' "Service" "stopped or unknown"
        fi
    else
        printf '  %-16s %s\n' "Nginx" "not installed"
    fi

    if command -v ss >/dev/null 2>&1; then
        log_ui "80/443 端口监听" "Listeners on ports 80 and 443"
        ss -ltnp 2>/dev/null | awk 'NR == 1 || $4 ~ /:80$|:443$/' || true
    fi

    if [[ -n "${domain}" ]]; then
        validate_domain "${domain}" || die_ui "域名格式不正确: ${domain}" "Invalid domain: ${domain}"
        log_ui "域名诊断: ${domain}" "Domain diagnostics: ${domain}"
        local resolved=""
        if command -v getent >/dev/null 2>&1; then
            resolved="$(getent ahostsv4 "${domain}" 2>/dev/null | awk '{print $1}' | sort -u | xargs || true)"
        fi
        printf '  %-16s %s\n' "DNS IPv4" "${resolved:-unresolved}"
        if [[ "${public_ip}" != "unknown" && -n "${resolved}" ]]; then
            if printf '%s\n' "${resolved}" | tr ' ' '\n' | grep -Fxq "${public_ip}"; then
                printf '  %-16s %s\n' "DNS Match" "yes"
            else
                printf '  %-16s %s\n' "DNS Match" "no (CDN/NAT may be intentional)"
            fi
        fi
    fi
}

validate_cloudflare_ranges() {
    local file="$1" family="$2" line count=0
    [[ -s "${file}" ]] || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line//$'\r'/}"
        [[ -n "${line}" ]] || continue
        if [[ "${family}" == "4" ]]; then
            [[ "${line}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
        else
            [[ "${line}" =~ ^[0-9A-Fa-f:]+/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$ ]] || return 1
        fi
        count=$((count + 1))
    done < "${file}"
    (( count >= 5 ))
}

write_cloudflare_realip_config() {
    local output="$1" ipv4_file="$2" ipv6_file="$3" range
    {
        printf '%s\n' '# Managed by nginx-easy-deploy.'
        printf '%s\n' '# Source: https://www.cloudflare.com/ips/'
        printf '%s\n' 'real_ip_header CF-Connecting-IP;'
        printf '%s\n' 'real_ip_recursive on;'
        while IFS= read -r range || [[ -n "${range}" ]]; do
            range="${range//$'\r'/}"
            [[ -n "${range}" ]] && printf 'set_real_ip_from %s;\n' "${range}"
        done < "${ipv4_file}"
        while IFS= read -r range || [[ -n "${range}" ]]; do
            range="${range//$'\r'/}"
            [[ -n "${range}" ]] && printf 'set_real_ip_from %s;\n' "${range}"
        done < "${ipv6_file}"
    } > "${output}"
}

install_cloudflare_schedule() {
    local script_source script_copy cron_script
    script_source="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    [[ -f "${script_source}" ]] || die_ui "无法定位当前脚本，不能安装自动更新任务。" \
        "The current script could not be located, so the update task cannot be installed."
    script_copy="/usr/local/libexec/nginx-easy-cloudflare-realip.sh"
    cron_script="/etc/cron.weekly/nginx-easy-cloudflare-realip"
    mkdir -p /usr/local/libexec /etc/cron.weekly
    install -m 700 "${script_source}" "${script_copy}"
    cat > "${cron_script}" <<EOF
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
exec /usr/bin/env bash ${script_copy} cf-realip
EOF
    chmod 700 "${cron_script}"
    log_ui "已安装每周 Cloudflare IP 更新任务: ${cron_script}" \
        "Installed the weekly Cloudflare IP update task: ${cron_script}"
}

cloudflare_realip() {
    local schedule=0 remove=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --schedule) schedule=1; shift ;;
            --remove) remove=1; shift ;;
            *) die_ui "未知 Cloudflare 真实 IP 选项: $1" \
                "Unknown Cloudflare real-IP option: $1" ;;
        esac
    done

    require_root
    command -v nginx >/dev/null 2>&1 || die_ui "Nginx 尚未安装。" "Nginx is not installed."
    ensure_managed_config_dir
    local config="${MANAGED_CONFIG_DIR}/00-ngx-easy-cloudflare-realip.conf"
    local backup_dir timestamp backup=""
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="/var/backups/nginx-easy-deploy/cloudflare-realip"
    mkdir -p "${backup_dir}"
    if [[ -f "${config}" ]]; then
        backup="${backup_dir}/cloudflare-realip-${timestamp}.conf"
        cp -a "${config}" "${backup}"
    fi

    if [[ "${remove}" -eq 1 ]]; then
        rm -f "${config}" \
            /etc/cron.weekly/nginx-easy-cloudflare-realip \
            /usr/local/libexec/nginx-easy-cloudflare-realip.sh
        if ! nginx -t; then
            [[ -n "${backup}" ]] && cp -a "${backup}" "${config}"
            die_ui "删除 Cloudflare 真实 IP 配置后校验失败，已恢复。" \
                "Validation failed after removing the Cloudflare real-IP config; it was restored."
        fi
        reload_nginx
        log_ui "已删除脚本管理的 Cloudflare 真实 IP 配置和自动任务。" \
            "Removed the managed Cloudflare real-IP configuration and update task."
        return 0
    fi

    require_command curl
    local work ipv4_file ipv6_file temp
    work="$(mktemp -d /tmp/ngx-easy-cloudflare.XXXXXX)"
    ipv4_file="${work}/ips-v4"
    ipv6_file="${work}/ips-v6"
    curl -fsSL --retry 3 --connect-timeout 5 --max-time 30 \
        https://www.cloudflare.com/ips-v4/ -o "${ipv4_file}"
    curl -fsSL --retry 3 --connect-timeout 5 --max-time 30 \
        https://www.cloudflare.com/ips-v6/ -o "${ipv6_file}"
    validate_cloudflare_ranges "${ipv4_file}" 4 \
        || { rm -rf "${work}"; die_ui "Cloudflare IPv4 列表校验失败，未修改配置。" \
            "Cloudflare IPv4 range validation failed; no configuration was changed."; }
    validate_cloudflare_ranges "${ipv6_file}" 6 \
        || { rm -rf "${work}"; die_ui "Cloudflare IPv6 列表校验失败，未修改配置。" \
            "Cloudflare IPv6 range validation failed; no configuration was changed."; }

    temp="$(mktemp "${MANAGED_CONFIG_DIR}/.ngx-easy-cloudflare.XXXXXX")"
    write_cloudflare_realip_config "${temp}" "${ipv4_file}" "${ipv6_file}"
    chmod 644 "${temp}"
    mv -f "${temp}" "${config}"
    if ! nginx -t; then
        if [[ -n "${backup}" ]]; then
            cp -a "${backup}" "${config}"
        else
            rm -f "${config}"
        fi
        rm -rf "${work}"
        die_ui "Cloudflare 真实 IP 配置校验失败，已恢复原配置。" \
            "Cloudflare real-IP configuration validation failed; the previous file was restored."
    fi
    reload_nginx
    rm -rf "${work}"
    log_ui "Cloudflare 真实访客 IP 配置已更新。" \
        "Cloudflare real visitor IP configuration updated."
    [[ "${schedule}" -eq 1 ]] && install_cloudflare_schedule
}

install_certbot_reload_hook() {
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    local hook="${hook_dir}/nginx-easy-reload"
    mkdir -p "${hook_dir}"
    cat > "${hook}" <<'EOF'
#!/bin/sh
nginx -t || exit 1
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    exec systemctl reload nginx
fi
exec nginx -s reload
EOF
    chmod 755 "${hook}"
}

enable_cloudflare_dns_https() {
    [[ $# -ge 3 ]] || die_ui \
        "用法: ${PROGRAM} dns-ssl DOMAIN EMAIL CREDENTIALS_FILE [--wildcard] [--staging]" \
        "Usage: ${PROGRAM} dns-ssl DOMAIN EMAIL CREDENTIALS_FILE [--wildcard] [--staging]"
    local domain="$1" email="$2" credentials_source="$3"
    shift 3
    local wildcard=0 staging=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --wildcard) wildcard=1; shift ;;
            --staging) staging=1; shift ;;
            *) die_ui "未知 DNS 证书选项: $1" "Unknown DNS certificate option: $1" ;;
        esac
    done

    require_root
    domain="$(printf '%s' "${domain}" | tr 'A-Z' 'a-z')"
    validate_domain "${domain}" || die_ui "域名格式不正确: ${domain}" "Invalid domain: ${domain}"
    validate_email "${email}" || die_ui "邮箱格式不正确: ${email}" "Invalid email address: ${email}"
    [[ -f "${credentials_source}" && -r "${credentials_source}" ]] \
        || die_ui "Cloudflare 凭据文件不可读: ${credentials_source}" \
            "Cloudflare credentials file is not readable: ${credentials_source}"
    local token
    token="$(awk -F= '
        /^[[:space:]]*dns_cloudflare_api_token[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, ""); gsub(/[[:space:]\r]+$/, ""); print; exit
        }
    ' "${credentials_source}")"
    [[ "${token}" =~ ^[A-Za-z0-9_-]{20,}$ ]] \
        || die_ui "凭据文件中缺少有效的 dns_cloudflare_api_token。" \
            "The credentials file does not contain a valid dns_cloudflare_api_token."

    command -v nginx >/dev/null 2>&1 || install_nginx nginx
    ensure_managed_config_dir
    local config
    config="$(site_config_path "${domain}")"
    [[ -f "${config}" ]] || die_ui "没有找到脚本管理的站点: ${domain}" \
        "No script-managed site was found for: ${domain}"
    install_cloudflare_certbot \
        || die_ui "Certbot Cloudflare DNS 插件安装失败，请检查系统软件源。" \
            "The Certbot Cloudflare DNS plugin could not be installed. Check the system package repository."

    local credentials_dir="/etc/letsencrypt/cloudflare"
    local credentials="${credentials_dir}/${domain}.ini" temp_credentials
    mkdir -p "${credentials_dir}"
    chmod 700 "${credentials_dir}"
    temp_credentials="$(mktemp "${credentials_dir}/.credentials.XXXXXX")"
    printf 'dns_cloudflare_api_token = %s\n' "${token}" > "${temp_credentials}"
    chmod 600 "${temp_credentials}"
    mv -f "${temp_credentials}" "${credentials}"
    install_certbot_reload_hook
    backup_site "${domain}" "${config}" 0

    local -a args=(
        run
        --authenticator dns-cloudflare
        --installer nginx
        --dns-cloudflare-credentials "${credentials}"
        --dns-cloudflare-propagation-seconds 30
        --non-interactive
        --agree-tos
        --no-eff-email
        --redirect
        --email "${email}"
        --cert-name "${domain}"
        --domains "${domain}"
    )
    if [[ "${wildcard}" -eq 1 ]]; then
        args+=(--domains "*.${domain}")
        [[ -d "/etc/letsencrypt/live/${domain}" ]] && args+=(--expand)
    fi
    [[ "${staging}" -eq 1 ]] && args+=(--staging)

    log_ui "正在通过 Cloudflare DNS 为 ${domain} 申请并安装证书。" \
        "Requesting and installing a certificate for ${domain} through Cloudflare DNS."
    certbot "${args[@]}"
    reload_nginx
    log_ui "Cloudflare DNS 证书已启用: https://${domain}" \
        "Cloudflare DNS certificate enabled: https://${domain}"
    [[ "${wildcard}" -eq 1 ]] && log_ui "证书同时包含: *.${domain}" \
        "Certificate also includes: *.${domain}"
    [[ "${staging}" -eq 1 ]] && warn_ui \
        "当前使用 Let's Encrypt 测试环境，浏览器不会信任该证书。" \
        "The Let's Encrypt staging environment is active; browsers will not trust this certificate."
}

restore_tuning() {
    local backup_dir="$1"
    if [[ "${backup_dir}" == "latest" ]]; then
        backup_dir="$(find /var/backups/nginx-easy-deploy -maxdepth 1 -type d -name 'tuning-*' 2>/dev/null | sort | tail -n 1)"
    fi
    [[ -n "${backup_dir}" && -f "${backup_dir}/metadata.tsv" ]] \
        || die_ui "找不到有效的调优备份: ${backup_dir:-latest}" \
            "No valid tuning backup was found: ${backup_dir:-latest}"
    [[ "$(metadata_value "${backup_dir}/metadata.tsv" format_version)" == "1" ]] \
        || die_ui "不支持的调优备份格式。" "Unsupported tuning backup format."

    local sysctl_file="/etc/sysctl.d/99-nginx-easy.conf"
    local limits_file="/etc/systemd/system/nginx.service.d/99-nginx-easy-limits.conf"
    local state key value
    state="$(metadata_value "${backup_dir}/metadata.tsv" sysctl_file)"
    if [[ "${state}" == "present" ]]; then
        mkdir -p "$(dirname "${sysctl_file}")"
        cp -a "${backup_dir}/rootfs${sysctl_file}" "${sysctl_file}"
    else
        rm -f "${sysctl_file}"
    fi
    state="$(metadata_value "${backup_dir}/metadata.tsv" limits_file)"
    if [[ "${state}" == "present" ]]; then
        mkdir -p "$(dirname "${limits_file}")"
        cp -a "${backup_dir}/rootfs${limits_file}" "${limits_file}"
    else
        rm -f "${limits_file}"
    fi

    while IFS=$'\t' read -r key value; do
        case "${key}" in
            net.core.somaxconn|net.ipv4.tcp_max_syn_backlog|net.ipv4.tcp_syncookies|fs.file-max|net.core.default_qdisc|net.ipv4.tcp_congestion_control)
                sysctl -w "${key}=${value}" >/dev/null \
                    || warn_ui "无法恢复内核参数: ${key}" "Could not restore kernel parameter: ${key}"
                ;;
        esac
    done < "${backup_dir}/sysctl-original.tsv"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        if command -v nginx >/dev/null 2>&1 && systemctl cat nginx >/dev/null 2>&1; then
            nginx -t
            systemctl restart nginx
        fi
    fi
    log_ui "已恢复调优前设置: ${backup_dir}" "Restored the pre-tuning state: ${backup_dir}"
}

tune_nginx() {
    require_root
    if [[ "${1:-}" == "--restore" ]]; then
        [[ $# -eq 2 ]] || die_ui "用法: ${PROGRAM} tune --restore latest|BACKUP_DIR" \
            "Usage: ${PROGRAM} tune --restore latest|BACKUP_DIR"
        restore_tuning "$2"
        return 0
    fi
    local enable_bbr=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bbr) enable_bbr=1; shift ;;
            *) die_ui "未知调优选项: $1" "Unknown tuning option: $1" ;;
        esac
    done
    require_command sysctl

    local timestamp backup_dir sysctl_file limits_file temp key value
    local somaxconn syn_backlog file_max nofile_limit current_nofile
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="/var/backups/nginx-easy-deploy/tuning-${timestamp}"
    sysctl_file="/etc/sysctl.d/99-nginx-easy.conf"
    limits_file="/etc/systemd/system/nginx.service.d/99-nginx-easy-limits.conf"
    mkdir -p "${backup_dir}/rootfs"
    printf 'format_version\t1\n' > "${backup_dir}/metadata.tsv"
    if [[ -f "${sysctl_file}" ]]; then
        printf 'sysctl_file\tpresent\n' >> "${backup_dir}/metadata.tsv"
        cp -a --parents "${sysctl_file}" "${backup_dir}/rootfs"
    else
        printf 'sysctl_file\tabsent\n' >> "${backup_dir}/metadata.tsv"
    fi
    if [[ -f "${limits_file}" ]]; then
        printf 'limits_file\tpresent\n' >> "${backup_dir}/metadata.tsv"
        cp -a --parents "${limits_file}" "${backup_dir}/rootfs"
    else
        printf 'limits_file\tabsent\n' >> "${backup_dir}/metadata.tsv"
    fi

    : > "${backup_dir}/sysctl-original.tsv"
    for key in net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_syncookies fs.file-max net.core.default_qdisc net.ipv4.tcp_congestion_control; do
        value="$(sysctl -n "${key}" 2>/dev/null || true)"
        [[ -n "${value}" ]] && printf '%s\t%s\n' "${key}" "${value}" >> "${backup_dir}/sysctl-original.tsv"
    done
    chmod -R go-rwx "${backup_dir}"

    somaxconn="$(sysctl -n net.core.somaxconn 2>/dev/null || printf 0)"
    syn_backlog="$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || printf 0)"
    file_max="$(sysctl -n fs.file-max 2>/dev/null || printf 0)"
    [[ "${somaxconn}" =~ ^[0-9]+$ ]] || somaxconn=0
    [[ "${syn_backlog}" =~ ^[0-9]+$ ]] || syn_backlog=0
    [[ "${file_max}" =~ ^[0-9]+$ ]] || file_max=0
    (( somaxconn < 4096 )) && somaxconn=4096
    (( syn_backlog < 4096 )) && syn_backlog=4096
    (( file_max < 262144 )) && file_max=262144
    nofile_limit=65535
    if command -v systemctl >/dev/null 2>&1; then
        current_nofile="$(systemctl show nginx -p LimitNOFILE --value 2>/dev/null || true)"
        if [[ "${current_nofile}" == "infinity" ]]; then
            nofile_limit="infinity"
        elif [[ "${current_nofile}" =~ ^[0-9]+$ ]] \
            && (( current_nofile > nofile_limit )); then
            nofile_limit="${current_nofile}"
        fi
    fi

    temp="$(mktemp /tmp/ngx-easy-sysctl.XXXXXX)"
    {
        printf '%s\n' '# Managed by nginx-easy-deploy. Restore with: tune --restore latest'
        printf 'net.core.somaxconn = %s\n' "${somaxconn}"
        printf 'net.ipv4.tcp_max_syn_backlog = %s\n' "${syn_backlog}"
        printf '%s\n' 'net.ipv4.tcp_syncookies = 1'
        printf 'fs.file-max = %s\n' "${file_max}"
        if [[ "${enable_bbr}" -eq 1 ]] \
            && sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
            printf '%s\n' 'net.core.default_qdisc = fq'
            printf '%s\n' 'net.ipv4.tcp_congestion_control = bbr'
        elif [[ "${enable_bbr}" -eq 1 ]]; then
            warn_ui "当前内核未提供 BBR，跳过 BBR 设置。" \
                "The current kernel does not provide BBR; skipping BBR settings."
        fi
    } > "${temp}"
    install -m 644 "${temp}" "${sysctl_file}"
    rm -f "${temp}"
    if ! sysctl -p "${sysctl_file}"; then
        warn_ui "内核参数应用失败，正在恢复。" \
            "Applying kernel parameters failed; restoring the previous state."
        restore_tuning "${backup_dir}"
        die_ui "调优失败，已恢复原设置。" \
            "Tuning failed and the previous settings were restored."
    fi

    if command -v systemctl >/dev/null 2>&1; then
        mkdir -p "$(dirname "${limits_file}")"
        cat > "${limits_file}" <<EOF
[Service]
LimitNOFILE=${nofile_limit}
EOF
        chmod 644 "${limits_file}"
        systemctl daemon-reload
        if command -v nginx >/dev/null 2>&1 && systemctl cat nginx >/dev/null 2>&1; then
            nginx -t
            if ! systemctl restart nginx; then
                warn_ui "Nginx 重启失败，正在恢复调优前设置。" \
                    "Nginx failed to restart; restoring the pre-tuning state."
                restore_tuning "${backup_dir}"
                die_ui "调优失败，已恢复原设置。" \
                    "Tuning failed and the previous settings were restored."
            fi
        fi
    fi
    log_ui "保守调优已应用，原设置备份在: ${backup_dir}" \
        "Conservative tuning applied. Previous settings: ${backup_dir}"
    warn_ui "脚本未修改 Swap、THP、防火墙或全局用户限制。" \
        "Swap, THP, firewall and global user limits were not modified."
}

update_nginx_package() {
    [[ $# -eq 0 ]] || die_ui "用法: ${PROGRAM} update" "Usage: ${PROGRAM} update"
    require_root
    command -v nginx >/dev/null 2>&1 || die_ui "Nginx 尚未安装。" "Nginx is not installed."
    local timestamp backup
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup="/var/backups/nginx-easy-deploy/update-${timestamp}.tar.gz"
    mkdir -p "$(dirname "${backup}")"
    export_bundle --output "${backup}" --force

    log_ui "正在使用系统软件源更新 Nginx。" \
        "Updating Nginx from the system package repository."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade nginx
    elif command -v dnf >/dev/null 2>&1; then
        dnf upgrade -y nginx
    elif command -v yum >/dev/null 2>&1; then
        yum update -y nginx
    elif command -v apk >/dev/null 2>&1; then
        apk upgrade nginx
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive update nginx
    else
        die_ui "未找到支持的软件包管理器。" "No supported package manager was found."
    fi
    start_nginx
    log_ui "Nginx 更新完成。更新前备份: ${backup}" \
        "Nginx update completed. Pre-update backup: ${backup}"
    warn_ui "配置可从备份恢复；软件包降级需要使用发行版的软件包管理器。" \
        "Configuration can be restored from the archive; package downgrades require the distribution package manager."
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
    read -r -p "$(ui_text "按回车键返回菜单..." "Press Enter to return to the menu...")" _ || true
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
        warn_ui "操作失败，请根据上面的错误信息检查后重试。" \
            "The operation failed. Review the error above and try again."
    fi
    return 0
}

interactive_create_site() {
    local kind="$1" domain target use_ssl email=""
    read -r -p "$(ui_text "域名（例如 app.example.com）: " "Domain (for example app.example.com): ")" domain
    if [[ "${kind}" == "proxy" ]]; then
        read -r -p "$(ui_text "本机服务端口或反代地址 [3000]: " "Local service port or upstream URL [3000]: ")" target
        target="${target:-3000}"
    else
        read -r -p "$(ui_text "静态文件目录 [/var/www/${domain}]: " "Static files directory [/var/www/${domain}]: ")" target
        target="${target:-/var/www/${domain}}"
    fi
    read -r -p "$(ui_text "现在申请 HTTPS？[Y/n]: " "Request HTTPS now? [Y/n]: ")" use_ssl
    if [[ ! "${use_ssl}" =~ ^[Nn]$ ]]; then
        read -r -p "$(ui_text "证书通知邮箱: " "Certificate notification email: ")" email
        run_menu_action create_site "${kind}" "${domain}" "${target}" --email "${email}"
    else
        run_menu_action create_site "${kind}" "${domain}" "${target}" --no-ssl
    fi
}

interactive_export() {
    local output encrypt webroot
    local -a args=()
    read -r -p "$(ui_text "输出文件（留空自动命名）: " "Output file (leave blank for an automatic name): ")" output
    [[ -n "${output}" ]] && args+=(--output "${output}")
    read -r -p "$(ui_text "是否用密码加密迁移包？[Y/n]: " "Encrypt the archive with a passphrase? [Y/n]: ")" encrypt
    [[ ! "${encrypt}" =~ ^[Nn]$ ]] && args+=(--encrypt)
    read -r -p "$(ui_text "是否同时打包静态站点目录？[y/N]: " "Include static site directories? [y/N]: ")" webroot
    [[ "${webroot}" =~ ^[Yy]$ ]] && args+=(--with-webroot)
    run_menu_action export_bundle "${args[@]}"
}

interactive_delete() {
    local domain cert files answer
    local -a args=()
    read -r -p "$(ui_text "要删除的域名: " "Domain to delete: ")" domain
    read -r -p "$(ui_text "同时删除 Certbot 证书？[y/N]: " "Delete its Certbot certificate too? [y/N]: ")" cert
    read -r -p "$(ui_text "备份静态站点文件？[y/N]: " "Back up static site files? [y/N]: ")" files
    read -r -p "$(ui_text "确认删除 ${domain}？输入 yes 继续: " "Delete ${domain}? Type yes to continue: ")" answer
    if [[ "${answer}" != "yes" ]]; then
        log_ui "已取消。" "Cancelled."
        return 0
    fi
    [[ "${cert}" =~ ^[Yy]$ ]] && args+=(--delete-cert)
    [[ "${files}" =~ ^[Yy]$ ]] && args+=(--backup-files)
    run_menu_action delete_site "${domain}" "${args[@]}"
}

interactive_custom_certificate() {
    local domain cert_file key_file chain_file
    read -r -p "$(ui_text "域名: " "Domain: ")" domain
    read -r -p "$(ui_text "证书文件路径（cert.pem 或 fullchain.pem）: " "Certificate path (cert.pem or fullchain.pem): ")" cert_file
    read -r -p "$(ui_text "私钥文件路径（privkey.pem/key.pem）: " "Private key path (privkey.pem/key.pem): ")" key_file
    read -r -p "$(ui_text "单独的证书链路径（没有请留空）: " "Separate chain path (leave blank if none): ")" chain_file
    if [[ -n "${chain_file}" ]]; then
        run_menu_action install_custom_certificate \
            "${domain}" "${cert_file}" "${key_file}" --chain "${chain_file}"
    else
        run_menu_action install_custom_certificate "${domain}" "${cert_file}" "${key_file}"
    fi
}

interactive_cloudflare_dns() {
    local domain email token wildcard staging credentials
    local -a args=()
    read -r -p "$(ui_text "域名: " "Domain: ")" domain
    read -r -p "$(ui_text "证书通知邮箱: " "Certificate notification email: ")" email
    read -r -s -p "$(ui_text "Cloudflare API Token（输入不显示）: " "Cloudflare API Token (input hidden): ")" token
    printf '\n'
    read -r -p "$(ui_text "同时申请 *.${domain} 通配符证书？[y/N]: " "Also request a *.${domain} wildcard certificate? [y/N]: ")" wildcard
    read -r -p "$(ui_text "使用 Let's Encrypt 测试环境？[y/N]: " "Use the Let's Encrypt staging environment? [y/N]: ")" staging
    credentials="$(mktemp /tmp/ngx-easy-cloudflare-token.XXXXXX)"
    printf 'dns_cloudflare_api_token = %s\n' "${token}" > "${credentials}"
    chmod 600 "${credentials}"
    [[ "${wildcard}" =~ ^[Yy]$ ]] && args+=(--wildcard)
    [[ "${staging}" =~ ^[Yy]$ ]] && args+=(--staging)
    run_menu_action enable_cloudflare_dns_https \
        "${domain}" "${email}" "${credentials}" "${args[@]}"
    rm -f "${credentials}"
    token=""
}

interactive_cloudflare_realip() {
    local schedule
    read -r -p "$(ui_text "安装每周自动更新任务？[y/N]: " "Install a weekly automatic update task? [y/N]: ")" schedule
    if [[ "${schedule}" =~ ^[Yy]$ ]]; then
        run_menu_action cloudflare_realip --schedule
    else
        run_menu_action cloudflare_realip
    fi
}

interactive_tune() {
    local answer bbr
    local -a args=()
    log_ui "将设置保守连接队列、文件限制；不会修改 Swap、THP 或防火墙。" \
        "This applies conservative queue and file limits; Swap, THP and firewall settings are untouched."
    read -r -p "$(ui_text "内核支持时同时启用 BBR？[y/N]: " "Enable BBR when supported by the kernel? [y/N]: ")" bbr
    read -r -p "$(ui_text "输入 apply 继续: " "Type apply to continue: ")" answer
    [[ "${answer}" == "apply" ]] || { log_ui "已取消。" "Cancelled."; return 0; }
    [[ "${bbr}" =~ ^[Yy]$ ]] && args+=(--bbr)
    run_menu_action tune_nginx "${args[@]}"
}

interactive_update() {
    local answer
    log_ui "更新前会自动备份 Nginx 配置和证书。" \
        "Nginx configuration and certificates will be backed up before updating."
    read -r -p "$(ui_text "输入 update 继续: " "Type update to continue: ")" answer
    [[ "${answer}" == "update" ]] || { log_ui "已取消。" "Cancelled."; return 0; }
    run_menu_action update_nginx_package
}

interactive_menu() {
    select_ui_language
    require_root
    [[ -t 0 ]] || {
        usage
        return 0
    }

    local choice domain email archive
    while true; do
        command -v clear >/dev/null 2>&1 && clear || true
        if [[ "${UI_LANG}" == "en" ]]; then
            cat <<'EOF'
============================================================
 nginx-easy-deploy - native Nginx deployment and migration
 No panel and no persistent management service
============================================================
  1. Install or repair Nginx + Certbot
  2. Create a reverse proxy site
  3. Create a static website
  4. Enable HTTPS for an existing site
  5. Request a Cloudflare DNS or wildcard certificate
  6. Upload and install a custom certificate
  7. List managed sites
  8. Diagnose the host and a domain
  9. Check local certificate expiry
 10. Refresh Cloudflare real visitor IP configuration
 11. Delete a site with a pre-delete backup
 12. Renew all certificates
 13. Export Nginx configuration and certificates
 14. Restore from a migration archive
 15. Show service status
 16. Apply optional conservative system tuning
 17. Back up and update Nginx
  L. Switch language / 切换语言
  0. Exit
------------------------------------------------------------
EOF
        else
            cat <<'EOF'
============================================================
 nginx-easy-deploy - 原生 Nginx 一键部署与迁移
 不安装面板，不常驻额外服务
============================================================
  1. 安装/修复 Nginx + Certbot
  2. 新建反向代理站点
  3. 新建静态网站
  4. 给已有站点启用 HTTPS
  5. 使用 Cloudflare DNS 申请证书/通配符证书
  6. 上传并安装自有证书
  7. 查看站点
  8. 环境与域名诊断
  9. 检查本机证书到期时间
 10. 更新 Cloudflare 真实访客 IP 配置
 11. 删除站点（删除前自动备份）
 12. 续签全部证书
 13. 导出配置和证书
 14. 从迁移包恢复
 15. 查看运行状态
 16. 可选的保守系统调优
 17. 备份后更新 Nginx
  L. 切换语言 / Switch language
  0. 退出
------------------------------------------------------------
EOF
        fi
        read -r -p "$(ui_text "请选择 [0-17/L]: " "Select [0-17/L]: ")" choice || return 0
        printf '\n'
        case "${choice}" in
            1) run_menu_action install_stack ;;
            2) interactive_create_site proxy ;;
            3) interactive_create_site static ;;
            4)
                read -r -p "$(ui_text "域名: " "Domain: ")" domain
                read -r -p "$(ui_text "证书通知邮箱: " "Certificate notification email: ")" email
                run_menu_action enable_https_domain "${domain}" "${email}"
                ;;
            5) interactive_cloudflare_dns ;;
            6) interactive_custom_certificate ;;
            7) run_menu_action list_sites ;;
            8)
                read -r -p "$(ui_text "要检查 DNS 的域名（可留空）: " "Domain to check in DNS (optional): ")" domain
                run_menu_action doctor "${domain}"
                ;;
            9) run_menu_action check_certificates ;;
            10) interactive_cloudflare_realip ;;
            11) interactive_delete ;;
            12) run_menu_action renew_certificates ;;
            13) interactive_export ;;
            14)
                read -r -p "$(ui_text "迁移包路径: " "Migration archive path: ")" archive
                run_menu_action restore_bundle "${archive}"
                ;;
            15) run_menu_action show_status ;;
            16) interactive_tune ;;
            17) interactive_update ;;
            l|L)
                select_ui_language 1
                continue
                ;;
            0) return 0 ;;
            *) warn_ui "无效选项。" "Invalid choice." ;;
        esac
        pause_menu
    done
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lang)
                [[ $# -ge 2 ]] || die "--lang requires zh or en."
                UI_LANG="$2"
                normalize_ui_language
                shift 2
                ;;
            --lang=*)
                UI_LANG="${1#*=}"
                normalize_ui_language
                shift
                ;;
            *) break ;;
        esac
    done
    [[ -n "${UI_LANG}" ]] && normalize_ui_language
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
            [[ $# -ge 2 ]] || die_ui "用法: ${PROGRAM} ssl DOMAIN EMAIL" \
                "Usage: ${PROGRAM} ssl DOMAIN EMAIL"
            enable_https_domain "$1" "$2"
            ;;
        cert|certificate)
            install_custom_certificate "$@"
            ;;
        dns-ssl|cloudflare-ssl)
            enable_cloudflare_dns_https "$@"
            ;;
        doctor|diagnose)
            doctor "$@"
            ;;
        certs|cert-check)
            check_certificates "$@"
            ;;
        cf-realip|cloudflare-realip)
            cloudflare_realip "$@"
            ;;
        tune)
            tune_nginx "$@"
            ;;
        update)
            update_nginx_package "$@"
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
