#!/bin/bash
# 测试：bash hooks/tests/vault-project-hint.test.sh
# 用一个假知识库（只有 projects/ 和一个最小的 _system/scripts/collect.py），不依赖本机的 ~/Documents/AgentVault。
hook="$(cd "$(dirname "$0")/.." && pwd)/vault-project-hint.py"
fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

vault="$tmp/vault"
mkdir -p "$vault/_system/scripts" "$vault/projects/demo" "$vault/projects/empty"
touch "$vault/projects/demo/overview.md" "$vault/projects/demo/status.md"
cat > "$vault/_system/scripts/collect.py" <<'EOF'
import fnmatch


def load_config():
    return {"projects": [{"key": "demo", "dirs": ["/work/demo*"]}, {"key": "empty", "dirs": ["/work/empty"]}],
            "exclude_session_dirs": ["/work/demo-run"]}


class ProjectMapper:
    def __init__(self, cfg):
        self.cfg = cfg

    def excluded(self, cwd):
        return any(fnmatch.fnmatch(cwd, p) for p in self.cfg["exclude_session_dirs"])

    def key_for_cwd(self, cwd):
        for p in self.cfg["projects"]:
            if any(fnmatch.fnmatch(cwd, d) for d in p["dirs"]):
                return p["key"]
        return "misc"
EOF

run() { # vault_dir stdin
  printf '%s' "$2" | AGENT_VAULT_DIR="$1" python3 "$hook" 2>"$tmp/err"
}

check() { # name want(hint|silent) output [应出现的文字]
  local got=silent
  [ -n "$3" ] && got=hint
  if [ "$got" != "$2" ]; then echo "FAIL $1 (want $2 got $got) $3 $(cat "$tmp/err")"; fail=1; return; fi
  if [ -n "${4-}" ] && ! printf '%s' "$3" | grep -qF "$4"; then echo "FAIL $1 (缺「$4」) $3"; fail=1; return; fi
  echo "ok   $1"
}

out=$(run "$vault" '{"hook_event_name":"SessionStart","cwd":"/work/demo-api"}')
check "对应项目时提示 overview 和 status" hint "$out" "$vault/projects/demo/overview.md 和 $vault/projects/demo/status.md"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["hookEventName"] == "SessionStart"' \
  && echo "ok   输出是 SessionStart 的 JSON" || { echo "FAIL 输出不是合法 JSON"; fail=1; }
check "对应不到项目时不输出" silent "$(run "$vault" '{"cwd":"/somewhere/else"}')"
check "无人值守目录不输出" silent "$(run "$vault" '{"cwd":"/work/demo-run"}')"
check "项目目录里没有笔记时不输出" silent "$(run "$vault" '{"cwd":"/work/empty"}')"
check "知识库不存在时不输出" silent "$(run "$tmp/no-vault" '{"cwd":"/work/demo-api"}')"
check "输入不是 JSON 时不输出" silent "$(run "$vault" 'not json')"

printf 'raise RuntimeError("坏配置")\n' > "$tmp/bad.py"
mkdir -p "$tmp/badvault/_system/scripts" && cp "$tmp/bad.py" "$tmp/badvault/_system/scripts/collect.py"
out=$(run "$tmp/badvault" '{"cwd":"/work/demo-api"}'); code=$?
if [ "$code" = 0 ] && [ -z "$out" ] && grep -q '坏配置' "$tmp/err"; then echo "ok   库脚本出错时退出 0、stderr 留原因"; else echo "FAIL 库脚本出错 code=$code out=$out"; fail=1; fi

exit $fail
