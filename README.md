# Kwrt 软件包编译

本仓库使用匹配的 Kwrt SDK 独立编译软件包并发布 IPK、Release 和软件包服务器内容

编译范围

```text
packages
luci + 中文翻译
routing
kiddin9
私有 LuCI feeds
```

`packages` 输入使用源码目录正则

```text
.*
luci-app
luci-app-(aria2|acme)
^[a-l]
^[^a-l]
```

默认值 `.*` 编译全部 managed feeds 软件包及其依赖

OpenWrt base、target-specific、kernel 和 kmod 由 Kwrt 构建并发布
