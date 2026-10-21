# DockSide

把 macOS Dock 栏左右两侧的空白利用起来，像小组件一样显示信息。

## 安装
```bash
./build.sh --install
```
需要 Xcode 或 Command Line Tools（`xcode-select --install`），macOS 13+。

首次启动后，在「系统设置 › 隐私与安全性 › 辅助功能」里允许 DockSide（用于读取 Dock 位置）。
重新打包后签名会变，如组件不显示，在辅助功能列表里删掉 DockSide 再重新允许即可。

## 使用
点击菜单栏的 Dock 图标：
- 「左侧」「右侧」子菜单里勾选要显示的组件，选择自动保存
- 「开机自动启动」
- 「退出 DockSide」

## 内置组件
时钟、日期、CPU、内存、电量

## 添加新组件
在 `Sources/DockSide/Widgets.swift` 的 `allWidgets` 里加一行：
```swift
WidgetDef(id: "hello", name: "问候") { AnyView(Ticking(every: 60) { Text("你好") }) },
```

## 已知限制
- 目前只支持 Dock 在屏幕底部
- Dock 自动隐藏时组件也会隐藏
