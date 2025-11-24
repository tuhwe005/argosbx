#!/bin/sh
export LANG=en_US.UTF-8

# ==================================================
# 1. 变量处理与默认值
# ==================================================

# 1.1 变量映射 (将外部传入的短变量映射到脚本内部变量)
# agk -> ARGO_AUTH (Token)
if [ -n "$agk" ]; then export ARGO_AUTH="$agk"; fi
# agn -> ARGO_DOMAIN (域名)
if [ -n "$agn" ]; then export ARGO_DOMAIN="$agn"; fi
# vmpt -> port_vm_ws (端口)
if [ -n "$vmpt" ]; then export port_vm_ws="$vmpt"; fi

# 1.2 默认值设置
export uuid=${uuid:-''}
export port_vm_ws=${port_vm_ws:-8001}  # 默认端口改为 8001
export argo_enable=${argo:-'y'}        # 默认开启 Argo 隧道模式

# 1.3 检查 Argo 必要参数
# 因为默认开启 argo=y，所以必须检查 Token 和 域名
if [ "$argo_enable" = "y" ]; then
    if [ -z "$ARGO_AUTH" ] || [ -z "$ARGO_DOMAIN" ]; then
        echo "❌ 错误：Argo 模式默认开启，必须提供 agk (Token) 和 agn (域名)！"
        echo "示例：agk='ey...' agn='vps.example.com' bash script.sh"
        exit 1
    fi
fi

# ==================================================
# 2. 系统环境准备
# ==================================================
echo "⚙️ 正在初始化环境..."

# 2.1 架构检测
hostname=$(uname -a | awk '{print $2}')
arch=$(uname -m)
case $arch in
    x86_64) cpu="64";;
    aarch64) cpu="arm64-v8a";;
    *) echo "❌ 不支持当前架构: $arch" && exit 1 ;;
esac

# 2.2 安装基础依赖
if [ -f /etc/alpine-release ]; then
    apk add --no-cache curl wget unzip tar ca-certificates >/dev/null 2>&1
elif [ -f /etc/debian_version ]; then
    apt-get update >/dev/null 2>&1 && apt-get install -y curl wget unzip tar ca-certificates >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget unzip tar ca-certificates >/dev/null 2>&1
fi

# 2.3 清理防火墙 (注意：这会清空所有规则)
setenforce 0 >/dev/null 2>&1
iptables -P INPUT ACCEPT >/dev/null 2>&1
iptables -F >/dev/null 2>&1

mkdir -p "$HOME/agsbx"
mkdir -p "$HOME/bin"

# 2.4 生成 UUID (如果没填)
if [ -z "$uuid" ] && [ ! -e "$HOME/agsbx/uuid" ]; then
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "eac8c09c-8409-4c63-a56b-187ce1f7b048")
    echo "$uuid" > "$HOME/agsbx/uuid"
elif [ -n "$uuid" ]; then
    echo "$uuid" > "$HOME/agsbx/uuid"
fi
uuid=$(cat "$HOME/agsbx/uuid")

# ==================================================
# 3. 安装 Xray (官方版本 XTLS/Xray-core)
# ==================================================
installxray(){
    echo "📥 安装 Xray 官方内核 (XTLS/Xray-core)..."
    
    if [ ! -e "$HOME/agsbx/xray" ]; then
        # 获取最新版本号
        tag_version=$(wget -qO- -t1 -T2 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' | sed 's/\"//g;s/,//g;s/ //g')
        if [ -z "$tag_version" ]; then tag_version="v1.8.24"; fi 
        
        echo "   检测到最新版本: $tag_version"
        url="https://github.com/XTLS/Xray-core/releases/download/${tag_version}/Xray-linux-${cpu}.zip"
        
        # --- 修改点：增加下载校验 ---
        wget -qO "$HOME/agsbx/xray.zip" "$url"
        if [ $? -ne 0 ]; then
            echo "❌ 下载 Xray 失败，请检查网络！(URL: $url)"
            exit 1
        fi
        # --------------------------

        # 解压并保留二进制文件
        unzip -q -o "$HOME/agsbx/xray.zip" -d "$HOME/agsbx/"
        rm -f "$HOME/agsbx/xray.zip" "$HOME/agsbx/geoip.dat" "$HOME/agsbx/geosite.dat"
        chmod +x "$HOME/agsbx/xray"
    fi

    # 写入配置 (仅 VMess)
    echo "🔨 配置 VMess (端口: $port_vm_ws)..."
    cat > "$HOME/agsbx/xr.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
        "tag": "vmess-xr",
        "listen": "127.0.0.1",
        "port": ${port_vm_ws},
        "protocol": "vmess",
        "settings": { "clients": [ { "id": "${uuid}" } ] },
        "streamSettings": { "network": "ws", "wsSettings": { "path": "/${uuid}-vm" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
}

# ==================================================
# 4. 安装 Cloudflared
# ==================================================
install_argo(){
    if [ "$argo_enable" != "y" ]; then return; fi

    echo "📥 安装 Cloudflared..."
    if [ ! -e "$HOME/agsbx/cloudflared" ]; then
        if [ "$cpu" = "64" ]; then 
            cf_arch="amd64"
        else 
            cf_arch="arm64"
        fi
        
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cf_arch"
        out="$HOME/agsbx/cloudflared"
        
        # 同样增加下载校验
        (command -v curl >/dev/null 2>&1 && curl -Lo "$out" -# --retry 2 "$url") || (command -v wget>/dev/null 2>&1 && timeout 10 wget -O "$out" --tries=2 "$url")
        
        if [ ! -f "$out" ]; then
             echo "❌ 下载 Cloudflared 失败，请检查网络！"
             exit 1
        fi
        chmod +x "$HOME/agsbx/cloudflared"
    fi
}

# ==================================================
# 5. 服务配置与保活 (Systemd/OpenRC/Crontab)
# ==================================================
setup_services(){
    echo "🛡️ 配置保活机制..."

    # --- Systemd (主流 VPS) ---
    if pidof systemd >/dev/null 2>&1 && [ "$EUID" -eq 0 ]; then
        # Xray 服务
        cat > /etc/systemd/system/xr.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=$HOME/agsbx/xray run -c $HOME/agsbx/xr.json
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable xr >/dev/null 2>&1
        systemctl restart xr >/dev/null 2>&1
        
        # Argo 服务
        if [ "$argo_enable" = "y" ]; then
            cat > /etc/systemd/system/argo.service <<EOF
[Unit]
Description=Argo Tunnel
After=network.target
[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=$HOME/agsbx/cloudflared tunnel --no-autoupdate run --token ${ARGO_AUTH}
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
            systemctl enable argo >/dev/null 2>&1
            systemctl restart argo >/dev/null 2>&1
        fi

    # --- OpenRC (Alpine) ---
    elif command -v rc-service >/dev/null 2>&1 && [ "$EUID" -eq 0 ]; then
        # Xray 服务
        cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service"
command="$HOME/agsbx/xray"
command_args="run -c $HOME/agsbx/xr.json"
command_background=yes
pidfile="/run/xray.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/xray
        rc-update add xray default >/dev/null 2>&1
        rc-service xray restart >/dev/null 2>&1

        # Argo 服务
        if [ "$argo_enable" = "y" ]; then
            cat > /etc/init.d/argo <<EOF
#!/sbin/openrc-run
description="Argo Tunnel"
command="$HOME/agsbx/cloudflared"
command_args="tunnel --no-autoupdate run --token ${ARGO_AUTH}"
command_background=yes
pidfile="/run/argo.pid"
depend() { need net; }
EOF
            chmod +x /etc/init.d/argo
            rc-update add argo default >/dev/null 2>&1
            rc-service argo restart >/dev/null 2>&1
        fi

    # --- Nohup + Crontab (容器/无服务管理) ---
    else
        pkill -f "$HOME/agsbx/xray"
        nohup "$HOME/agsbx/xray" run -c "$HOME/agsbx/xr.json" >/dev/null 2>&1 &
        
        if [ "$argo_enable" = "y" ]; then
            pkill -f "$HOME/agsbx/cloudflared"
            nohup "$HOME/agsbx/cloudflared" tunnel --no-autoupdate run --token "${ARGO_AUTH}" >/dev/null 2>&1 &
        fi
        
        # 写入 Crontab
        crontab -l > /tmp/crontab.tmp 2>/dev/null
        sed -i '/agsbx/d' /tmp/crontab.tmp
        echo "@reboot sleep 10 && /bin/sh -c \"nohup $HOME/agsbx/xray run -c $HOME/agsbx/xr.json >/dev/null 2>&1 &\"" >> /tmp/crontab.tmp
        echo "*/1 * * * * pgrep -f 'agsbx/xray' >/dev/null || nohup $HOME/agsbx/xray run -c $HOME/agsbx/xr.json >/dev/null 2>&1 &" >> /tmp/crontab.tmp
        
        if [ "$argo_enable" = "y" ]; then
             echo "@reboot sleep 10 && /bin/sh -c \"nohup $HOME/agsbx/cloudflared tunnel --no-autoupdate run --token ${ARGO_AUTH} >/dev/null 2>&1 &\"" >> /tmp/crontab.tmp
             echo "*/1 * * * * pgrep -f 'cloudflared' >/dev/null || nohup $HOME/agsbx/cloudflared tunnel --no-autoupdate run --token ${ARGO_AUTH} >/dev/null 2>&1 &" >> /tmp/crontab.tmp
        fi
        
        crontab /tmp/crontab.tmp
        rm /tmp/crontab.tmp
    fi
}

# ==================================================
# 6. 持久化
# ==================================================
persist_env(){
    SCRIPT_PATH="$HOME/bin/agsbx"
    cat > "$SCRIPT_PATH" <<EOF
#!/bin/sh
if [ "\$1" = "list" ]; then cat "$HOME/agsbx/jh.txt"; fi
if [ "\$1" = "del" ]; then 
  systemctl stop xr argo 2>/dev/null
  rc-service xray stop 2>/dev/null
  rc-service argo stop 2>/dev/null
  rm -rf "$HOME/agsbx" /etc/systemd/system/xr.service /etc/systemd/system/argo.service
  crontab -l | grep -v 'agsbx' | crontab -
  echo "卸载完成"
fi
EOF
    chmod +x "$SCRIPT_PATH"
    if ! grep -q "$HOME/bin" "$HOME/.bashrc"; then echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"; fi
}

# ==================================================
# 7. 结果输出
# ==================================================
print_links(){
    sleep 3
    rm -f "$HOME/agsbx/jh.txt"
    echo "========================================================="
    echo "✅ 安装完成！(官方 Xray 内核 + Cloudflare Tunnel)"
    echo "========================================================="
    echo "UUID: $uuid"
    echo "内网端口: $port_vm_ws"
    echo "Argo 域名: $ARGO_DOMAIN"
    
    # 生成链接
    vma_link="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"Argo-VMess\", \"add\": \"$ARGO_DOMAIN\", \"port\": \"443\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN\", \"path\": \"/${uuid}-vm\", \"tls\": \"tls\", \"sni\": \"$ARGO_DOMAIN\"}" | base64 -w0)"
    
    echo "---------------------------------------------------------"
    echo "🔗 节点链接 (请复制):"
    echo ""
    echo "$vma_link"
    echo ""
    echo "$vma_link" >> "$HOME/agsbx/jh.txt"
    echo "========================================================="
    echo "提示: 输入 'agsbx list' 可再次查看链接，输入 'agsbx del' 可卸载。"
}

# === 入口 ===
if [ "$1" = "del" ]; then
    systemctl stop xr argo >/dev/null 2>&1
    rc-service xray stop 2>/dev/null
    rc-service argo stop 2>/dev/null
    rm -rf "$HOME/agsbx" /etc/systemd/system/xr.service /etc/systemd/system/argo.service
    crontab -l | grep -v 'agsbx' | crontab -
    echo "已卸载。"
    exit
fi

echo "🚀 开始安装..."
installxray
install_argo
setup_services
persist_env
print_links
