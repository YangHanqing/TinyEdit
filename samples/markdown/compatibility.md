# Markdown 预览检查

[安装](#安装) · [第二个安装](#安装-1) · [编码标题](#%E5%AE%89%E8%A3%85) · [嵌套标题](#嵌套标题) · [代码](#代码)

普通段落，**粗体**、*斜体*、~~删除线~~、`inline code`、[链接](https://example.com) 和 <https://example.com>。
软换行继续同一段；  
两个空格硬换行。<br>HTML 换行。

长链接：<https://example.com/abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz>

## 安装

1. 第一项
   - 嵌套无序项
     - [x] 已完成
     - [ ] 未完成
   - 引用和代码：
     > 引用正文
     >
     > ### 嵌套标题
     >
     > ```json
     > {"中文": true, "count": 42}
     > ```
2. 第二项

> 外层引用
>> 内层引用，**粗体**。
>
> - 引用中的列表
> - 第二项

## 安装

重复标题应该生成 `安装-1`。

### 表格与图片

| 左对齐 | 居中 | 右对齐 |
| :--- | :---: | ---: |
| **标题**<br>第二行 | `x \| y` | 123 |
| ![原生图片](../../assets/screenshots/command-palette.png) | <img src="../../assets/screenshots/command-palette.png" width="180" height="100" alt="尺寸限制"> | ~~删除~~ |
| <img src='../../assets/screenshots/command-palette.png' width='560'> | 上文<br/>下文 | 456 |
| [很长链接](https://example.com/abcdefghijklmnopqrstuvwxyz/abcdefghijklmnopqrstuvwxyz/abcdefghijklmnopqrstuvwxyz/abcdefghijklmnopqrstuvwxyz) | 单元格中的长文本，用于检查窄窗口下的换行、对齐与横向滚动。 | 789 |

[![带链接图片](../../assets/screenshots/command-palette.png)](#代码)

![大图片](../../assets/screenshots/command-palette.png)

![缺失图片](missing.png)

![远程图片，只有点击才请求](http://localhost:18474/remote.png)

## 代码

```swift
// 复制后应保持原始缩进与中文
let message = "你好 👋"
if true {
    print(message)
}
```

```json
{"name": "TinyEdit", "ready": true, "count": 42, "none": null}
```

```unknown-language
<raw>不支持的语言保留纯文本</raw>
```

```html
<img src="never-load.png"><br>
```

---

<div>未支持的 HTML 显示源码</div>

## 结束

[返回顶部](#markdown-预览检查)
