---
layout: home

hero:
  name: "SQL Lab"
  text: "能跑、能量化对比的 MySQL 优化实战集"
  tagline: 80 个精选案例 · 百万级真实数据 · Docker 一键复现 · bad/good EXPLAIN 量化对比
  actions:
    - theme: brand
      text: 快速开始
      link: /guide/quick-start
    - theme: alt
      text: 浏览案例
      link: /cases/

features:
  - title: 真能跑
    details: Docker 起库 + 种子数据，30 秒内复现每个案例。不是贴截图，是真能 EXPLAIN 的可执行 SQL。
    icon: 🐳
  - title: 量化对比
    details: 每个案例给出 bad/good 的 EXPLAIN 扫描行数对比，用数字说话 -- 980,000 行 → 12 行。
    icon: 📊
  - title: 5.7 + 8.0 双版本
    details: 同时跑 MySQL 5.7 和 8.0，标注 ICP、降序索引、Hash Join 等版本差异，贴近真实生产。
    icon: 🔢
  - title: 场景驱动
    details: 不按教科书分类，按"订单深分页""手机号查用户"等真实生产场景命名，看完即用。
    icon: 🏷️
  - title: 精排文档
    details: VitePress 构建的在线文档站，bad/good diff 高亮、EXPLAIN 并排对比表、侧边栏分类导航。
    icon: 📖
  - title: AI 对话
    details: 接入 DeepWiki，可直接与仓库对话 -- "我的深分页怎么优化？"，AI 基于案例库回答你。
    icon: 🤖
---
