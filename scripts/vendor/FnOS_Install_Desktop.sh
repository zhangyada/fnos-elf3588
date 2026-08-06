#!/bin/bash
# Debian 12 XFCE + XRDP + 中文环境 自动安装脚本
# root 用户直接运行，非 root 会自动提权
set -e

CURRENT_USER=$(whoami)
echo "[INFO] 当前用户: $CURRENT_USER"

# ----------------------------
# 提权函数
# ----------------------------
run_as_root() {
    if [ "$CURRENT_USER" = "root" ]; then
        bash -c "$1"
    else
        echo "[INFO] 需要 root 权限执行操作..."
        if command -v sudo >/dev/null 2>&1; then
            sudo bash -c "$1"
        else
            su -c "$1"
        fi
    fi
}

# ----------------------------
# 1. 更新软件源
# ----------------------------
echo "[INFO] 更新软件源..."
run_as_root "apt update"

# ----------------------------
# 2. 安装基础工具、依赖和中文字体
# ----------------------------
echo "[INFO] 安装基础工具、依赖和中文字体..."
run_as_root "apt install -y curl wget nano dbus-x11 x11-xserver-utils locales fonts-noto-cjk fonts-wqy-zenhei"

# ----------------------------
# 3. 配置中文 locale
# ----------------------------
echo "[INFO] 配置中文 locale..."
# 确保 /etc/locale.gen 中 zh_CN.UTF-8 取消注释
run_as_root "sed -i '/^# zh_CN.UTF-8 UTF-8/s/^# //' /etc/locale.gen"
run_as_root "locale-gen"

# 设置系统默认 LANG
run_as_root "update-locale LANG=zh_CN.UTF-8"

# ----------------------------
# 4. 安装最小 XFCE 桌面环境
# ----------------------------
echo "[INFO] 安装最小 XFCE 桌面环境..."
run_as_root "apt install -y --no-install-recommends \
    xorg \
    xfce4 \
    xfce4-session \
    xfce4-terminal \
    xfce4-panel \
    xfce4-settings \
    xfwm4 \
    xfdesktop4 \
    dbus-user-session \
    policykit-1"

# ----------------------------
# 5. 安装 XRDP
# ----------------------------
echo "[INFO] 安装 XRDP..."
run_as_root "apt install -y xrdp xorgxrdp"

# ----------------------------
# 6. 配置 .xsession 和 .xinitrc
# ----------------------------
echo "[INFO] 配置 .xsession 和 .xinitrc..."
USER_HOME=$(eval echo "~$CURRENT_USER")
if [ ! -d "$USER_HOME" ]; then
    echo "[INFO] 当前用户 $CURRENT_USER 的 home 目录不存在，正在创建..."
    run_as_root "mkdir -p '$USER_HOME'"
    USER_GROUP=$(id -gn "$CURRENT_USER")
    run_as_root "chown $CURRENT_USER:$USER_GROUP '$USER_HOME'"
fi

# 当前用户 .xsession
cat > "$USER_HOME/.xsession" <<'EOF'
#!/bin/sh
exec dbus-launch --exit-with-session xfce4-session
EOF
chmod +x "$USER_HOME/.xsession"
rm -rf "$USER_HOME/.cache/sessions"
rm -f "$USER_HOME/.xsession-errors"

# 当前用户 .xinitrc
cat > "$USER_HOME/.xinitrc" <<'EOF'
#!/bin/sh
exec startxfce4
EOF
chmod +x "$USER_HOME/.xinitrc"

# root 的 .xsession
run_as_root "cat > /root/.xsession <<'EOF'
#!/bin/sh
exec dbus-launch --exit-with-session xfce4-session
EOF
chmod +x /root/.xsession
rm -rf /root/.cache/sessions
rm -f /root/.xsession-errors"

# root 的 .xinitrc
run_as_root "cat > /root/.xinitrc <<'EOF'
#!/bin/sh
exec startxfce4
EOF
chmod +x /root/.xinitrc"

# ----------------------------
# 7. 启动并开机自启 XRDP
# ----------------------------
echo "[INFO] 启动并设置 XRDP 开机自启..."
run_as_root "systemctl enable xrdp"
run_as_root "systemctl restart xrdp"
run_as_root "systemctl restart xrdp-sesman"

# ----------------------------
# 8. 配置用户中文环境
# ----------------------------
PROFILE_FILE="$USER_HOME/.profile"
grep -qxF 'export LANG=zh_CN.UTF-8' "$PROFILE_FILE" || echo 'export LANG=zh_CN.UTF-8' >> "$PROFILE_FILE"
grep -qxF 'export LANGUAGE=zh_CN:zh' "$PROFILE_FILE" || echo 'export LANGUAGE=zh_CN:zh' >> "$PROFILE_FILE"
grep -qxF 'export LC_ALL=zh_CN.UTF-8' "$PROFILE_FILE" || echo 'export LC_ALL=zh_CN.UTF-8' >> "$PROFILE_FILE"

# ----------------------------
# 9. root 用户 XRDP 登录提示
# ----------------------------
if [ "$CURRENT_USER" != "root" ]; then
    echo "[WARN] 如果需要使用 root 用户通过 XRDP 登录，请先执行以下命令设置 root 密码："
    echo "  sudo passwd root"
fi

# ----------------------------
# 10. 完成提示
# ----------------------------
echo "[INFO] 安装完成！"
echo "退出终端重新登录后，可使用 startx 启动 XFCE 桌面（中文界面已配置）。"
echo "XRDP 已安装，可使用 Xorg 会话远程登录桌面。"
echo "当前用户 ($CURRENT_USER) 的 ~/.xsession 和 ~/.xinitrc 已配置，root 用户的 ~/.xsession 和 ~/.xinitrc 已自动配置。"
echo "系统语言已设置为中文，XFCE 将显示中文界面。"

