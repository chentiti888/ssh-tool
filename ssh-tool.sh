#!/bin/bash
# =============================================================
#  SSH 小工具：修改 SSH 端口 / 生成密钥并下载
#  用法：bash ssh-tool.sh
# =============================================================

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; NC='\033[0m'
SSHD_CONF="/etc/ssh/sshd_config"
KEY_DIR="/root/.ssh/keys"

info() { echo -e "${GREEN}[√]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[×]${NC} $*"; }

[[ $EUID -ne 0 ]] && { err "请使用 root 运行"; exit 1; }

# ---------------- 快捷命令（想改名就改这里） ----------------
CMD_NAME="ss"
CMD_PATH="/usr/local/bin/${CMD_NAME}"

# 脚本在 GitHub 仓库里的 raw 地址（上传仓库后按实际仓库名修改）
SCRIPT_URL="https://raw.githubusercontent.com/chentiti888/ssh-tool/main/ssh-tool.sh"

install_shortcut() {
    local self
    self=$(readlink -f "$0" 2>/dev/null)
    [[ "$self" == "$CMD_PATH" ]] && return
    if [[ -f "$self" ]]; then
        # 本地文件运行：直接复制
        cp -f "$self" "$CMD_PATH" 2>/dev/null
    else
        # 通过 bash <(curl ...) 运行：从仓库重新下载一份
        curl -fsSL --retry 3 --connect-timeout 10 --max-time 40 "$SCRIPT_URL" -o "$CMD_PATH"
    fi
    if [[ -s "$CMD_PATH" ]] && head -1 "$CMD_PATH" | grep -q '^#!'; then
        chmod +x "$CMD_PATH"
        info "已安装快捷命令：以后直接输入 ${CMD_NAME} 即可打开本菜单"
    else
        rm -f "$CMD_PATH"
        warn "快捷命令安装失败：无法从 ${SCRIPT_URL} 下载脚本，请检查网络或 SCRIPT_URL"
        warn "可手动安装：curl -fsSL ${SCRIPT_URL} -o ${CMD_PATH} && chmod +x ${CMD_PATH}"
        sleep 3
    fi
}
install_shortcut

get_ip() {
    curl -s4 --max-time 5 ip.sb 2>/dev/null || curl -s4 --max-time 5 ifconfig.me 2>/dev/null || echo "服务器IP"
}

current_port() {
    local p
    p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    echo "${p:-22}"
}

restart_sshd() {
    # Ubuntu 22.10+ 默认 socket 激活，会无视 sshd_config 里的 Port
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        warn "检测到 ssh.socket，改为直接由 ssh 服务监听"
        systemctl disable --now ssh.socket >/dev/null 2>&1
        systemctl enable ssh >/dev/null 2>&1
    fi
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
}

open_firewall() {
    local port=$1
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null && info "ufw 已放行 ${port}/tcp"
    fi
    if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
        firewall-cmd --reload >/dev/null && info "firewalld 已放行 ${port}/tcp"
    fi
    if command -v iptables >/dev/null && ! command -v ufw >/dev/null && ! command -v firewall-cmd >/dev/null; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
            || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        info "iptables 已放行 ${port}/tcp（重启后可能失效，请自行持久化）"
    fi
    if command -v semanage >/dev/null && command -v getenforce >/dev/null \
        && [[ $(getenforce) == "Enforcing" ]]; then
        semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null \
            || semanage port -m -t ssh_port_t -p tcp "$port" 2>/dev/null
    fi
}

# ---------------- 1. 修改端口 ----------------
change_port() {
    local old new
    old=$(current_port)
    echo -e "当前 SSH 端口：${CYAN}${old}${NC}"
    read -rp "请输入新端口 (1-65535，回车取消): " new
    [[ -z "$new" ]] && return
    if ! [[ "$new" =~ ^[0-9]+$ ]] || ((new < 1 || new > 65535)); then
        err "端口无效"; return
    fi
    if [[ "$new" == "$old" ]]; then
        warn "与当前端口相同，无需修改"; return
    fi
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${new}$"; then
        err "端口 ${new} 已被占用"; return
    fi

    cp -a "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    info "已备份 sshd_config"

    # 注释掉主配置和 drop-in 里已有的 Port 行，再写入新端口
    sed -i -E 's/^[[:space:]]*Port[[:space:]]+/#Port /' "$SSHD_CONF"
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$f" ]] && sed -i -E 's/^[[:space:]]*Port[[:space:]]+/#Port /' "$f"
    done
    # 放在文件最前面，避免被 Match 块吞掉
    sed -i "1i Port ${new}" "$SSHD_CONF"

    if ! sshd -t 2>/tmp/sshd_err; then
        err "sshd 配置校验失败，已回滚："; cat /tmp/sshd_err
        cp -a "$(ls -t ${SSHD_CONF}.bak.* | head -1)" "$SSHD_CONF"
        return
    fi

    open_firewall "$new"
    restart_sshd
    sleep 1

    if ss -tln | awk '{print $4}' | grep -qE "[:.]${new}$"; then
        info "SSH 已监听新端口 ${new}"
        warn "请【不要关闭当前窗口】，先新开终端测试：ssh -p ${new} root@$(get_ip)"
        warn "云服务器还需要在【安全组/防火墙】里放行 ${new}/tcp，确认能登录后再关闭旧端口 ${old}"
    else
        err "新端口未监听，请检查：systemctl status sshd"
    fi
}

# ---------------- 2. 生成密钥 ----------------
gen_key() {
    local name type pass keyfile
    read -rp "密钥名称 (默认 id_$(hostname)): " name
    name=${name:-id_$(hostname)}
    name=${name//[^a-zA-Z0-9._-]/_}
    echo "密钥类型： 1) ed25519 (推荐)   2) rsa 4096"
    read -rp "请选择 [1]: " type
    read -rsp "私钥密码 (可留空): " pass; echo

    mkdir -p "$KEY_DIR"; chmod 700 "$KEY_DIR"
    keyfile="${KEY_DIR}/${name}"
    if [[ -e "$keyfile" ]]; then
        read -rp "${keyfile} 已存在，覆盖？[y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || return
        rm -f "$keyfile" "${keyfile}.pub"
    fi

    if [[ "$type" == "2" ]]; then
        ssh-keygen -t rsa -b 4096 -f "$keyfile" -N "$pass" -C "$name" -q
    else
        ssh-keygen -t ed25519 -f "$keyfile" -N "$pass" -C "$name" -q
    fi
    [[ -f "$keyfile" ]] || { err "生成失败"; return; }
    chmod 600 "$keyfile"
    info "密钥已生成：${keyfile}"

    # 公钥写入 authorized_keys
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
    if ! grep -qF "$(cut -d' ' -f2 "${keyfile}.pub")" /root/.ssh/authorized_keys; then
        cat "${keyfile}.pub" >> /root/.ssh/authorized_keys
        info "公钥已加入 /root/.ssh/authorized_keys"
    fi

    LAST_KEY="$keyfile"
    echo
    read -rp "现在下载这个私钥吗？[Y/n]: " yn
    [[ "$yn" =~ ^[Nn]$ ]] || download_key "$keyfile"
}

# ---------------- 3. 下载密钥 ----------------
list_keys() {
    ls "$KEY_DIR" 2>/dev/null | grep -v '\.pub$'
}

download_key() {
    local keyfile=$1
    if [[ -z "$keyfile" ]]; then
        local keys; mapfile -t keys < <(list_keys)
        if ((${#keys[@]} == 0)); then err "还没有生成过密钥"; return; fi
        local i=1
        for k in "${keys[@]}"; do echo "  $i) $k"; ((i++)); done
        read -rp "选择要下载的密钥编号: " n
        [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#keys[@]})) || { err "无效选择"; return; }
        keyfile="${KEY_DIR}/${keys[$((n-1))]}"
    fi
    local ip port
    ip=$(get_ip)
    port=$(current_port)

    echo
    echo "下载方式："
    echo "  1) 直接显示私钥内容（复制保存为文件，最安全）"
    echo "  2) 临时 HTTP 链接下载（一次性，120 秒后自动关闭，明文传输有风险）"
    echo "  3) 显示 scp 命令（在你本地电脑执行）"
    read -rp "请选择 [1]: " m
    case "$m" in
    2)
        command -v python3 >/dev/null || { err "需要 python3"; return; }
        local dport token tmp
        dport=$((RANDOM % 10000 + 40000))
        token=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
        tmp=$(mktemp -d)
        cp "$keyfile" "${tmp}/${token}"
        open_firewall "$dport"
        warn "私钥将通过明文 HTTP 传输，下载完成后建议删除并重新生成"
        echo -e "下载链接：${CYAN}http://${ip}:${dport}/${token}${NC}"
        echo "（云服务器需在安全组临时放行 ${dport}/tcp；等待下载中，Ctrl+C 取消）"
        python3 - "$tmp" "$dport" "$token" <<'PY'
import http.server, sys, os, threading
d, port, token = sys.argv[1], int(sys.argv[2]), sys.argv[3]
os.chdir(d)
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.strip('/') != token:
            self.send_error(404); return
        super().do_GET()
        threading.Thread(target=self.server.shutdown, daemon=True).start()
    def log_message(self, *a): pass
s = http.server.HTTPServer(('0.0.0.0', port), H)
threading.Timer(120, s.shutdown).start()
s.serve_forever()
PY
        rm -rf "$tmp"
        command -v ufw >/dev/null && ufw delete allow "${dport}/tcp" >/dev/null 2>&1
        command -v firewall-cmd >/dev/null && { firewall-cmd --permanent --remove-port="${dport}/tcp" >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; }
        iptables -D INPUT -p tcp --dport "$dport" -j ACCEPT 2>/dev/null
        info "临时下载服务已关闭"
        ;;
    3)
        echo -e "在本地电脑执行：\n${CYAN}scp -P ${port} root@${ip}:${keyfile} ./${keyfile##*/}${NC}"
        ;;
    *)
        echo -e "${YELLOW}↓↓↓ 复制下面全部内容保存为文件（含 BEGIN/END 行）↓↓↓${NC}"
        cat "$keyfile"
        echo -e "${YELLOW}↑↑↑ 结束 ↑↑↑${NC}"
        echo "本地保存后执行：chmod 600 文件名 ；登录：ssh -i 文件名 -p ${port} root@${ip}"
        ;;
    esac
}

# ---------------- 4. 禁用密码登录 ----------------
disable_password() {
    if ! [[ -s /root/.ssh/authorized_keys ]]; then
        err "authorized_keys 为空，禁用密码登录会把你锁在外面！请先生成密钥"; return
    fi
    warn "请确认你已经用密钥成功登录测试过！"
    read -rp "确定禁用密码登录？[y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || return
    cp -a "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONF"
    grep -q '^PasswordAuthentication' "$SSHD_CONF" || echo "PasswordAuthentication no" >> "$SSHD_CONF"
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$f" ]] && sed -i -E 's/^[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' "$f"
    done
    if sshd -t; then restart_sshd; info "已禁用密码登录"; else err "配置校验失败，未生效"; fi
}

# ---------------- 菜单 ----------------
while true; do
    echo
    echo -e "${CYAN}========== SSH 小工具 ==========${NC}"
    echo -e " 当前 SSH 端口：${GREEN}$(current_port)${NC}"
    echo " 1) 修改 SSH 端口"
    echo " 2) 生成密钥（自动加入 authorized_keys）"
    echo " 3) 下载已有密钥"
    echo " 4) 禁用密码登录（仅密钥登录）"
    echo " 0) 退出"
    read -rp "请选择: " c
    case "$c" in
        1) change_port ;;
        2) gen_key ;;
        3) download_key "" ;;
        4) disable_password ;;
        0) exit 0 ;;
        *) err "无效选择" ;;
    esac
done
