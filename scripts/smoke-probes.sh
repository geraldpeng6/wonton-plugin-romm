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
rm_core() { # 核心容器：通知房记录、Matrix 令牌和 Tuwunel 都在它的数据目录/网络上
	docker ps --format '{{.Names}}' | grep -xE "wonton-${SMOKE_INSTANCE:-}--core" | head -1
}

rm_dd() { # 核心数据目录（e2e 冒烟有 read_env；dev.sh probes 用 probes_setting）
	if declare -F read_env >/dev/null; then read_env WONTON_DATA_DIR; else probes_setting WONTON_DATA_DIR; fi
}

rm_room_query() { # 用主人令牌读「Wonton」通知房最近消息（信被核心投进私聊的最终证据）。
	# 主人令牌照核心自己的做法：管理令牌走 Tuwunel 的 impersonation 登录；都在核心容器里拿。
	local core dd room admin srv otok
	core="$(rm_core)" || return 1
	dd="$(rm_dd)"
	room="$(docker exec "$core" cat "$dd/core/matrix-notice-room")" ||
		{ echo "读不到通知房记录（$dd/core/matrix-notice-room）"; return 1; }
	admin="$(docker exec "$core" cat "$dd/core/matrix-admin-token")" ||
		{ echo "读不到 Matrix 管理令牌"; return 1; }
	srv="$(docker exec "$core" cat "$dd/../secrets/matrix-server-name")" ||
		{ echo "读不到 Matrix 服务器名"; return 1; }
	otok="$(docker run --rm --network "container:$core" -e HTTP_PROXY= -e HTTPS_PROXY= -e http_proxy= -e https_proxy= -e NO_PROXY='*' \
		curlimages/curl:8.23.0 -sS -H "Authorization: Bearer $admin" -H 'Content-Type: application/json' -d '{}' \
		"http://tuwunel.wonton.internal:8008/_synapse/admin/v1/users/@owner:$srv/login" | jq -er .access_token)" ||
		{ echo "拿不到主人的 Matrix 令牌"; return 1; }
	docker run --rm --network "container:$core" -e HTTP_PROXY= -e HTTPS_PROXY= -e http_proxy= -e https_proxy= -e NO_PROXY='*' \
		curlimages/curl:8.23.0 -sS -H "Authorization: Bearer $otok" \
		"http://tuwunel.wonton.internal:8008/_matrix/client/v3/rooms/$room/messages?dir=b&limit=20"
}

rm_room_newest_ts() { # <前缀>：通知房里该插件最近一条邮件消息的 origin_server_ts（没有则 0）
	local out
	out="$(rm_room_query)" || { echo 0; return 0; }
	jq -r --arg p "$1" '[.chunk[]? | select(.type == "m.room.message" and (.content.body | startswith($p))) | .origin_server_ts] | max // 0' <<<"$out" 2>/dev/null || echo 0
}

rm_room_wait() { # <前缀> <标记> <起始 ts> [次数=40]：等通知房里出现这条插件发的新邮件消息（投进私聊后一直都在）
	local prefix="$1" marker="$2" since="$3" n="${4:-40}" i out hits
	for ((i = 0; i < n; i++)); do
		out="$(rm_room_query)" || { sleep 2; continue; }
		hits="$(jq -r --arg p "$prefix" --arg m "$marker" --argjson s "$since" '
			[.chunk[]? | select(.type == "m.room.message" and (.content.body | startswith($p)) and .origin_server_ts > $s)
			 | select($m == "" or (.content.body | contains($m)))] | length' <<<"$out" 2>/dev/null || echo 0)"
		[[ "${hits:-0}" -ge 1 ]] && return 0
		sleep 2
	done
	return 1
}

extra_check() { # 发信端到端：建一个 Email 通知渠道，应用立刻寄确认码邮件（只在发送成功时才建上），
	# 核心把它投进主人的「Wonton」私聊（直接读通知房的消息）；收完把渠道删掉，不给实例留未确认的渠道
	local jar csrf resp id to
	to="${SMOKE_OWNER:-owner}@wonton.internal"
	jar="$(mktemp -u)"
	page="$(romm_login "$jar")" || { rm -f "$jar"; echo "OIDC 链失败：$(head -c 300 <<<"$page")"; return 1; }
	romm_check_admin "$jar" || { rm -f "$jar"; return 1; }
	csrf="$(romm_csrf "$jar")"
	[[ -n "$csrf" ]] || { rm -f "$jar"; echo "会话里没有 romm_csrftoken"; return 1; }
	# 记下触发前该插件最近一封邮件消息的时间，之后只认更新的。
	before="$(rm_room_newest_ts "RomM：")"
	# 建渠道：应用寄出确认码邮件（发送成功才建得上渠道，本身就是一次真实发信）。
	resp="$(dweb --jar "$jar" /api/notification-channels -H "x-csrftoken: $csrf" -H 'Content-Type: application/json' \
		-X POST -d "{\"type\":\"email\",\"name\":\"wonton-smoke-$(date +%s)\",\"address\":\"$to\"}")" ||
		{ rm -f "$jar"; echo "建 Email 渠道失败：$(head -c 200 <<<"$resp")"; return 1; }
	id="$(jq -r '.id // empty' <<<"$resp")"
	[[ -n "$id" ]] || { rm -f "$jar"; echo "建渠道响应没有 id：$(head -c 200 <<<"$resp")"; return 1; }
	jq -e '.confirmed == false' <<<"$resp" >/dev/null || { rm -f "$jar"; echo "渠道不该是已确认的：$resp"; return 1; }
	# 核心把信投进主人的「Wonton」私聊：房里出现这一封。
	rm_room_wait "RomM：" "" "$before" 40 ||
		{ dweb --jar "$jar" "/api/notification-channels/$id" -H "x-csrftoken: $csrf" -X DELETE >/dev/null 2>&1; rm -f "$jar"
			echo "确认码邮件 80 秒没出现在主人的 Wonton 私聊：$(rm_room_query | head -c 300)"; return 1; }
	dweb --jar "$jar" "/api/notification-channels/$id" -H "x-csrftoken: $csrf" -X DELETE >/dev/null ||
		echo "（提示）测试渠道 $id 删不掉，留在实例里"
	rm -f "$jar"
	echo "确认码邮件已进主人的 Wonton 私聊（RomM：…，收件人 $to）"
}
