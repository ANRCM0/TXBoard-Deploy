#!/usr/bin/env bash
# Read-only table cutover review generator.
# Requires an existing db_sql function and a confirmed legacy v2_* schema.
# NEVER changes the approval fields or runs any DDL.
txboard_generate_cutover_review() {
  command -v python3 >/dev/null 2>&1 || {
    printf '[TXBoard] 缺少 python3，无法生成数据库映射报告\n' >&2
    return 1
  }
  local out_dir inventory out count
  out_dir="$INSTALL_DIR/backups/cutover-plans"
  mkdir -p -m 700 "$out_dir" || return 1
  chmod 700 "$out_dir" || return 1
  inventory="$(mktemp "$out_dir/.tables.XXXXXXXX")" || return 1
  if ! db_sql "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE' AND LEFT(TABLE_NAME,3)='v2_' ORDER BY TABLE_NAME" > "$inventory"; then
    rm -f "$inventory"
    printf '[TXBoard] 读取旧版数据表失败，未执行任何迁移\n' >&2
    return 1
  fi
  out="$out_dir/review-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
  if ! python3 - "$inventory" "$out" <<'PY'
import json, re, sys
from pathlib import Path

source = Path(sys.argv[1])
names = [x.strip() for x in source.read_text(encoding="utf-8").splitlines() if x.strip()]
if not names or len(names) != len(set(names)):
    sys.exit("数据库表清单为空或存在重复记录，已阻止生成")
if any(re.fullmatch(r"v2_[a-z][a-z0-9_]*", name) is None for name in names):
    sys.exit("存在不可安全重命名的数据表名，已阻止生成")
renames = [{"from": n, "to": "tx_" + n[3:]} for n in sorted(names)]
plan = {
    "schemaVersion": 1,
    "kind": "native-table-cutover-plan",
    "executable": False,
    "requiresManualApproval": True,
    "proposedRenames": renames,
    "blockers": [
        "TXBoard runtime and hardcoded SQL require independent compatibility review",
        "External plugins/workers/SQL references require independent review",
        "A complete database restore drill and row-level checks have not been verified",
    ],
    "notes": "Read-only inspection draft: never change approval flags to force production DDL",
}
dest = Path(sys.argv[2])
with dest.open("x", encoding="utf-8") as file:
    json.dump(plan, file, ensure_ascii=False, indent=2)
    file.write("\n")
dest.chmod(0o600)
print(f"[TXBoard] 已自动生成 {len(renames)} 张旧表的完整映射：{dest}")
print("[TXBoard] 当前只生成审核报告，未获得全量重命名生产授权。")
PY
  then
    rm -f "$inventory"
    return 1
  fi
  rm -f "$inventory"
  # A target collision or mixed schema always blocks even the review path.
  count="$(db_sql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND LEFT(TABLE_NAME,3)='tx_'")" || return 1
  [[ "$count" == 0 ]] || {
    printf '[TXBoard] 已发现 tx_* 目标表，必须先人工排查混合结构\n' >&2
    return 1
  }
  printf '[TXBoard] 检查结果：不能安全地自动执行全库重命名；原有业务仍保持运行。\n'
}
