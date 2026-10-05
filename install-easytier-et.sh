#!/bin/sh
# =============================================================================
# EasyTier 一键安装脚本（Alpine / Debian 双系列通用）
#
# 功能:
#   1. 自动识别发行版(Alpine/Debian/Ubuntu...)与 CPU 架构
#   2. 自动从 GitHub EasyTier/EasyTier 仓库下载对应架构的最新 release 并解压
#   3. 安装到 /opt/easytier，注册为系统服务「et」并开机自启、崩溃自动重启
#   4. 自动适配 systemd(Debian/Ubuntu) 与 OpenRC(Alpine)
#
# 用法:
#   ./install-easytier-et.sh [install|update|uninstall|status] [-h]
#        [--dir DIR] [--args "..."] [--version vX.Y.Z] [--arch NAME] [--no-service]
#
#   install     安装（默认命令，已安装则覆盖升级）
#   update      更新到最新版（已是最新则跳过；保留配置目录）
#   uninstall  停止服务并删除安装目录
#   status      查看版本、服务状态、进程 PID
#
#   --dir DIR      安装目录，默认 /opt/easytier          [环境变量 ET_INSTALL_DIR]
#   --args "..."   easytier-core 启动参数，
#                  默认: -w tcp://23.94.244.106:22020/admin  [环境变量 ET_ARGS]
#   --version v   指定版本，默认取仓库 latest            [环境变量 ET_VERSION]
#   --arch NAME   强制架构，默认按 uname -m 自动映射      [环境变量 ET_ARCH]
#   --no-service  只装二进制，不注册服务（容器/无 init 场景）
#
# 服务管理:
#   systemd:  systemctl {start|stop|restart|status|disable} et
#   openrc:   rc-service et {start|stop|restart|status}   /   rc-update {add|del} et
#
# 说明: 官方 Linux release 均为 musl 静态编译，Alpine 与 Debian 使用同一个包。
# =============================================================================

set -eu

# -------------------------------- 默认配置 -----------------------------------
INSTALL_DIR="${ET_INSTALL_DIR:-/opt/easytier}"
SERVICE_NAME="et"
ET_ARGS="${ET_ARGS--config-server tcp://easytier.968111.xyz:22020/admin}"
REPO="EasyTier/EasyTier"
LOG_FILE="/var/log/et.log"
ARCH="${ET_ARCH:-}"
VERSION="${ET_VERSION:-}"
NO_SERVICE=0
CMD="install"
INIT_SYSTEM="none"
SRC_ET=""

TMP_ET="$(mktemp -d "${TMPDIR:-/tmp}/easytier-et.XXXXXX")"
trap 'rm -rf "$TMP_ET"' EXIT INT TERM

# -------------------------------- 输出辅助 -----------------------------------
if [ -t 1 ]; then
    C_RED=$(printf '\033[31m'); C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m'); C_BLUE=$(printf '\033[36m'); C_RESET=$(printf '\033[0m')
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_RESET=''
fi
info() { printf '%s[信息]%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf '%s[成功]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[错误]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }
require_root() { [ "$(id -u)" = "0" ] || die "请使用 root 运行（例如: sudo $0）"; }

# -------------------------------- 环境探测 -----------------------------------
detect_init() {
    if need_cmd systemctl && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif need_cmd rc-service && need_cmd rc-update; then
        INIT_SYSTEM="openrc"
    elif need_cmd systemctl; then
        INIT_SYSTEM="systemd"      # 装了 systemd 但未以它启动，后面会降级为后台进程
    else
        INIT_SYSTEM="none"
    fi
    info "init 系统: $INIT_SYSTEM"
}

systemd_booted() { [ -d /run/systemd/system ]; }
openrc_booted()  { [ -d /run/openrc ]; }

detect_arch() {
    if [ -n "$ARCH" ]; then return 0; fi
    m="$(uname -m)"
    hf=""
    if grep -qi 'half' /proc/cpuinfo 2>/dev/null; then hf="hf"; fi
    case "$m" in
        x86_64|amd64)        ARCH="x86_64" ;;
        aarch64|arm64)       ARCH="aarch64" ;;
        armv7*|armv7l)       ARCH="armv7${hf}" ;;
        armv6*|armv6l|arm)   ARCH="arm${hf}" ;;
        riscv64)             ARCH="riscv64" ;;
        loongarch64)         ARCH="loongarch64" ;;
        mipsel|mips64el)     ARCH="mipsel" ;;
        mips|mips64)         ARCH="mips" ;;
        *) die "暂不支持的 CPU 架构: $m（可用 --arch 手动指定: x86_64/aarch64/armv7hf/...）" ;;
    esac
    info "CPU 架构: $ARCH (uname -m = $m)"
}

install_deps() {
    if need_cmd curl && need_cmd unzip; then return 0; fi
    require_root
    info "安装依赖: curl unzip ca-certificates"
    if [ -f /etc/alpine-release ]; then
        apk add --no-cache curl unzip ca-certificates
    elif need_cmd apt-get; then
        apt-get update || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip ca-certificates
    elif need_cmd dnf; then
        dnf install -y curl unzip ca-certificates
    elif need_cmd yum; then
        yum install -y curl unzip ca-certificates
    else
        die "未找到包管理器，请手动安装 curl 与 unzip 后重试"
    fi
    need_cmd curl  || die "curl 安装失败，请手动安装"
    need_cmd unzip || die "unzip 安装失败，请手动安装"
}

get_latest_version() {
    if [ -n "$VERSION" ]; then return 0; fi
    info "查询 GitHub 最新版本 ..."
    resp="$(curl -fsSL --connect-timeout 10 --max-time 30 \
            "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)"
    [ -n "$resp" ] || die "无法访问 GitHub API，请检查网络，或用 --version 手动指定版本"
    VERSION="$(printf '%s\n' "$resp" | grep '"tag_name":' | head -n 1 \
              | sed -e 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
    [ -n "$VERSION" ] || die "解析版本号失败，可用 --version vX.Y.Z 手动指定"
    info "最新版本: $VERSION"
}

# -------------------------------- 下载解压 -----------------------------------
download_and_extract() {
    url="https://github.com/$REPO/releases/download/$VERSION/easytier-linux-$ARCH-$VERSION.zip"
    zip="$TMP_ET/easytier.zip"
    info "下载: $url"
    curl -fL --retry 3 --connect-timeout 15 -o "$zip" "$url" \
        || die "下载失败（架构=$ARCH 版本=$VERSION）。可用 --arch / --version 指定，或稍后重试"
    [ -s "$zip" ] || die "下载文件为空"
    [ "$(head -c 2 "$zip")" = "PK" ] || die "下载文件不是有效 zip（可能被代理污染）"
    mkdir -p "$TMP_ET/x"
    unzip -q -o "$zip" -d "$TMP_ET/x" || die "解压失败"
    SRC_ET="$TMP_ET/x/easytier-linux-$ARCH"
    [ -f "$SRC_ET/easytier-core" ] || die "包内未找到 easytier-core（架构名是否匹配: $ARCH）"
    ok "下载并解压完成"
}

# -------------------------------- 安装 ---------------------------------------
service_unit_path()    { printf '%s' "/etc/systemd/system/$SERVICE_NAME.service"; }
service_openrc_path()  { printf '%s' "/etc/init.d/$SERVICE_NAME"; }

install_binaries() {
    require_root
    if [ -f "$INSTALL_DIR/easytier-core" ]; then
        info "检测到已安装: $("$INSTALL_DIR/easytier-core" --version 2>/dev/null | head -n 1 || echo 未知)"
        service_stop
        if [ -d "$INSTALL_DIR/config" ]; then
            bak="$INSTALL_DIR/config.bak.$(date +%Y%m%d%H%M%S)"
            cp -a "$INSTALL_DIR/config" "$bak"
            info "已备份配置到 $bak"
        fi
    fi
    mkdir -p "$INSTALL_DIR/config"
    cp -f "$SRC_ET/easytier-core" "$INSTALL_DIR/"
    for f in easytier-cli easytier-web easytier-web-embed; do
        if [ -f "$SRC_ET/$f" ]; then cp -f "$SRC_ET/$f" "$INSTALL_DIR/"; fi
    done
    chmod +x "$INSTALL_DIR"/easytier-* 2>/dev/null || true
    ok "已安装到 $INSTALL_DIR"
    info "版本: $("$INSTALL_DIR/easytier-core" --version 2>&1 | head -n 1)"
}

check_tun() {
    if [ ! -c /dev/net/tun ]; then
        warn "未检测到 /dev/net/tun，easytier 可能无法创建虚拟网卡"
        warn "容器运行请加: --cap-add NET_ADMIN --device /dev/net/tun"
    fi
}

# -------------------------------- 服务管理 -----------------------------------
proc_pids() {
    pids=""
    if need_cmd pgrep; then pids="$(pgrep -f 'easytier-core' 2>/dev/null || true)"; fi
    if [ -z "$pids" ]; then
        pids="$(ps -eo pid,args 2>/dev/null | grep '[e]asytier-core' | awk '{print $1}' | tr '\n' ' ')"
    fi
    printf '%s' "$pids"
}

stop_proc() {
    pids="$(proc_pids)"
    [ -n "$pids" ] || return 0
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    i=0
    while [ "$i" -lt 5 ] && [ -n "$(proc_pids)" ]; do sleep 1; i=$((i + 1)); done
    left="$(proc_pids)"
    if [ -n "$left" ]; then
        # shellcheck disable=SC2086
        kill -9 $left 2>/dev/null || true
    fi
    return 0
}

start_proc_bg() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    if need_cmd setsid; then
        setsid "$INSTALL_DIR/easytier-core" $ET_ARGS >>"$LOG_FILE" 2>&1 &
    else
        nohup "$INSTALL_DIR/easytier-core" $ET_ARGS >>"$LOG_FILE" 2>&1 &
    fi
    cat >"$INSTALL_DIR/start-et.sh" <<EOF
#!/bin/sh
# 手动启动脚本（无 systemd / OpenRC 的环境下使用）
exec $INSTALL_DIR/easytier-core $ET_ARGS
EOF
    chmod +x "$INSTALL_DIR/start-et.sh"
    return 0
}

write_systemd_unit() {
    cat >"$(service_unit_path)" <<EOF
[Unit]
Description=et
After=network.target syslog.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/easytier-core $ET_ARGS
Restart=always
RestartSec=15
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF
}

write_openrc_script() {
    cat >"$(service_openrc_path)" <<EOF
#!/sbin/openrc-run
name="et"
description="EasyTier service"

command="$INSTALL_DIR/easytier-core"
command_args="$ET_ARGS"
command_background="yes"

pidfile="/run/$SERVICE_NAME.pid"
output_log="$LOG_FILE"
error_log="$LOG_FILE"

depend() {
    need net
    after net
}
EOF
    chmod +x "$(service_openrc_path)"
}

service_stop() {
    case "$INIT_SYSTEM" in
        systemd) systemctl stop "$SERVICE_NAME" 2>/dev/null || true ;;
        openrc)  rc-service "$SERVICE_NAME" stop 2>/dev/null || true ;;
    esac
    stop_proc
    return 0
}

register_service() {
    if [ "$NO_SERVICE" = "1" ]; then
        info "已跳过服务注册 (--no-service)"
        return 0
    fi
    case "$INIT_SYSTEM" in
        systemd)
            write_systemd_unit
            if systemd_booted; then
                systemctl daemon-reload
                systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 \
                    || warn "systemctl enable 失败（开机自启可能未生效）"
                systemctl restart "$SERVICE_NAME" \
                    || die "服务启动失败，请查看日志: journalctl -u $SERVICE_NAME -n 30"
            else
                warn "systemd 未作为 PID1 运行，改用后台进程启动（未实现开机自启）"
                start_proc_bg
            fi
            ;;
        openrc)
            write_openrc_script
            if openrc_booted; then
                rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 \
                    || warn "rc-update add 失败（开机自启可能未生效）"
                rc-service "$SERVICE_NAME" restart 2>/dev/null \
                    || rc-service "$SERVICE_NAME" start \
                    || die "OpenRC 服务启动失败，请查看日志: tail -n 30 $LOG_FILE"
            else
                warn "OpenRC 未作为 PID1 运行（容器场景），改用后台进程启动（未实现开机自启）"
                start_proc_bg
            fi
            ;;
        *)
            warn "未检测到 systemd 或 OpenRC，仅以后台进程方式启动（未实现开机自启）"
            start_proc_bg
            ;;
    esac
}

verify_running() {
    if [ "$NO_SERVICE" = "1" ]; then return 0; fi
    i=0
    while [ "$i" -lt 10 ]; do
        if [ -n "$(proc_pids)" ]; then return 0; fi
        sleep 1
        i=$((i + 1))
    done
    err "easytier-core 进程未存活，最近的日志如下:"
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        journalctl -u "$SERVICE_NAME" --no-pager -n 30 2>/dev/null || true
    fi
    if [ -f "$LOG_FILE" ]; then tail -n 30 "$LOG_FILE" || true; fi
    return 1
}

print_summary() {
    echo
    ok "EasyTier 部署完成"
    printf '  版本:     %s\n' "$VERSION"
    printf '  目录:     %s\n' "$INSTALL_DIR"
    printf '  启动参数: %s\n' "$ET_ARGS"
    printf '  日志:     %s\n' "$LOG_FILE"
    if [ "$INIT_SYSTEM" = "systemd" ] && systemd_booted; then
        printf '  服务管理: systemctl {start|stop|restart|status} %s（已 enable，开机自启）\n' "$SERVICE_NAME"
        printf '  查看日志: journalctl -u %s -n 30 --no-pager\n' "$SERVICE_NAME"
    elif [ "$INIT_SYSTEM" = "openrc" ] && openrc_booted; then
        printf '  服务管理: rc-service %s {start|stop|restart|status}（已加入 default，开机自启）\n' "$SERVICE_NAME"
        printf '  查看日志: tail -n 30 %s\n' "$LOG_FILE"
    else
        printf '  启动脚本: %s\n' "$INSTALL_DIR/start-et.sh"
    fi
    printf '  进程检查: ps -ef | grep easytier-core\n'
    echo
    warn "若启动参数中的域名在本机无法解析，进程会秒退；可改用 IP:"
    warn "   sudo $0 install --args \"-w tcp://<服务器IP>:22020/admin\""
}

# -------------------------------- 子命令 -------------------------------------
cmd_status() {
    detect_init
    printf '安装目录: %s\n' "$INSTALL_DIR"
    printf 'init:     %s\n' "$INIT_SYSTEM"
    printf '启动参数: %s\n' "$ET_ARGS"
    if [ -f "$INSTALL_DIR/easytier-core" ]; then
        printf '版本:     %s\n' "$("$INSTALL_DIR/easytier-core" --version 2>&1 | head -n 1)"
    else
        printf '版本:     未安装\n'
    fi
    if [ "$INIT_SYSTEM" = "systemd" ] && systemd_booted; then
        printf '开机自启: %s\n' "$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo unknown)"
        printf '运行状态: %s\n' "$(systemctl is-active  "$SERVICE_NAME" 2>/dev/null || echo inactive)"
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        if rc-update show 2>/dev/null | grep -q "$SERVICE_NAME"; then
            printf '开机自启: 已加入 default\n'
        else
            printf '开机自启: 未加入\n'
        fi
        printf '运行状态: %s\n' "$(rc-service "$SERVICE_NAME" status 2>&1 | head -n 1 || true)"
    fi
    pids="$(proc_pids)"
    if [ -n "$pids" ]; then printf '进程 PID: %s\n' "$pids"; else printf '进程:     未运行\n'; fi
    ps -eo pid,args 2>/dev/null | grep '[e]asytier-core' || true
}

cmd_uninstall() {
    require_root
    detect_init
    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
            rm -f "$(service_unit_path)"
            if systemd_booted; then systemctl daemon-reload; fi
            ;;
        openrc)
            rc-service "$SERVICE_NAME" stop 2>/dev/null || true
            rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
            rm -f "$(service_openrc_path)"
            ;;
    esac
    stop_proc
    if [ -d "$INSTALL_DIR" ]; then
        if ls "$INSTALL_DIR"/easytier-* >/dev/null 2>&1; then
            rm -rf "$INSTALL_DIR"
            ok "已删除 $INSTALL_DIR"
        else
            warn "$INSTALL_DIR 中未发现 easytier 文件，未删除该目录"
        fi
    fi
    rm -f "$LOG_FILE"
    ok "卸载完成"
}

cmd_install() {
    install_deps
    detect_init
    detect_arch
    get_latest_version
    download_and_extract
    install_binaries
    check_tun
    register_service
    verify_running || die "启动验证失败，请根据上面的日志排查"
    print_summary
}

cmd_update() {
    require_root
    get_latest_version
    if [ -f "$INSTALL_DIR/easytier-core" ]; then
        cur="$("$INSTALL_DIR/easytier-core" --version 2>/dev/null \
               | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | head -n 1 || true)"
        if [ -n "$cur" ] && [ "$cur" = "${VERSION#v}" ]; then
            ok "已是最新版本 $VERSION（如需强制重装请执行: $0 install）"
            exit 0
        fi
    fi
    install_deps
    detect_init
    detect_arch
    download_and_extract
    install_binaries
    check_tun
    register_service
    verify_running || die "更新后启动验证失败，请根据上面的日志排查"
    print_summary
}

# -------------------------------- 参数解析 -----------------------------------
usage() {
    sed -n '3,32p' "$0" | sed -e 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        install|update|uninstall|status) CMD="$1" ;;
        help|-h|--help) CMD="help" ;;
        --no-service)   NO_SERVICE=1 ;;
        --dir)          [ $# -ge 2 ] || die "--dir 需要参数"; INSTALL_DIR="$2"; shift ;;
        --dir=*)        INSTALL_DIR="${1#*=}" ;;
        --args|-a)      [ $# -ge 2 ] || die "--args 需要参数"; ET_ARGS="$2"; shift ;;
        --args=*)       ET_ARGS="${1#*=}" ;;
        --version)      [ $# -ge 2 ] || die "--version 需要参数"; VERSION="$2"; shift ;;
        --version=*)    VERSION="${1#*=}" ;;
        --arch)         [ $# -ge 2 ] || die "--arch 需要参数"; ARCH="$2"; shift ;;
        --arch=*)       ARCH="${1#*=}" ;;
        *) die "未知参数: $1（可用 -h 查看帮助）" ;;
    esac
    shift
done

[ -n "$INSTALL_DIR" ] || die "安装目录不能为空"
[ "$INSTALL_DIR" != "/" ] || die "安装目录不能是 /"
[ -d "$INSTALL_DIR" ] || INSTALL_DIR="${INSTALL_DIR%/}"

case "$CMD" in
    install)   cmd_install ;;
    update)    cmd_update ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    help)      usage ;;
    *)         die "未知命令: $CMD" ;;
esac
