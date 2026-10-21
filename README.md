# DockSide

> 把 macOS Dock 栏左右两侧浪费的空白利用起来，像小组件一样显示时钟、系统状态和待办。

Dock 居中时，两侧常年空着一大片。DockSide 会实时读取 Dock 的位置和宽度，在两侧空白处放上半透明的毛玻璃胶囊组件，Dock 变宽变窄、增删图标都会自动跟随。

## 功能

- **自动贴合 Dock**：跟随 Dock 宽度变化，字号按 Dock 高度自动调整，组件太多时整排等比缩小，不遮挡 Dock 图标
- **小组件自选**：菜单栏图标里分「左侧」「右侧」勾选要显示的组件，选择自动保存
- **待办清单**：Dock 旁显示下一条待办，点圆圈完成，点文字打开清单；支持导入导出
- **轻量常驻**：不占 Dock 图标，所有桌面空间都显示，可设开机自启
- **Apple 芯片 + Intel 通用**，macOS 13 及以上

## 内置组件

| 组件 | 说明 |
| --- | --- |
| 时钟 | 时:分:秒 |
| 日期 | 月日 + 星期 |
| CPU | 实时占用率 |
| 内存 | 已用内存占比 |
| 电量 | 电池百分比 |
| 待办 | 下一条未完成待办 + 剩余数量 |

## 下载安装

1. 到 [Releases](../../releases/latest) 下载 `DockSide.zip`，解压后把 `DockSide.app` 拖进「应用程序」
2. 应用未经 Apple 公证，首次打开被拦截时，在终端运行：
   ```bash
   xattr -cr /Applications/DockSide.app
   ```
3. 打开后，在「系统设置 › 隐私与安全性 › 辅助功能」里允许 DockSide（用于读取 Dock 位置）

> 更新版本后如果组件不显示，在辅助功能列表里删掉 DockSide 再重新允许即可。

## 使用

点击菜单栏的 Dock 图标：

- **左侧 / 右侧**：勾选要显示的组件
- **待办清单…**（⌘T）：添加、编辑、拖动排序、删除、清除已完成
- **导入待办…**：从文件导入
- **开机自动启动**
- **退出 DockSide**

### 待办导入格式

支持 txt / md / csv 文件或剪贴板，每行一条，自动跳过空行、Markdown 标题和重复项：

```markdown
- [ ] 写周报
- [x] 回复邮件
1. 买牛奶
* 预约牙医
```

导出为 Markdown 勾选清单，可再次导入。数据保存在 `~/Library/Application Support/DockSide/todos.json`。

## 从源码构建

需要 Xcode 或 Command Line Tools（`xcode-select --install`）：

```bash
./build.sh            # 生成 build/DockSide.app
./build.sh --install  # 生成并安装到 /Applications，然后启动
UNIVERSAL=1 ./build.sh  # 编译通用版（需要完整 Xcode）
```

推送到 `main` 分支后，GitHub Actions 会自动编译通用版并发布到 Releases。

## 添加新组件

在 `Sources/DockSide/Widgets.swift` 的 `allWidgets` 里加一行即可：

```swift
WidgetDef(id: "hello", name: "问候") { AnyView(Ticking(every: 60) { Text("你好") }) },
```

## 项目结构

```
Sources/DockSide/
├── main.swift          入口
├── AppDelegate.swift   菜单栏、布局、开机自启
├── DockLocator.swift   通过辅助功能 API 读取 Dock 位置，创建两侧悬浮窗
├── Widgets.swift       组件注册表、胶囊样式、自适应排布
├── WidgetStore.swift   每侧组件选择的保存
├── Metrics.swift       CPU / 内存 / 电量
└── Todo.swift          待办数据、导入导出、清单窗口
```

## 已知限制

- 目前只支持 Dock 在屏幕底部
- Dock 自动隐藏时组件也会隐藏
- 多显示器下只显示在 Dock 所在的屏幕
