# 相册整理（PhotoOrganizer）

一个自己用的 iPhone 相册分析工具。**全部在手机本地分析，照片不会上传到任何服务器。**

## 这一版能做什么

- 找出**重复照片**（内容完全相同）
- 找出**相似照片**（连拍、角度几乎一样）
- 找出**模糊照片**
- 找出**截图**
- 生成一份清单，可以导出分享

> 第一版**只看不删**，不会动你任何照片。

## 为什么用 GitHub 编译

iOS 安装包必须在 macOS 上编译，而这里用 GitHub 免费的 macOS 机器自动完成，不需要自己有 Mac。

每次把代码推上来，它会自动：

1. 在 macOS 上编译
2. 打包成 `PhotoOrganizer.ipa`
3. 提供下载

## 怎么拿到安装包

1. 打开这个仓库的 **Actions** 标签
2. 点最新一次运行（绿色勾）
3. 页面底部 **Artifacts** → 下载 `PhotoOrganizer-ipa`
4. 解压得到 `PhotoOrganizer.ipa`

## 怎么装到 iPhone

需要用 Windows 上的 **Sideloadly**（免费）签名安装，详见交付时给的安装说明。

## 项目结构

```
PhotoOrganizer.xcodeproj       Xcode 工程
PhotoOrganizer/
  PhotoOrganizerApp.swift      App 入口
  Info.plist                   权限声明
  Models/PhotoItem.swift       数据模型
  Services/
    PhotoLibraryService.swift  相册读取与权限
    AnalysisEngine.swift       哈希、清晰度、分组算法
  Views/ContentView.swift      全部界面
.github/workflows/build.yml    自动编译配置
```
