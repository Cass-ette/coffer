# Coffer v0.1.0 交付清单

## ✅ 自动化验证（已完成）

### Release 构建
- **状态**: ✅ PASSED
- **结果**: `** BUILD SUCCEEDED **`
- **位置**: `.build/Build/Products/Release/Coffer.app`

### 测试套件
- **状态**: ✅ PASSED
- **结果**: 63 tests, 1 skipped, 0 failures
- **测试模块**:
  - VaultCrypto: 8 tests ✓
  - Entry: 9 tests ✓
  - VaultFileStore: 4 tests ✓
  - VaultStore: 7 tests ✓
  - TOTP: 8 tests ✓
  - SearchIndex: 8 tests ✓
  - DEKStore: 10 tests ✓
  - UnlockService: 4 tests ✓
  - LockPolicy: 5 tests ✓

### 代码状态
- **Working tree**: Clean (计划文档已提交)
- **总提交数**: 55 commits
- **最后提交**: `2e00e32 docs(plan): record Task 17 and Task 19 implementation results`
- **敏感文件检查**: ✅ 无 `*.vault` / `*.bak*` 文件在仓库中
- **构建目录检查**: ✅ `.build` 已被 gitignore

---

## ⏳ 待完成项（需要真机操作）

### Step 2: 整机验收清单（对应 spec §10/§12）

请在真机上逐项测试并记录结果：

#### 成功标准（必须全部通过）

1. [ ] **标准 1 - 5 秒快速访问**
   - 操作: 重启 Mac → 登录 → 任意应用 `⌥Space` → 指纹 → 敲 2-3 字 → `↵` 复制 → `⌘V` 粘贴
   - 要求: 总时长 ≤ 5 秒
   - 结果: _____

2. [ ] **标准 2 - 30 秒内定位权限**
   - 操作: 搜"内网"或点"内网系统"分组
   - 要求: 30 秒内列出所有内网系统访问权限
   - 结果: _____

3. [ ] **标准 3 - 加密文件安全性**
   - 操作: `cp ~/Library/Application\ Support/Coffer/vault.vault /tmp/` 然后 `strings /tmp/vault.vault | grep -i password`
   - 要求: 无明文密码泄漏
   - 结果: _____

#### 功能验收（14 项）

4. [ ] **首次运行流程**
   - 删除 `~/Library/Application Support/Coffer/` 重新启动
   - 创建 8 位主密码 → 生物识别录入 → 完成初始化
   - 结果: _____

5. [ ] **六种条目类型创建**
   - login: 标题/用户名/密码（生成器）/URL/标签
   - access: 地址/登录方式/网络位置/权限备注
   - apiKey: 提供商/密钥/环境变量前缀
   - sshKey: 主机/用户/私钥
   - totp: 手动输入 secret 或粘贴 otpauth:// URI，验证码实时刷新
   - secureNote: 正文 + 附件（图片/文档，2MB/5 文件限制）
   - 结果: _____

6. [ ] **搜索功能**
   - 搜索框输入 → 模糊匹配 → 高亮显示
   - 敏感字段（密码/密钥/正文）不出现在搜索联想
   - 结果: _____

7. [ ] **分组与标签**
   - 创建分组 → 条目移入分组 → 侧边栏点击分组过滤
   - 添加标签 → 侧边栏标签列表 → 点击标签过滤
   - 结果: _____

8. [ ] **详情页操作**
   - 显形按钮 → 密码/密钥可见
   - 复制按钮 → 剪贴板 45 秒倒计时 → 自动清空
   - TOTP 验证码 30 秒倒计时刷新
   - 链接按钮 → 浏览器打开 URL
   - 结果: _____

9. [ ] **编辑与删除**
   - 编辑条目 → 修改字段 → 保存 → 列表更新
   - 删除条目 → 确认对话框 → 列表移除
   - 结果: _____

10. [ ] **全局热键浮窗**
    - `⌥Space` 呼出浮窗
    - 已锁定状态 → 指纹解锁 → 浮窗显示
    - 已解锁状态 → 直接显示
    - 结果: _____

11. [ ] **浮窗键盘导航**
    - `↑↓` 选择条目
    - `Tab` 循环复制目标（用户名 → 密码 → 地址）
    - `↵` 复制当前目标
    - `⌘↵` 打开 URL
    - `Esc` 关闭浮窗
    - 结果: _____

12. [ ] **自动锁定**
    - 设置 1 分钟闲置锁定
    - 不操作 1 分钟 → 自动锁定
    - 睡眠/锁屏/屏保/切用户 → 立即锁定
    - 结果: _____

13. [ ] **设置页功能**
    - 热键录制 → 修改热键 → 冲突提示（如被其他应用占用）
    - 自动锁定时长 → 改为 5 分钟 → 立即生效
    - 剪贴板清空时长 → 改为 30 秒 → 立即生效
    - 结果: _____

14. [ ] **主密码修改**
    - 输入当前密码 → 新密码（8 位+）→ 确认 → 验证
    - 错误旧密码 → 报错拒绝
    - 不匹配确认 → 报错拒绝
    - 成功后解锁仍需新密码
    - 结果: _____

15. [ ] **备份与恢复**
    - 检查 `~/Library/Application Support/Coffer/` 有 `vault.bak1` / `vault.bak2`
    - 破坏 `vault.vault` → 启动 → 从备份恢复 → 数据完整
    - 结果: _____

16. [ ] **退出与重启**
    - 退出应用 → 数据持久化
    - 重新启动 → 锁定状态 → 指纹解锁 → 数据完整
    - 结果: _____

17. [ ] **压力测试**
    - 创建 100+ 条目 → 搜索响应时间 < 200ms
    - 快速连按 `⌥Space` → 无崩溃/卡顿
    - 结果: _____

---

### Step 3: 截图

请手动截取以下三张截图并放入 `assets/brand/screenshots/`：

1. [ ] `main.png` - 主窗口三栏布局（侧边栏 + 列表 + 详情）
2. [ ] `lock.png` - 锁定页（Touch ID 按钮 + 主密码备选）
3. [ ] `panel.png` - 浮动搜索面板（搜索框 + 结果列表 + TOTP 倒计时）

截图要求：
- 尺寸建议: 宽度 1200-1600px
- 格式: PNG
- 内容: 使用示例数据，避免真实敏感信息

---

### Step 4: 版本号配置

需要修改以下文件设置版本号为 `0.1.0`：

1. [ ] `project.yml` - `MARKETING_VERSION: "0.1.0"`
2. [ ] `CofferCore/Package.swift` - 检查无需修改（库无独立版本）

修改后提交：
```bash
git add project.yml
git commit -m "chore: set version 0.1.0 for initial release"
git tag -a v0.1.0 -m "Release v0.1.0 - Initial public release"
```

---

### Step 5: GitHub 发布（⚠️ 需要明确确认）

**在执行前请确认：**

- [ ] 仓库名: `Cass-ette/coffer`
- [ ] 公开范围: Public
- [ ] 所有验收项已通过
- [ ] 截图已添加
- [ ] 版本号已配置

**执行命令:**

```bash
# 创建远程仓库并推送
cd ~/Projects/coffer
gh repo create coffer --public --source . --push

# 推送 tags
git push --follow-tags
```

**预期结果:**
- 输出 `https://github.com/Cass-ette/coffer`
- main 分支和 v0.1.0 tag 已推送

---

### Step 6: 终验

发布后检查：

- [ ] 浏览器打开 `https://github.com/Cass-ette/coffer`
- [ ] README 三张截图正常显示
- [ ] 无 `*.vault` / `*.bak*` / `.build` 进入仓库
- [ ] Tag `v0.1.0` 可见
- [ ] 所有 14 项验收结果填写完整

---

## 📊 实现统计

- **总任务数**: 20/20 ✅
- **总提交数**: 56 commits
- **代码行数**:
  - CofferCore: ~2500 行（含测试）
  - App: ~3500 行
- **测试覆盖**: 63 tests, 0 failures
- **开发周期**: 单日集中实现

---

## 🎯 下一步

1. 完成真机验收清单（14 项）
2. 添加 3 张截图
3. 配置版本号并打 tag
4. 确认后执行 GitHub 发布
5. 提交完整的验收记录

有任何问题请随时告知。
