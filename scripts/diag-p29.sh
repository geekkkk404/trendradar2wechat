#!/usr/bin/env bash
# diag-p29.sh — P-29 现场诊断：daemon.json / restart 退出码 / 活性 / journal
echo "== ① daemon.json =="
cat /etc/docker/daemon.json 2>/dev/null || echo "(无文件)"
echo "== ② 手动 restart（含错误输出）=="
systemctl restart docker 2>&1; echo "exit=$?"
echo "== ③ 3秒后活性 =="
sleep 3
systemctl is-active docker
docker info >/dev/null 2>&1 && echo "docker-OK" || echo "docker-DEAD"
echo "== ④ unit 状态摘要 =="
systemctl status docker --no-pager -l 2>&1 | head -12
echo "== ⑤ journal 尾部 =="
journalctl -u docker --no-pager -n 25 2>&1 | tail -25
echo "== ⑥ 环境 =="
docker --version 2>/dev/null
uname -r
free -m | head -2
echo "== DIAG-DONE =="
