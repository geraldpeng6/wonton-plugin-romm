# shellcheck shell=bash disable=SC2034
# scripts/smoke.sh / dev.sh probes 的一项一项探测，跟着插件走。
# 钩子只用约定面：SMOKE_STATE（数据标记）、SMOKE_OWNER 和助手 web_get / dweb；
# 会话 jar 由钩子自己 mktemp 持有（dweb --jar），不依赖调用方导出的 jar 变量。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 走完 OIDC 链后用应用自己的“当前用户”接口断言认出的是主人管理员。
# 数据：data_write 用应用的上传接口收一个占位 ROM 并扫描入库，data_check 重登后核对还在。
# 工具：清单没有 mcp，这一项由套件按 N/A 处理。

web_assert() { grep -qi '<title>RomM</title>'; }

romm_login() { # <jar>：走完浏览器式 OIDC（/api/login/openid → 核心身份提供方自动登录 →
  #            回调 /api/oauth/openid 由 RomM 换令牌），RomM 会话落在指定 jar 里
  dweb --jar "$1" /api/login/openid -L
}

romm_marker_path() { # SMOKE_STATE 在 e2e 是标记文件，在 dev probes 是状态目录——两种都接住
  if [[ -f "$SMOKE_STATE" ]]; then
    printf '%s' "$SMOKE_STATE"
  else
    printf '%s' "$SMOKE_STATE/romm-data-marker"
  fi
}

romm_csrf() { # <jar>：RomM 的 CSRF 中间件校验所有写请求，令牌在 heartbeat 写进会话 cookie
  dweb --jar "$1" /api/heartbeat >/dev/null 2>&1
  awk '$6 == "romm_csrftoken" {print $7}' "$1" | tail -1
}

romm_check_admin() { # <jar>：当前用户是主人管理员
  local me
  me="$(dweb --jar "$1" /api/users/me)" || { echo "取 /api/users/me 失败：$(head -c 200 <<<"$me")"; return 1; }
  jq -e --arg u "${SMOKE_OWNER:-owner}" '.username == $u and .role == "admin"' <<<"$me" >/dev/null ||
    { echo "当前用户不是主人管理员：$(head -c 200 <<<"$me")"; return 1; }
}

identity_check() {
  local jar page
  # mktemp -u：只取名字不建文件——session_into 见 jar 文件已存在会跳过核心登录（dev.sh:505），网关就 401 了
  jar="$(mktemp -u)"
  page="$(romm_login "$jar")" || { rm -f "$jar"; echo "OIDC 链失败：$(head -c 300 <<<"$page")"; return 1; }
  grep -qi '<title>RomM</title>' <<<"$page" || { rm -f "$jar"; echo "没有落回 RomM 页面：$(head -c 200 <<<"$page")"; return 1; }
  romm_check_admin "$jar" || { rm -f "$jar"; return 1; }
  rm -f "$jar"
}

scan_sees_gba() { # <jar>：/api/platforms 里有 gba 且 ROM 计数至少 1
  local platforms
  platforms="$(dweb --jar "$1" /api/platforms)" || { echo "取 /api/platforms 失败：$(head -c 200 <<<"$platforms")"; return 1; }
  jq -e 'any(.[]; .fs_slug == "gba" and .rom_count >= 1)' <<<"$platforms" >/dev/null ||
    { echo "扫描没认出 gba 平台或 ROM：$(head -c 300 <<<"$platforms")"; return 1; }
}

data_write() { # 用应用的上传接口收一个占位 ROM（服务端自己写进 games 共享文件夹），扫描入库，标记记下
  local jar marker csrf platforms pid up upload_id task task_id out tmp
  # mktemp -u：只取名字不建文件——session_into 见 jar 文件已存在会跳过核心登录（dev.sh:505），网关就 401 了
  jar="$(mktemp -u)"
  marker="$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  romm_login "$jar" >/dev/null || { rm -f "$jar"; echo "OIDC 链走不通"; return 1; }
  romm_check_admin "$jar" || { rm -f "$jar"; return 1; }
  csrf="$(romm_csrf "$jar")"
  [[ -n "$csrf" ]] || { rm -f "$jar"; echo "会话里没有 romm_csrftoken"; return 1; }

  dweb --jar "$jar" /api/platforms -H "x-csrftoken: $csrf" -X POST -H 'Content-Type: application/json' \
    -d '{"fs_slug":"gba"}' >/dev/null || { rm -f "$jar"; echo "建平台失败"; return 1; }
  platforms="$(dweb --jar "$jar" /api/platforms)" || { rm -f "$jar"; echo "取 /api/platforms 失败"; return 1; }
  pid="$(jq -r 'map(select(.fs_slug == "gba")) | .[0].id // empty' <<<"$platforms")"
  [[ -n "$pid" ]] || { rm -f "$jar"; echo "平台列表里没有 gba：$(head -c 200 <<<"$platforms")"; return 1; }

  tmp="$(mktemp)"
  head -c 4096 /dev/urandom >"$tmp" || { rm -f "$tmp" "$jar"; echo "生成占位 ROM 失败"; return 1; }
  up="$(dweb --jar "$jar" /api/roms/upload/start -H "x-csrftoken: $csrf" \
    -H "x-upload-platform: $pid" -H "x-upload-filename: wonton-$marker.gba" \
    -H "x-upload-total-size: 4096" -H "x-upload-total-chunks: 1" -X POST)" ||
    { rm -f "$tmp" "$jar"; echo "上传 start 失败：$(head -c 200 <<<"$up")"; return 1; }
  upload_id="$(jq -r '.upload_id // empty' <<<"$up")"
  [[ -n "$upload_id" ]] || { rm -f "$tmp" "$jar"; echo "start 响应没有 upload_id：$(head -c 200 <<<"$up")"; return 1; }
  dweb --jar "$jar" "/api/roms/upload/$upload_id" -H "x-csrftoken: $csrf" -H 'x-chunk-index: 0' \
    -H 'Content-Type: application/octet-stream' --data-binary @"$tmp" -X PUT >/dev/null 2>&1 ||
    { rm -f "$tmp" "$jar"; echo "上传 chunk 失败"; return 1; }
  dweb --jar "$jar" "/api/roms/upload/$upload_id/complete" -H "x-csrftoken: $csrf" -X POST >/dev/null 2>&1 ||
    { rm -f "$tmp" "$jar"; echo "上传 complete 失败"; return 1; }
  rm -f "$tmp"

  task="$(dweb --jar "$jar" /api/tasks/scan -H "x-csrftoken: $csrf" -X POST)" ||
    { rm -f "$jar"; echo "触发扫描失败：$(head -c 200 <<<"$task")"; return 1; }
  task_id="$(jq -r '.task_id // empty' <<<"$task")"
  [[ -n "$task_id" ]] || { rm -f "$jar"; echo "扫描响应没有 task_id：$(head -c 200 <<<"$task")"; return 1; }
  for _ in $(seq 1 60); do
    out="$(dweb --jar "$jar" "/api/tasks/$task_id" 2>/dev/null || true)"
    [[ "$(jq -r '.status // empty' <<<"$out")" == finished ]] && break
    [[ "$(jq -r '.status // empty' <<<"$out")" == failed ]] && { rm -f "$jar"; echo "扫描失败：$(head -c 200 <<<"$out")"; return 1; }
    sleep 2
  done
  scan_sees_gba "$jar" || { rm -f "$jar"; return 1; }
  rm -f "$jar"
  printf '%s' "$marker" >"$(romm_marker_path)"
}

data_check() { # 升级/重装后：库里扫出的平台和 ROM 还在（不重扫）
  local jar marker
  # mktemp -u：只取名字不建文件——session_into 见 jar 文件已存在会跳过核心登录（dev.sh:505），网关就 401 了
  jar="$(mktemp -u)"
  marker="$(cat "$(romm_marker_path)" 2>/dev/null)"
  [[ -n "$marker" ]] || { echo "没有 data_write 留下的标记"; return 1; }
  romm_login "$jar" >/dev/null || { rm -f "$jar"; echo "升级/重装后 OIDC 链走不通"; return 1; }
  romm_check_admin "$jar" || { rm -f "$jar"; return 1; }
  scan_sees_gba "$jar" || { rm -f "$jar"; return 1; }
  rm -f "$jar"
}

# ---------- 发信（notify，规范 0.11）----------
rm_core() { # 核心容器：Mailpit 的别名和 API 密码都在它的网络上/数据目录里
	docker ps --format '{{.Names}}' | grep -xE "wonton-${SMOKE_INSTANCE:-}--core" | head -1
}

rm_mailpit() { # <path>：调 Mailpit API（basic core:<密码>）。主路照核心自己的冒烟：在核心网络里
	# 打 mailpit.wonton.internal:8025；兜底用应用容器的 wget（它的网络里也有这个别名）。
	local core pw dd out webc
	core="$(rm_core)" || return 1
	if declare -F read_env >/dev/null; then dd="$(read_env WONTON_DATA_DIR)"; else dd="$(probes_setting WONTON_DATA_DIR)"; fi
	pw="$(docker exec "$core" cat "$dd/core/mailpit/api-password" 2>/dev/null)"
	[[ -n "${pw:-}" ]] || { echo "读不到 Mailpit API 密码（核心数据目录 core/mailpit/api-password）"; return 1; }
	out="$(docker run --rm --network "container:$core" curlimages/curl:8.23.0 \
		-s -u "core:$pw" "http://mailpit.wonton.internal:8025$1" 2>&1)"
	if jq -e '.messages' <<<"$out" >/dev/null 2>&1 || [[ "$out" == "{"* ]]; then
		printf '%s' "$out"; return 0
	fi
	webc="$(docker ps --format '{{.Names}}' | grep "$SMOKE_INSTANCE" | grep 'romm' | head -1)"
	[[ -n "$webc" ]] || { echo "Mailpit 主路没拿到 JSON：$(head -c 200 <<<"$out")"; return 1; }
	docker exec "$webc" wget -qO- --header "Authorization: Basic $(printf 'core:%s' "$pw" | base64 | tr -d '\n')" \
		"http://smtp.wonton.internal:8025$1" 2>&1
}

rm_mailpit_wait() { # <from> <to> [次数=20]：等一封 From/To 对上的信进 Mailpit
	local from="$1" to="$2" n="${3:-20}" i out
	for ((i = 0; i < n; i++)); do
		out="$(rm_mailpit "/api/v1/messages?limit=100")" || { sleep 3; continue; }
		jq -e --arg f "$from" --arg t "$to" \
			'.messages | any(.From.Address == $f and any(.To[]; .Address == $t))' <<<"$out" >/dev/null 2>&1 && return 0
		sleep 3
	done
	return 1
}

rm_mailpit_wait_gone() { # <to> [次数=20]：等收件人的信从 Mailpit 里消失（核心投进私聊后会把信删掉）
	local to="$1" n="${2:-20}" i out
	for ((i = 0; i < n; i++)); do
		out="$(rm_mailpit "/api/v1/messages?limit=100")" || { sleep 3; continue; }
		jq -e --arg t "$to" '(.messages | map(select(.To[].Address == $t)) | length) == 0' <<<"$out" >/dev/null 2>&1 && return 0
		sleep 3
	done
	return 1
}

extra_check() { # 发信端到端：建一个 Email 通知渠道，应用立刻寄确认码邮件（只在发送成功时才建上），
	# 核心投进主人私聊后从 Mailpit 取走删除；收完把渠道删掉，不给实例留未确认的渠道
	local jar csrf resp id to
	to="${SMOKE_OWNER:-owner}@wonton.internal"
	jar="$(mktemp -u)"
	page="$(romm_login "$jar")" || { rm -f "$jar"; echo "OIDC 链失败：$(head -c 300 <<<"$page")"; return 1; }
	romm_check_admin "$jar" || { rm -f "$jar"; return 1; }
	csrf="$(romm_csrf "$jar")"
	[[ -n "$csrf" ]] || { rm -f "$jar"; echo "会话里没有 romm_csrftoken"; return 1; }
	resp="$(dweb --jar "$jar" /api/notification-channels -H "x-csrftoken: $csrf" -H 'Content-Type: application/json' \
		-X POST -d "{\"type\":\"email\",\"name\":\"wonton-smoke-$(date +%s)\",\"address\":\"$to\"}")" ||
		{ rm -f "$jar"; echo "建 Email 渠道失败：$(head -c 200 <<<"$resp")"; return 1; }
	id="$(jq -r '.id // empty' <<<"$resp")"
	[[ -n "$id" ]] || { rm -f "$jar"; echo "建渠道响应没有 id：$(head -c 200 <<<"$resp")"; return 1; }
	jq -e '.confirmed == false' <<<"$resp" >/dev/null || { rm -f "$jar"; echo "渠道不该是已确认的：$resp"; return 1; }
	# 信进内部邮箱：From 是 WONTON_MAIL_FROM（app.romm.romm@plugins.wonton.internal）。
	rm_mailpit_wait "app.romm.romm@plugins.wonton.internal" "$to" 20 ||
		{ dweb --jar "$jar" "/api/notification-channels/$id" -H "x-csrftoken: $csrf" -X DELETE >/dev/null 2>&1; rm -f "$jar"
			echo "确认码邮件 60 秒没进 Mailpit：$(rm_mailpit '/api/v1/messages?limit=5' | head -c 300)"; return 1; }
	echo "确认码邮件已进内部邮箱（To=$to）"
	# 核心投进收件人私聊后把信从 Mailpit 删掉：信箱里没有这封信 = 已投递。
	rm_mailpit_wait_gone "$to" 20 ||
		{ echo "确认码邮件一直留在 Mailpit：核心没把它投进主人私聊（投完才会删）"; rm -f "$jar"; return 1; }
	dweb --jar "$jar" "/api/notification-channels/$id" -H "x-csrftoken: $csrf" -X DELETE >/dev/null ||
		echo "（提示）测试渠道 $id 删不掉，留在实例里"
	rm -f "$jar"
	echo "核心已把信投进主人的 Wonton 私聊（Mailpit 里已删除）"
}
