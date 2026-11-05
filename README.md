# 相册整理（PhotoOrganizer）

一个自己用的 iPhone 相册分析工具。**全部在手机本地分析，照片不会上传到任何服务器。**

## 能做什么

- 找出**重复照片**（原图字节完全相同）
- 找出**相似照片**（连拍、角度几乎一样）
- 找出**模糊照片**（和本相册的清晰度中位数比）
- 找出**大文件**，按体积排序
- 按内容分类：**发票票据 / 二维码 / 文档 / 截图 / 人物 / 美食 / 风景 / 宠物 / 隐私照片 / 隐私视频 / 其他**
- 隐私有照片和视频两类，同一套判定口径；不进「建议清理」，可在「我的」里整体隐藏
- 选中删除（30 天内在「最近删除」可恢复）、逐张滑动筛查（左滑待删、批量删除）、视频转 720p
- 分类里点一张卡片就地下钻到那一类，能多选、能删、能看大图
- 内置新手教程（5 页）+ 首页首启提示卡 + 常见问题 + 邮件反馈（我的 → 帮助与支持）
- **增量扫描**：算过的照片存本地，第二次扫描通常几十秒；中途被打断也能从断点接着跑

扫描本身不改动任何照片，只有点删除才会真的删。

## 怎么拿到安装包

iOS 安装包必须在 macOS 上编译，这里用 GitHub 免费的 macOS 机器自动完成，不需要自己有 Mac。

1. 打开仓库的 **Actions** 标签
2. 点最新一次运行（绿色勾）
3. 页面底部 **Artifacts** → 下载 `PhotoOrganizer-ipa-macos-15`
4. 解压得到 `PhotoOrganizer.ipa`

## 怎么装到 iPhone

需要用 Windows 上的 **Sideloadly**（免费）签名安装：ipa 拖进去 → 填 Apple ID → Start。装完到 **设置 → 通用 → VPN 与设备管理** 信任证书。

免费证书 7 天过期，过期重新签一次即可，照片不受影响。

## 扫描会分两次出结果

- **第一段**（通常 1 分钟内）：重复 / 相似 / 模糊 / 截图，结果页直接可操作
- **第二段**（后台，顶部有横幅）：内容分类，慢得多，边跑边补

扫描期间别锁屏、别切后台，否则系统会掐断解码和识别请求。

## 项目结构

```
AGENTS.md                      AI 接手项目的入口（铁律、文档路由）
docs/                          项目文档（架构、设计、开发、使用说明…）
PhotoOrganizer.xcodeproj       Xcode 工程
PhotoOrganizer/
  PhotoOrganizerApp.swift      App 入口
  Info.plist                   权限声明 + 版本号（唯一生效处）
  Models/PhotoItem.swift       数据模型
  Services/
    PhotoLibraryService.swift  相册读取、缩略图、原图、删除
    AnalysisEngine.swift       特征、分组、打分、两阶段调度
    ContentAnalyzer.swift      Vision 分类 / OCR / 二维码
    VideoCompressor.swift      视频转 720p
  Views/ContentView.swift      首页 / 扫描 / 结果页
  Views/DashboardView.swift    空间看板
  Views/SwipeTriageView.swift  逐张过（含视频播放）
  Views/TutorialView.swift     新手教程 5 页（示意图全部现画）
  Views/PhotoPreviewView.swift 大图与视频
maestro/                       云端 UI 用例
.github/workflows/build.yml    自动编译出包
```

## 文档

| 想知道 | 看 |
|---|---|
| 怎么用、数字怎么读、误判怎么办 | [docs/user-guide.md](docs/user-guide.md) |
| 内部怎么跑、判定口径 | [docs/architecture.md](docs/architecture.md) |
| 怎么改代码、怎么发版、回归清单 | [docs/development.md](docs/development.md) |
| 现在做到哪、下一步做什么 | [docs/TODO.md](docs/TODO.md) |
| 为什么这么设计 | [docs/project-overview.md](docs/project-overview.md) |
| 新手教程讲什么、怎么翻页 | [docs/onboarding-spec.md](docs/onboarding-spec.md) |
| 颜色 / 字号 / 交互规则 | [docs/DESIGN.md](docs/DESIGN.md) |
| 类型与调用契约 | [docs/component-api.md](docs/component-api.md) |
