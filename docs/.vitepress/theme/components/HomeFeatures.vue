<script setup lang="ts">
/**
 * HomeFeatures - 首页自定义内容区
 * 在 VitePress 默认 features 下方渲染：统计数据 + 分类导航 + 快速命令
 */
import { withBase } from 'vitepress'

const stats = [
  { number: '80', label: '精选案例' },
  { number: '7', label: '场景分类' },
  { number: '2', label: 'MySQL 版本' },
  { number: '100%', label: '可复现' },
]

const categories = [
  { icon: '🔑', name: '索引设计与失效', count: '18 个案例', link: withBase('/cases/indexing/01-deep-pagination') },
  { icon: '✏️', name: '查询改写', count: '14 个案例', link: withBase('/cases/query-rewrite/19-subquery-to-join') },
  { icon: '🔗', name: 'JOIN 优化', count: '9 个案例', link: withBase('/cases/join/33-small-drive-large') },
  { icon: '🔨', name: 'DDL 与大表', count: '10 个案例', link: withBase('/cases/ddl/42-online-ddl') },
  { icon: '🏗️', name: '架构级优化', count: '11 个案例', link: withBase('/cases/architecture/52-dynamic-filter') },
  { icon: '🔒', name: '事务与锁', count: '9 个案例', link: withBase('/cases/transaction/63-deadlock-analysis') },
  { icon: '⚡', name: '优化器与 8.0', count: '9 个案例', link: withBase('/cases/optimizer/72-descending-index') },
  { icon: '🚀', name: '全部案例', count: '查看总览', link: withBase('/cases/') },
]
</script>

<template>
  <!-- 统计数据 -->
  <div class="home-stats">
    <div v-for="s in stats" :key="s.label" class="home-stat-item">
      <div class="home-stat-number">{{ s.number }}</div>
      <div class="home-stat-label">{{ s.label }}</div>
    </div>
  </div>

  <!-- 分类导航 -->
  <div class="home-categories">
    <h2 class="home-categories-title">七大场景 · 80 个案例</h2>
    <p class="home-categories-subtitle">从索引失效到事务锁、从查询改写到 8.0 新特性，覆盖 MySQL 优化全链路</p>
    <div class="home-category-grid">
      <a
        v-for="c in categories"
        :key="c.name"
        :href="c.link"
        class="home-category-card"
      >
        <span class="home-category-icon">{{ c.icon }}</span>
        <div class="home-category-name">{{ c.name }}</div>
        <div class="home-category-count">{{ c.count }}</div>
      </a>
    </div>
  </div>

  <!-- 快速命令 -->
  <div class="home-quick-cmd">
    <h2 class="home-quick-cmd-title">30 秒快速开始</h2>
    <p class="home-quick-cmd-subtitle">复制以下命令，一键跑通第一个案例</p>
    <div class="home-cmd-block">
      <span class="cmd-comment"># 1. 克隆仓库</span><br>
      <span class="cmd-prompt">$ </span><span class="cmd-text">git clone https://github.com/slowleelab/sql-lab.git</span><br>
      <span class="cmd-prompt">$ </span><span class="cmd-text">cd sql-lab</span><br><br>
      <span class="cmd-comment"># 2. 启动 MySQL（5.7 + 8.0）</span><br>
      <span class="cmd-prompt">$ </span><span class="cmd-text">docker compose up -d</span><br><br>
      <span class="cmd-comment"># 3. 运行第一个案例</span><br>
      <span class="cmd-prompt">$ </span><span class="cmd-text">./scripts/run-case.sh 01-deep-pagination</span>
    </div>
  </div>
</template>
