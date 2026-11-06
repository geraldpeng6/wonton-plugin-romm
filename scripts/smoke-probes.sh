# shellcheck shell=bash
# scripts/smoke.sh / dev.sh probes 的一项一项探测，跟着插件走。
# 钩子只依赖约定面：SMOKE_STATE（数据标记）、SMOKE_JAR、SMOKE_WEB_URL、SMOKE_OWNER、
# SMOKE_BASE、SMOKE_TOKEN、SMOKE_INSTANCE，助手 web_get / dweb。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 走完 OIDC 链后用应用自己的“当前用户”接口断言认出的是主人管理员。
# 数据：data_write 用应用的上传接口收一个占位 ROM 并扫描入库，data_check 重登后核对还在。
# 工具：清单没有 mcp，这一项由套件按 N/A 处理。

web_assert() { grep -qi '<title>RomM</title>'; }

# 走完浏览器式 OIDC（/api/login/openid 重定向到核心身份提供方，核心会话自动登录，
# 回调 /api/oauth/openid 由 RomM 用授权码换令牌并种下自己的会话），再用会话调当前用户接口。
identity_check() {
  local page me
  page="$(dweb /api/login/openid -L -b "$SMOKE_JAR" -c "$SMOKE_JAR")" ||
    { echo "OIDC 链失败：$(head -c 300 <<<"$page")"; return 1; }
  grep -qi '<title>RomM</title>' <<<"$page" || { echo "没有落回 RomM 页面：$(head -c 200 <<<"$page")"; return 1; }
  me="$(web_get /api/users/me)" || { echo "取 /api/users/me 失败：$(head -c 200 <<<"$me")"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.username == $u and .role == "admin"' <<<"$me" >/dev/null ||
    { echo "当前用户不是主人管理员：$(head -c 200 <<<"$me")"; return 1; }
}

romm_marker_path() { # SMOKE_STATE 在 e2e 是标记文件，在 dev probes 是状态目录——两种都接住
  if [[ -f "$SMOKE_STATE" ]]; then
    printf '%s' "$SMOKE_STATE"
  else
    printf '%s' "$SMOKE_STATE/romm-data-marker"
  fi
}

romm_csrf() { # RomM 的 CSRF 中间件校验所有写请求：先刷新令牌 cookie 再从会话里取出来
  dweb /api/heartbeat -c "$SMOKE_JAR" >/dev/null 2>&1
  awk '$6 == "romm_csrftoken" {print $7}' "$SMOKE_JAR" | tail -1
}

scan_sees_gba() { # /api/platforms 里有 gba 且 ROM 计数至少 1
  local platforms
  platforms="$(web_get /api/platforms)" || { echo "取 /api/platforms 失败：$(head -c 200 <<<"$platforms")"; return 1; }
  jq -e 'any(.[]; .fs_slug == "gba" and .rom_count >= 1)' <<<"$platforms" >/dev/null ||
    { echo "扫描没认出 gba 平台或 ROM：$(head -c 300 <<<"$platforms")"; return 1; }
}

data_write() { # 用应用的上传接口收一个占位 ROM（服务端自己写进 games 共享文件夹），扫描入库，标记记下
  local marker csrf platforms pid up upload_id task task_id out tmp
  marker="$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  identity_check >/dev/null || { echo "OIDC 链走不通"; return 1; }
  csrf="$(romm_csrf)"
  [[ -n "$csrf" ]] || { echo "会话里没有 romm_csrftoken"; return 1; }

  web_get /api/platforms -H "x-csrftoken: $csrf" -X POST -H 'Content-Type: application/json' \
    -d '{"fs_slug":"gba"}' >/dev/null || { echo "建平台失败"; return 1; }
  platforms="$(web_get /api/platforms)" || { echo "取 /api/platforms 失败"; return 1; }
  pid="$(jq -r 'map(select(.fs_slug == "gba")) | .[0].id // empty' <<<"$platforms")"
  [[ -n "$pid" ]] || { echo "平台列表里没有 gba：$(head -c 200 <<<"$platforms")"; return 1; }

  tmp="$(mktemp)"
  head -c 4096 /dev/urandom >"$tmp" || { rm -f "$tmp"; echo "生成占位 ROM 失败"; return 1; }
  up="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "x-csrftoken: $csrf" \
    -H "x-upload-platform: $pid" -H "x-upload-filename: wonton-$marker.gba" \
    -H "x-upload-total-size: 4096" -H "x-upload-total-chunks: 1" \
    -X POST "$SMOKE_WEB_URL/api/roms/upload/start")" || { rm -f "$tmp"; echo "上传 start 失败：$(head -c 200 <<<"$up")"; return 1; }
  upload_id="$(jq -r '.upload_id // empty' <<<"$up")"
  [[ -n "$upload_id" ]] || { rm -f "$tmp"; echo "start 响应没有 upload_id：$(head -c 200 <<<"$up")"; return 1; }
  curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "x-csrftoken: $csrf" -H 'x-chunk-index: 0' \
    -H 'Content-Type: application/octet-stream' --data-binary @"$tmp" \
    -X PUT "$SMOKE_WEB_URL/api/roms/upload/$upload_id" >/dev/null 2>&1 || { rm -f "$tmp"; echo "上传 chunk 失败"; return 1; }
  curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "x-csrftoken: $csrf" \
    -X POST "$SMOKE_WEB_URL/api/roms/upload/$upload_id/complete" >/dev/null 2>&1 || { rm -f "$tmp"; echo "上传 complete 失败"; return 1; }
  rm -f "$tmp"

  task="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "x-csrftoken: $csrf" \
    -X POST "$SMOKE_WEB_URL/api/tasks/scan")" || { echo "触发扫描失败：$(head -c 200 <<<"$task")"; return 1; }
  task_id="$(jq -r '.task_id // empty' <<<"$task")"
  [[ -n "$task_id" ]] || { echo "扫描响应没有 task_id：$(head -c 200 <<<"$task")"; return 1; }
  for _ in $(seq 1 60); do
    out="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" "$SMOKE_WEB_URL/api/tasks/$task_id" 2>/dev/null || true)"
    [[ "$(jq -r '.status // empty' <<<"$out")" == finished ]] && break
    [[ "$(jq -r '.status // empty' <<<"$out")" == failed ]] && { echo "扫描失败：$(head -c 200 <<<"$out")"; return 1; }
    sleep 2
  done
  scan_sees_gba || return 1
  printf '%s' "$marker" >"$(romm_marker_path)"
}

data_check() { # 升级/重装后：库里扫出的平台和 ROM 还在（不重扫）
  local marker
  marker="$(cat "$(romm_marker_path)" 2>/dev/null)"
  [[ -n "$marker" ]] || { echo "没有 data_write 留下的标记"; return 1; }
  identity_check >/dev/null || { echo "升级/重装后 OIDC 链走不通"; return 1; }
  scan_sees_gba || return 1
}
