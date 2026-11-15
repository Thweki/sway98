# sway98 — 项目说明（面向 AI 代理与协作者）

Windows 98 外观，给 **Arch Linux + Sway**，一条命令装、一条命令卸干净。

本文件是工程的唯一约定来源。改代码前先读完，改完代码若与本文冲突，**改本文**。

---

## 1. 目标与非目标

**目标**
- Arch Linux + Sway（Wayland）上一键把桌面 Win98 化，覆盖 GTK / Qt / Sway / Waybar / 终端 / 输入法 / 通知 / 启动器 / Firefox。
- 每个模块**独立可选**，每个改动**可回滚**。
- 不覆盖用户已有配置：只做 `include` 片段或在用户确认后接管文件。

**非目标（明确不做）**
- 不支持 Debian/Fedora/NixOS；不提供 deb/rpm/官方仓库包。
- 不支持 hyprland/niri/其他合成器（目录结构留位，不实现）。
- 不打包任何微软版权素材（音效、壁纸、字体原始文件）。见 §6。
- 不追求 Qt / libadwaita 应用 100% 还原（只能"半像"，README 必须如实标注）。

---

## 2. 目录结构

```
install.sh              入口：参数解析 → preflight → 模块选择 → apply
uninstall.sh            按 manifest 回滚全部改动
lib/common.sh           日志、die、确认、常量（SWAY98_VERSION）
lib/detect.sh           发行版/会话/输出/locale/程序 探测
lib/manifest.sh         事务层：备份、manifest 记录、install_file/dir、record_cmd、restore
lib/edit.sh             include_block（标记块）、ini_set（INI 键值）、block_replace
lib/fetch.sh            http_get、archive_org_fetch（metadata API + sha1 校验）、git_clone_pinned
lib/menu.sh             交互式模块选择（gum 可选，纯 bash 兜底）
modules/<id>/module.sh  模块实现（契约见 §3）
modules/<id>/files/...  模块自带的配置/样式资产
docs/                   兼容性、故障排查（面向用户）
tests/                  shellcheck + 干跑冒烟
```

---

## 3. 模块契约（唯一写法，勿另创）

```bash
# modules/waybar/module.sh
SWAY98_MODULE_ID="waybar"
SWAY98_MODULE_DESC="Win98 taskbar as a Waybar at the bottom edge"
SWAY98_MODULE_SCOPE="user"            # user | system
SWAY98_MODULE_RECOMMENDED="yes"       # 'r' 快捷集是否包含
SWAY98_MODULE_REQUIRES="theme"        # 依赖的模块 id，空格分隔（只提示不强制）
SWAY98_MODULE_NEEDS_PKGS="waybar"     # Arch 包名，preflight 只报告不安装

sway98_apply()  { ... }               # 必写
sway98_revert() { ... }               # 可选：仅用于 manifest 无法表达的动作
```

规则：
- 元数据变量在 **sourcing 时**读取（`lib/menu.sh` 用子 shell source 取变量）。
- `sway98_apply` 在 **子 shell** 中执行（`( source module.sh; sway98_apply )`），因此模块可以随意定义局部函数/变量，不会污染主进程。
- 一切文件写入必须走 `install_file` / `install_dir` / `ini_set` / `include_block`——**它们才会写 manifest**。手写 `cp`/`sed -i` 到用户目录属严重违规（无法回滚）。
- 需要执行的外部命令（`gsettings`、`flatpak override`、`fc-cache`）用 `record_cmd "<幂等的反向命令>"` 记录回滚命令。
- 需要 sway 运行时生效的（`exec waybar`、开机音）写到 `~/.config/sway/conf.d/sway98.d/<id>.conf`，由 sway98 主片段通配 `include`。
- 缺依赖时 `warn` + `return 0`（跳过该模块并计入摘要），**不要**擅自 `pacman -S`。

---

## 4. 核心 lib API（改模块前先看实现）

| 函数 | 作用 |
|---|---|
| `info/warn/err/ok/dry/step` | 日志，同时落 `$STATE/log/install-<ts>.log` |
| `die <msg>` | 报错退出 |
| `confirm <prompt>` | 交互确认（`--no-prompt` 下自动 yes） |
| `is_dry_run` | 全局 `--dry-run`：所有写操作只打印不执行 |
| `backup_path <path>` | 复制到 `$STATE/backups/<ts>/...` 并返回路径 |
| `install_file <src> <dest>` | 备份→写入→记 manifest（create/modify） |
| `install_dir <src-dir> <dest-dir>` | 逐文件 install_file + 记录目录创建 |
| `record_cmd <module> <revert-cmd>` | 记录一条回滚命令（按逆序执行） |
| `include_block <file> <block-id> <line>...` | 用 `# >>> id >>>` / `# <<< id <<<` 标记块幂等加一行 include |
| `ini_set <file> <section> <key> <value>` | 幂等改 INI 键，首次改动时整文件进 manifest；支持 LF / CRLF，生成行沿用首行换行符，新文件用 LF |
| `http_get <url> <dest>` | curl 带重试/超时/UA |
| `archive_org_fetch <item> <remote-path> <dest> <sha1>` | 见 §6，唯一允许的微软素材下载方式 |
| `git_clone_pinned <url> <ref> <dest>` | 浅克隆并 checkout 指定 commit，校验存在 |

`$STATE` = `${XDG_STATE_HOME:-~/.local/state}/sway98`。
manifest 为 TSV 三件套：`manifest/files.tsv`（module/action/path/sha_new/sha_old/backup）、`manifest/commands.tsv`（module/revert_cmd）、`manifest/modules.tsv`（module/version/timestamp）。

---

## 5. 安全与可回滚（不可协商）

1. **默认 dry-run 安全**：所有写路径先过 `is_dry_run`，`--dry-run` 必须零副作用（不建目录、不写 manifest）。
2. **只碰表内路径**：`$HOME` 下的配置文件，或 `SCOPE=system` 模块明确声明的 `/usr/...`、`/etc/...`。禁止 `rm -rf` 无 `--` 保护的路径，禁止通配删除。
3. **接管已有文件必须先问**：目标已存在且不属于本项目 → `confirm` 后才覆盖，否则跳过并在摘要里说明。
4. **卸载必须完整**：`uninstall.sh` 依据 manifest 逆序执行命令、恢复备份、删除新建文件与空目录。任何"装了但卸不掉"的改动视为 bug。
5. **系统级模块**（保留给后续里程碑的 `sddm`/`plymouth`）：必须 `--system` 显式开启，README/PLAN 里标注变砖风险。

---

## 6. 微软素材政策（重要）

- 仓库**只存下载地址与校验值，不存素材本体**。
- 下载脚本：`modules/sounds/fetch-ms-sounds.sh` + `modules/sounds/sources.tsv`
  （列：`主题名 <TAB> archive.org item <TAB> 远端路径 <TAB> sha1`）。
- **必须用 `archive_org_fetch`**：先查 `https://archive.org/metadata/<item>` 拿 `server`/`dir`，再直连
  `https://<server><dir>/<urlencoded path>` 下载，最后校验 sha1。
  原因（实测，别改回去）：`https://archive.org/download/...` 的 302 会指向 `dnXXXXXX.ca.archive.org` 一类节点，
  在部分网络下 **TLS 直接断连（unexpected eof）**，同一文件直连 metadata 给出的节点则 200 且 sha1 一致。
  实测记录：通用 URL 连续 5 次失败，直连节点 1 次成功（693212 字节，sha1 `5427a0f8…`）。
- README 必须声明：素材版权属 Microsoft，仅在用户主动执行时下载，仓库不分发。

---

## 7. 代码风格

- Bash 5，脚本头固定：`#!/usr/bin/env bash` + `set -euo pipefail`。
- 运行期依赖只允许：`bash`、`coreutils`、`curl`、`git`、`grep`/`sed`/`awk`（Arch 基础包）。`gum` 为可选增强。
- **shellcheck 必须零告警**（`make check`）。习惯写法：数组引用加引号、`[[ ]]`、`read -r`、避免 `ls` 解析。
- 变量/函数：`sway98_*`（对外）、`_sway98_*`（内部）、全局大写。
- 语言策略：**代码注释、README、CREDITS 用英文**（面向 GitHub 受众）；**AGENTS.md、PLAN.md、docs 中文**（本地工作文档，发布前可择机翻译）。
- **`PLAN.md` 是本地工作文档，已列入 `.gitignore`，禁止提交**：其中的决策记录、风险登记与待定问题只给维护者看。因此不要在任何入库文件里把它写成链接——README 只说明"实施计划保存在本地"。
- 提交信息：英文，`<area>: <imperative summary>`，例如 `sway: add marker include block`。

---

## 8. 常用命令

```bash
./install.sh --list                     # 列出模块与状态
./install.sh --dry-run --all            # 零副作用预演（CI 用）
./install.sh                            # 交互选择
./install.sh --modules theme,gtk,sway   # 非交互
./uninstall.sh                          # 按 manifest 全量回滚

make check                              # shellcheck + 干跑 + 沙箱往返（发布前必跑）
make check-real                         # 对真实 Chicago95 做一次装→卸（覆盖符号链接与深目录）
tests/run-sandbox.sh dry-run            # 只跑干跑断言
tests/run-sandbox.sh roundtrip          # 装→重装→卸，要求沙箱 $HOME 逐字节还原
tests/verify-real-tree.sh               # 真素材版：入口与 make check-real 相同
tests/screenshots.sh                    # 在一次性无头 sway 里重生成 README 截图
```

**截图必须用 `tests/screenshots.sh` 生成**，不要在真实桌面截：真桌面截图会带出浏览器标签、会话 URL、
订阅链接、Wi-Fi 名称。脚本会（a）用私有 runtime dir / 私有 D-Bus / 私有 XDG_CONFIG_HOME 起 headless sway，
（b）只装本仓库的模块资产，（c）把 Waybar 的 SSID 单元格替换成信号强度。改脚本前先读 `docs/screenshots/README.md`。

沙箱在 `tests/sandbox/`，用 `$HOME`/`XDG_STATE_HOME` 指向临时目录实现，`SWAY98_NO_GSETTINGS=1`
阻止测试碰到真实 dconf。**绝不**在自己日常账户下直接跑 `./install.sh --yes --all` 做测试；
`make check-real` 需要 `SWAY98_THEME_SRC` 指向一份 Chicago95 检出（没有会自动 SKIP 并返回 0）。

---

## 9. 已知坑（踩过，别重踩）

### 9.1 事务层（这些是真 bug，会被 `make check` 抓住）

| 现象 | 根因 | 正确写法 |
|---|---|---|
| manifest 里 `action` 列为空，卸载时 `unknown manifest action '<path>'` | `awk` 没有匹配也返回 **0**，`if prev="$(awk ...)"; then` 被误判为真 | 函数内显式 `[[ -n "$out" ]] \|\| return 1`，见 `_manifest_earliest_record` |
| 卸载后 `$HOME` 残留一堆空目录树 | `install_file` 里用 `mkdir -p` 建父目录，没有记账 | 一律走 `_manifest_record_created_dirs`（逐级创建 + 记录，浅层在前，卸载时 `tac` 反序 rmdir） |
| 卸载后残留几千个**悬空符号链接** | 批量路径只 `find -type f` 记账；Chicago95 图标主题 11k 条目里绝大多数是 symlink | 批量路径额外跑一遍 `find -type l` 记账；增量路径用 `install_symlink`（`ln -sfn`，不 dereference） |
| 卸载后残留子目录（`cp -a` 的中间目录） | 批量拷贝只记了顶层 dest，没记子目录 | `_install_tree_create` 里 `find "$dest" -mindepth 1 -type d` 全部记账（浅层在前） |
| 安装器在非 Arch 机上静默退出、什么都不输出 | 函数返回非 0 且被 `$(...)` 捕获，`set -e` + `pipefail` 直接杀进程 | 探测类函数**永远返回 0**（`pacman_missing`），或调用处用 `if`/`\|\| true` 兜住 |
| 启动时报 `log/install-*.log: No such file or directory` | 日志文件路径先于目录创建被赋值 | 先 `mkdir -p` 那一级目录；同时 `_log` 追加日志失败不能致命 |
| `[[ -n "$x" && ( -f f \|\| is_dry_run ) ]]` 恒为真 | `[[ ]]` 里的裸词是**字符串**，不是函数调用 | 把函数调用放外面：`if [[ -f f ]] \|\| is_dry_run; then ...` |
| shellcheck `-x` 报 `SC2128: expanding an array` | 脚本里的变量名与被 source 的库里的数组变量重名（如 `out`） | 局部变量起独特名字（`dest_file`），别用 `out`/`i` 这类通用名 |

**测试纪律**：以上六条里有四条是 `tests/run-sandbox.sh` 抓出来的，两条是真素材实测抓出来的。
新增"批量拷贝/删除"类优化后，**必须**跑 `make check` **并且**用真实 Chicago95 跑一次
`bash tests/verify-real-tree.sh`（见下），因为桩目录太规整，覆盖不到符号链接与深层目录。

**shellcheck 注意**：`# shellcheck source=` 的相对路径是按**当前工作目录**解析的，不是脚本所在目录 —— 所以统一写 `source=lib/xxx.sh`，并且只在仓库根目录跑 shellcheck（Makefile 就是这么做的）。

### 9.2 主题类（用户会遇到的）

| 现象 | 处理 |
|---|---|
| archive.org 下载 TLS 断连 | 见 §6，走 metadata API 直连节点 |
| 重复安装导致配置块叠加 | 一律用 `include_block`/`ini_set`，禁止裸追加 |
| sway 窗口配色不生效 | 主片段必须在用户 `config` **末尾** include（后者覆盖前者） |
| GTK 应用改了设置没变化 | 需重启应用；GTK 只读启动时的 settings.ini |
| Firefox 界面没变 | 必须完全退出（`Ctrl+Shift+Q`）再启动；userChrome 属 best-effort，大版本可能失效 |
| fcitx5 在 X11 应用不生效 | 需 `dbus-update-activation-environment`（模块写 sway 片段解决） |
| Qt 应用不跟主题 | `QT_QPA_PLATFORMTHEME=gtk3` 必须在应用启动前存在于环境里；TTY 启动的 sway 不读 environment.d，要写 `~/.profile` |
| Plymouth / SDDM 改动 | v0.3 才做，需显式 `--system`，README 给 `arch-chroot` 回滚步骤 |

---

## 10. 路线图

见 `PLAN.md`（本地、不入库，见 §7 语言策略）。当前实现范围以其勾选框为准；新增模块前先在 `PLAN.md` 里把它加进模块矩阵。
