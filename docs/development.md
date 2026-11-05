# 开发、构建与回归

## 环境事实

| 项 | 情况 |
|---|---|
| 开发机 | Windows（没有 Mac，也不能装 Xcode） |
| 编译器 | 只存在于 GitHub Actions 的 macOS 机器上 |
| 仓库 | `github.com/EddieZuiShuai/PhotoOrganizer`，主分支 `main` |
| 结论 | **本机无法编译。push 即构建，语法错误只能从 CI 日志里看。** 所以每次提交尽量小、只做一件事 |

## 从改代码到装到手机

```bash
git add -A
git commit -m "改了什么 + 为什么（中文，一句话说清）"
git push
```

push 之后：

1. `build.yml` 自动触发（`main` / `master` 分支，或手动 `workflow_dispatch`）。
2. 等待 Actions 跑完（矩阵：`macos-15` 与 `macos-14` 各编一份，任一失败不影响另一份）。
3. 下载 artifact `PhotoOrganizer-ipa-macos-15`，解压出 `PhotoOrganizer.ipa`。
4. Windows 上用 Sideloadly 签名安装（或双击工作区的 `一键重签安装.cmd`）。

> 同一分支只保留最新一次构建（`concurrency` + `cancel-in-progress`）。推太快会把上一次取消掉，这是预期行为。

### 想省掉手动刷新

工作区根目录（不在本仓库）的 `watch_build.py` 会盯最新一次构建，编完弹系统通知 / 响铃 / 自动打开结果页：

```bash
python watch_build.py            # 盯最新一次
python watch_build.py --sha abc1234
python watch_build.py --test     # 只测通知通道
```

## 版本号

**唯一生效位置：`PhotoOrganizer/Info.plist`**

| 键 | 当前值 | 说明 |
|---|---|---|
| `CFBundleShortVersionString` | `1.4` | 对用户可见的版本 |
| `CFBundleVersion` | `17` | 构建号，每次装到手机都要 +1，否则 Sideloadly 可能装不上/不覆盖 |

> `project.pbxproj` 里的 `MARKETING_VERSION = 1.0` / `CURRENT_PROJECT_VERSION = 3` 是模板残留，**不起作用**（`INFOPLIST_FILE` 指向的 plist 里写了硬编码值，会覆盖它们）。别去改那里。

## CI 工作流

### `build.yml` — 出安装包

- 触发：push 到 `main` / `master`，或手动。
- 编译：`xcodebuild -configuration Release -destination 'generic/platform=iOS'`，显式关签名（`CODE_SIGNING_ALLOWED=NO`），产物在 CI 里打包成 ipa。
- 产物保留 30 天。

### `ui-test.yml` — 云端 UI 测试

- 触发：**仅手动**（`workflow_dispatch`）。
- 流程：选一台最新 iPhone 模拟器 → 编 Debug 模拟器版 → 装 App → 灌 12 张测试图（`UITestFixtures/`）→ 授权 → Maestro 跑 8 条用例 → 传报告与截图。
- 用例覆盖：启动扫描、跨标签选中、逐张过滑动/撤销、预览标记、全选清空、布局三档、模糊三档、逐张过标记回传。
- 授权顺序是硬要求：`addmedia` → 启动一次 → `grant photos`。**不能** `grant photos-add`（会把权限记成"仅添加"，启动弹框挡住界面）。顺序错了所有用例都会挂在第一步。

### 本机取回测试结论

```bash
python _ci_check.py                 # 等最新一次跑完并汇总
python _ci_check.py --run 41948076790
```

产物落在 `_ci_artifacts/`（已 gitignore）。脚本从 `~/.git-credentials` 读 token，走无代理 opener（系统代理会劫持 GitHub API）。

## 回归清单（每次发版前逐条勾）

云端（`ui-test.yml` 全绿即可覆盖 1~8）：

- [ ] 01 启动 → 授权 → 扫描出结果，张数 > 0
- [ ] 02 网格选中后切标签，选中不丢；分组页选中正常
- [ ] 03 逐张过：右滑保留 / 左滑标记 / 撤销回到正确那张
- [ ] 04 长按进大图、标记待删、返回后选中保留
- [ ] 05 全选 / 取消全选 / 清空
- [ ] 06 布局三档切换；分组页不显示布局按钮
- [ ] 07 模糊页三档灵敏度切换
- [ ] 08 逐张过连续标记后关闭，标记带回列表

真机（云端替代不了）：

- [ ] 2 万张的真实相册：阶段一 90 秒内出结果，全程不闪退
- [ ] 阶段二跑完，发票票据数 > 0，内容分类有非"其他"的项
- [ ] 删 1 张 → 最近删除里能找到 → 恢复
- [ ] 选 600 张 → 弹二次确认（500 阈值生效）
- [ ] 视频转 720p：体积变小、原片被替换、可在最近删除找回
- [ ] 导出清单内容不为空，包含分类统计

## 提交信息规范

中文，写"改了什么 + 为什么"，不要写"update"：

```
修「切页签内容变空」+ 分组卡片加放大按钮 + 去掉网图表情分类
构建号提到 16（这一版扫描改成两阶段出货，需要和上一版区分开）
扫描稳定性三改：①扫描期间保持屏幕常亮 ②逐张套 autoreleasepool 解决 jetsam ③内存低于 220MB 跳过大图补读
```

一个提交只解决一件事。涉及阈值变动的，提交信息里写清旧值和新值。

## 故障对照

| 现象 | 先查什么 |
|---|---|
| CI 编译失败：找不到符号 | 新增 `.swift` 是否漏了 `project.pbxproj` 四处引用（`PBXBuildFile` / `PBXFileReference` / 分组 children / Sources） |
| CI 编译失败：API 不可用 | 部署目标是 iOS 16.0，别用 17+ 的 API，或加 `if #available` |
| UI 测试全挂在第一步 | 授权顺序；是否误 grant 了 `photos-add`；「开始扫描」是否在首屏之外（小屏要先滚） |
| UI 测试断言全 0 | 缩略图没取到。跑 `-PODiag` 看 `Documents/po-diag.txt` |
| `_ci_check.py` 连不上 | 先看是不是系统代理劫持（`urllib` 会读注册表代理）；脚本已用空 ProxyHandler，若仍失败查 token |
| 装到手机打不开 | 证书 7 天过期；或构建号没 +1 导致覆盖失败 |
| 真机扫描中途闪退 | 是否去掉了 `autoreleasepool`；内存探针阈值是否被改高 |

## 目录速查

```
PhotoOrganizer.xcodeproj     工程（老式文件引用，加文件要手改）
PhotoOrganizer/              App 源码
  Info.plist                 权限声明 + 版本号（唯一生效处）
UITestFixtures/              12 张测试图，CI 灌进模拟器
maestro/flows|subflows/      UI 用例
.github/workflows/           build.yml（出包）+ ui-test.yml（UI 测试）
scripts/check_triage_shots.py  逐张过截图的前后像素比对
_ci_check.py                 本机取回 CI 结论
```
