#!/usr/bin/env bash

set -Eeuo pipefail

CERT_DIR="/etc/V2bX"
KEY_FILE="${CERT_DIR}/cert.key"
CERT_FILE="${CERT_DIR}/fullchain.cer"

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

error() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
    error "请使用 root 用户运行此脚本，例如：sudo bash $0"
fi

if [[ ! -d "${CERT_DIR}" ]]; then
    error "目录不存在：${CERT_DIR}"
fi

if [[ ! -r /etc/os-release ]]; then
    error "无法读取 /etc/os-release，无法判断系统类型"
fi

# shellcheck disable=SC1091
source /etc/os-release

OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"

log "检测到系统：${PRETTY_NAME:-${OS_ID}}"

install_openssl() {
    log "正在安装 OpenSSL..."

    case "${OS_ID}" in
        debian|ubuntu|linuxmint|kali)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y openssl
            ;;

        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y openssl
            elif command -v yum >/dev/null 2>&1; then
                yum install -y openssl
            else
                error "未找到 dnf 或 yum，无法安装 OpenSSL"
            fi
            ;;

        alpine)
            apk add --no-cache openssl
            ;;

        *)
            if [[ "${OS_LIKE}" == *debian* ]] && command -v apt-get >/dev/null 2>&1; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update
                apt-get install -y openssl
            elif [[ "${OS_LIKE}" == *rhel* ]] || [[ "${OS_LIKE}" == *fedora* ]]; then
                if command -v dnf >/dev/null 2>&1; then
                    dnf install -y openssl
                elif command -v yum >/dev/null 2>&1; then
                    yum install -y openssl
                else
                    error "未找到可用的软件包管理器"
                fi
            else
                error "暂不支持当前系统：${OS_ID}"
            fi
            ;;
    esac
}

if command -v openssl >/dev/null 2>&1; then
    log "OpenSSL 已安装：$(openssl version)"
else
    warn "未检测到 OpenSSL"
    install_openssl

    if ! command -v openssl >/dev/null 2>&1; then
        error "OpenSSL 安装失败"
    fi

    log "OpenSSL 安装成功：$(openssl version)"
fi

if ! command -v v2bx >/dev/null 2>&1; then
    error "未找到 v2bx 命令，请确认 V2bX 已正确安装"
fi

# 生成 100000~999999 之间的随机六位数字
RANDOM_NUMBER="$(
    od -An -N4 -tu4 /dev/urandom |
    tr -d ' ' |
    awk '{ printf "%d", ($1 % 900000) + 100000 }'
)"

SNI_DOMAIN="${RANDOM_NUMBER}.com"

log "随机生成的 SNI：${SNI_DOMAIN}"

# 防止生成过程中产生过于宽松的文件权限
umask 077

# 备份原有证书文件
if [[ -e "${KEY_FILE}" ]]; then
    mv -f "${KEY_FILE}" "${KEY_FILE}.back"
    log "已备份：${KEY_FILE} -> ${KEY_FILE}.back"
else
    warn "不存在原私钥文件，跳过备份：${KEY_FILE}"
fi

if [[ -e "${CERT_FILE}" ]]; then
    mv -f "${CERT_FILE}" "${CERT_FILE}.back"
    log "已备份：${CERT_FILE} -> ${CERT_FILE}.back"
else
    warn "不存在原证书文件，跳过备份：${CERT_FILE}"
fi

# 使用临时 OpenSSL 配置文件，兼容较老版本的 OpenSSL
OPENSSL_CONFIG="$(mktemp)"

cleanup() {
    rm -f "${OPENSSL_CONFIG}"
}

trap cleanup EXIT

cat > "${OPENSSL_CONFIG}" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = ${SNI_DOMAIN}

[v3_req]
subjectAltName = DNS:${SNI_DOMAIN}
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
EOF

log "正在生成 10 年有效期的自签名证书..."

openssl req \
    -x509 \
    -nodes \
    -newkey rsa:2048 \
    -keyout "${KEY_FILE}" \
    -out "${CERT_FILE}" \
    -days 3650 \
    -config "${OPENSSL_CONFIG}"

chmod 600 "${KEY_FILE}"
chmod 644 "${CERT_FILE}"

log "私钥已生成：${KEY_FILE}"
log "证书已生成：${CERT_FILE}"
log "证书有效期：3650 天"
log "证书 SNI：${SNI_DOMAIN}"

log "正在执行：v2bx restart"

RESTART_OUTPUT=""
if RESTART_OUTPUT="$(v2bx restart 2>&1)"; then
    RESTART_STATUS=0
else
    RESTART_STATUS=$?
fi

printf '\n========== v2bx restart 输出 ==========\n'
printf '%s\n' "${RESTART_OUTPUT}"
printf '========================================\n'

if [[ "${RESTART_STATUS}" -eq 0 ]]; then
    printf '\n[RESULT] V2bX 重启成功\n'
    printf '[RESULT] SNI：%s\n' "${SNI_DOMAIN}"
    printf '[RESULT] 证书文件：%s\n' "${CERT_FILE}"
    printf '[RESULT] 私钥文件：%s\n' "${KEY_FILE}"
else
    printf '\n[RESULT] V2bX 重启失败，退出码：%s\n' "${RESTART_STATUS}"
    exit "${RESTART_STATUS}"
fi
