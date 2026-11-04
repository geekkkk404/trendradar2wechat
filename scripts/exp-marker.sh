#!/bin/bash
# marker 消失定位实验（stdin 管道注入，规避 wsl.exe 参数损坏）
set -u
cat /tmp/tr030.sh | head -1 >/dev/null  # 确认安装脚本还在
if [ ! -f /tmp/tr030.sh ]; then echo "INSTALLER_GONE"; exit 1; fi
bash /tmp/tr030.sh --wechat-bridge --no-web > /tmp/exp1.log 2>&1 && echo INSTALLED || { echo INSTALL_FAIL; tail -5 /tmp/exp1.log; exit 1; }
F=/opt/TrendRadar/user-config/frequency_words.txt
echo '--- S1 append (ASCII + Chinese) ---'
echo 'P32ASCII_MARKER' >> "$F"
echo 'P32中文标记' >> "$F"
echo "ascii=$(grep -c P32ASCII "$F") cn=$(grep -c 中文 "$F")"
tail -3 "$F"
echo '--- S2 fetch (version-check suspect) ---'
systemctl start trendradar-fetch 2>/dev/null
sleep 75
echo "after_fetch ascii=$(grep -c P32ASCII "$F")"
tail -2 "$F"
echo '--- S3 CLI apply ---'
printf '{"v":1,"cfg":{"report":{"mode":"daily"}}}' > /tmp/p2.json
/opt/TrendRadar/.venv/bin/python /opt/TrendRadar/tr2w/apply_trcfg.py /tmp/p2.json
echo "after_cli ascii=$(grep -c P32ASCII "$F")"
echo '--- S4 rerun ---'
bash /tmp/tr030.sh --wechat-bridge --no-web > /tmp/exp2.log 2>&1
echo "rerun_rc=$?"
echo "after_rerun ascii=$(grep -c P32ASCII "$F")"
grep -E '已更新到最新版|升级不覆盖' /tmp/exp2.log
echo '--- S5 version check log scan ---'
journalctl -u trendradar-fetch --no-pager --since '-10 min' 2>/dev/null | grep -iE '版本|version|更新|覆盖' | head -8
