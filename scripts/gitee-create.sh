#!/usr/bin/env bash
# gitee-create.sh — 用注入凭证调 Gitee API 建仓（凭证在 /tmp/.gu /tmp/.gp，用后即焚）
U=$(cat /tmp/.gu); P=$(cat /tmp/.gp)
DESC='一键部署 TrendRadar 到个人微信 (any2wechat)'
BODY="{\"name\":\"trendradar2wechat\",\"private\":false,\"has_issues\":true,\"auto_init\":false,\"description\":\"$DESC\"}"
code=$(curl -sm 20 -o /tmp/gresp.json -w '%{http_code}' -X POST 'https://gitee.com/api/v5/user/repos' -u "$U:$P" -H 'Content-Type: application/json' -d "$BODY")
echo "basic-auth HTTP $code"
if [ "$code" = "201" ]; then
  echo "CREATED"
  head -c 200 /tmp/gresp.json; echo
else
  code2=$(curl -sm 20 -o /tmp/gresp2.json -w '%{http_code}' -X POST "https://gitee.com/api/v5/user/repos?access_token=$P" -H 'Content-Type: application/json' -d "$BODY")
  echo "token-auth HTTP $code2"
  [ "$code2" = "201" ] && echo "CREATED"
  head -c 200 /tmp/gresp2.json 2>/dev/null; echo
fi
rm -f /tmp/.gu /tmp/.gp
