# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 走完 OIDC 链后用应用自己的“当前用户”接口断言认出的是主人管理员。
# 数据：data_write 往共享文件夹放一个 ROM 并扫描入库，data_check 升级/重装后核对还在。
# 工具：清单没有 mcp，这一项由套件按 N/A 处理。

web_assert() { grep -qi '<title>RomM</title>'; }

games_share() { # games 共享文件夹在测试环境里的宿主路径
  if [[ -n "${E2E_DIR:-}" ]]; then
    printf '%s' "$E2E_DIR/.wonton/data/shares/games"
  else
    printf '%s' "${SMOKE_STATE:?}/data/shares/games"
  fi
}

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

data_write() { # 在 games 共享文件夹建 gba 平台目录放一个占位 ROM，登录后触发扫描，等它入库
  local marker task_id task out
  marker="$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf '%s' "$marker" >"$SMOKE_STATE/romm-data-marker"
  mkdir -p "$(games_share)/roms/gba" || { echo "建平台目录失败"; return 1; }
  head -c 4096 /dev/urandom >"$(games_share)/roms/gba/wonton-$marker.gba" || { echo "写占位 ROM 失败"; return 1; }

  identity_check >/dev/null || { echo "OIDC 链走不通"; return 1; }
  task="$(web_get /api/users/me >/dev/null; curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" \
    -X POST "$SMOKE_WEB_URL/api/tasks/scan")" || { echo "触发扫描失败：$(head -c 200 <<<"$task")"; return 1; }
  task_id="$(jq -r '.task_id // empty' <<<"$task")"
  [[ -n "$task_id" ]] || { echo "扫描响应没有 task_id：$(head -c 200 <<<"$task")"; return 1; }
  for _ in $(seq 1 60); do
    out="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" "$SMOKE_WEB_URL/api/tasks/$task_id" 2>/dev/null || true)"
    [[ "$(jq -r '.status // empty' <<<"$out")" == finished ]] && break
    [[ "$(jq -r '.status // empty' <<<"$out")" == failed ]] && { echo "扫描失败：$(head -c 200 <<<"$out")"; return 1; }
    sleep 2
  done
  scan_sees_marker "$marker" || return 1
}

data_check() { # 升级/重装后：文件还在，库里扫出的平台和 ROM 也还在（不重扫）
  local marker
  marker="$(cat "$SMOKE_STATE/romm-data-marker" 2>/dev/null)"
  [[ -n "$marker" ]] || { echo "没有 data_write 留下的标记"; return 1; }
  [[ -f "$(games_share)/roms/gba/wonton-$marker.gba" ]] || { echo "共享文件夹里的 ROM 不见了"; return 1; }
  identity_check >/dev/null || { echo "升级/重装后 OIDC 链走不通"; return 1; }
  scan_sees_marker "$marker" || return 1
}

scan_sees_marker() { # <marker>：/api/platforms 里有 gba 且 ROM 计数至少 1
  local platforms
  platforms="$(web_get /api/platforms)" || { echo "取 /api/platforms 失败：$(head -c 200 <<<"$platforms")"; return 1; }
  jq -e 'any(.[]; .fs_slug == "gba" and .rom_count >= 1)' <<<"$platforms" >/dev/null ||
    { echo "扫描没认出 gba 平台或 ROM：$(head -c 300 <<<"$platforms")"; return 1; }
}
