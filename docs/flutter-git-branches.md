# Flutter 端 Git 分支操作手册

> 仓库：`zhengmin486/otaku-data-platform`（monorepo）
> 你的范围：`app-client/`（Flutter）
> 更新：2026-10-20

---

## 0. 先认清你现在的位置

这一步最容易搞错，务必先看：

| 项目 | 现状 |
| --- | --- |
| 远程仓库 | 已有 `main`、`feat/source-pagination-and-fields`、`docs/legacy-asset-review` 三个分支 |
| 远程 `app-client/` | 只有一个 `README.md`，没有 Flutter 工程 |
| 你本地 `D:\otaku\app-client` | 完整 Flutter 工程，能构建，但**不是 git 仓库** |

结论：**你现在在这个目录里敲 `git branch` 会直接报 `not a git repository`。**
所以"弄分支"的第一步不是 `git branch`，而是**先把本地目录接上远程仓库**。

还有一件事：**不要** `git init` 完就 `git add . && git commit`。
那样会造出一条和远程毫无关系的提交历史，push 会被拒（non-fast-forward），
接着就得处理一堆无关历史合并。正确顺序是 `init → remote → fetch → checkout`，让本地历史直接继承远程。

---

## 1. 一次性接入（只做一次，约 3 分钟）

### 1.1 配好身份（不做这步 commit 会失败）

```bash
git config --global user.name "riceyu02"
git config --global user.email "你的GitHub邮箱"
```

### 1.2 把 `D:\otaku` 变成仓库并接上远程

```bash
# ① 先备份一份工程到仓库外面，出问题能还原
cd /d
cp -r otaku/app-client otaku-app-client-backup

# ② 进项目根目录
cd /d/otaku

# ③ 初始化仓库
git init

# ④ 接上远程（本机代理不支持 HTTP/2，这行必加，否则 fetch 报 502）
git remote add origin https://github.com/zhengmin486/otaku-data-platform.git
git config http.version HTTP/1.1

# ⑤ 只拉记录，不动你的文件
git fetch origin

# ⑥ 让本地 main 等于远程 main，并把仓库文件铺到工作区
rm app-client/README.md
git checkout -b main origin/main
```

第 ⑥ 步的 `rm` 是必须的：远程已有 `app-client/README.md`，你本地也有一个（`flutter create` 生成的），
不删就会报 `untracked working tree files would be overwritten by checkout`。
删的是模板默认 README，没有损失。

### 1.3 确认接好了

```bash
git status
git log --oneline -5
```

正常结果是：
- `git log` 能看到别人的提交（如 PR #13–#16 相关）
- `git status` 里 `app-client/lib/`、`pubspec.yaml`、`android/` 等显示为 **untracked**——这正是你的工作量，等着被提交
- `.workbuddy/`、`app-client/build/`、`.dart_tool/` **不应该**出现在列表里（已被 `.gitignore` 挡住）

如果 `.workbuddy/` 出现了，说明根 `.gitignore` 没生效，先别提交，回头查。

---

## 2. 分支到底是什么

一句话：**分支是一条独立的开发线。你在上面怎么改，都不影响 `main`，也不影响别人的分支。**

三条铁律：

1. **`main` 是只读的。** 任何人都不直接往 `main` 提交，包括你。所有改动走"分支 → PR → 合并"。
2. **一个分支只做一件事。** 分支里混进两件不相关的事，review 就没法做，出问题也没法单独回滚。
3. **分支从最新的 `main` 切出来。** 基于旧代码开分支，等于给自己预埋冲突。

你只需要记四条命令：

| 目的 | 命令 |
| --- | --- |
| 开新分支 | `git switch -c feat/xxx` |
| 看现在在哪条分支 | `git branch`（当前分支前面有 `*`） |
| 切回主线 | `git switch main` |
| 删掉已合并的分支 | `git branch -d feat/xxx` |

> `git switch` 需要 Git 2.23+，你的机器是 2.55，没问题。
> 如果看到别人的教程写 `git checkout -b feat/xxx`，效果一样，`checkout` 是老写法。

---

## 3. 你要开的 6 条分支

| 顺序 | 分支名 | 交付内容 | 主要改动位置 | 前置依赖 |
| --- | --- | --- | --- | --- |
| 1 | `feat/flutter-scaffold` | 工程迁入 monorepo、目录骨架、主题、路由、dio 封装、错误模型、Mock 仓储、README | `app-client/**`、根 `README.md` | 无 |
| 2 | `feat/contents-list` | 列表页、分页加载、筛选、骨架屏、空态/错误态 | `app-client/lib/features/contents/` | 1 |
| 3 | `feat/contents-detail` | 详情页、封面、元信息、收藏入口占位 | `app-client/lib/features/detail/` | 1 |
| 4 | `feat/auth` | 登录/注册、令牌安全存储、401 拦截跳登录 | `app-client/lib/features/auth/` | 1 |
| 5 | `feat/collections` | 收藏列表、收藏/取消（幂等 PUT） | `app-client/lib/features/collections/` | 1 + 4 |
| 6 | `chore/release-build` | Android 签名、release 脚本、版本号规则、构建说明 | `app-client/android/`、`app-client/scripts/` | 1 |

依赖关系：

```
scaffold ──┬── contents-list
           ├── contents-detail
           └── auth ── collections
           └── release-build（最后做）
```

**`contents-list` 和 `contents-detail` 可以并行**，两者都只依赖 scaffold，互不依赖。
**`collections` 必须等 `auth` 合并**，因为它要拿登录态。

### 命名规则

- 前缀只用仓库现有的四种：`feat/` `fix/` `docs/` `chore/`
- 全小写，用短横线连接：`feat/contents-list` ✅ `feat/ContentsList` ❌ `feat/内容列表` ❌
- 名字要能看出做什么，不要 `feat/dev`、`feat/test`、`feat/update`
- **契约改动单独开 `docs/*` 分支**，不要混在 `feat/` 里。比如要改 `docs/openapi.yaml`，就开 `docs/collection-idempotent`

---

## 4. 一条分支从生到死

以 `feat/contents-list` 为例，完整走一遍。

### ① 回到主线，拿最新代码

```bash
git switch main
git pull
```

`git pull` = `git fetch` + `git merge`，把远程 `main` 的新提交拉到本地。
**不做这步就切分支，你就是基于旧代码开工。**

### ② 切出新分支

```bash
git switch -c feat/contents-list
```

`-c` 是 create，从当前所在的位置（此刻是最新 `main`）长出一条新线。
后续所有提交都落在这条线上，`main` 一动不动。

### ③ 写代码，随手看状态

```bash
git status          # 哪些文件改了 / 新增了
git diff            # 具体改了什么
```

### ④ 提交（分成几个小 commit，别攒成一个巨型 commit）

```bash
git add app-client/lib/features/contents
git commit -m "feat(contents): 列表页接入分页接口"
```

commit message 格式跟仓库现有习惯一致：`类型(范围): 中文描述`。

**提交前必看一次 `git status`。** 这个项目有个真实陷阱：
`app-client/build/app/outputs/flutter-apk/app-debug.apk` 有 144MB，
GitHub 单文件上限 100MB，一旦提交进去，push 会直接被拒，还得改写历史才能清掉。
只要 `.gitignore` 正常（`/build/` 已忽略），它不会出现在 `git status` 里；但它一旦出现，就说明有问题，停下来查。

### ⑤ 推上去

```bash
git push -u origin feat/contents-list
```

第一次推这条分支要带 `-u`，把本地分支和远程分支绑定；之后直接 `git push` 就行。

首次 push 会要求 GitHub 授权：浏览器弹窗登录，或者用 Personal Access Token 当密码。
**这一步需要你对该仓库有写权限**（被加为 collaborator）。如果弹的是 403，说明没权限，见 §7。

### ⑥ 开 PR

推完后终端会给一个链接，或者直接去 GitHub 仓库页面，会看到黄色提示条 "Compare & pull request"。

PR 里写清楚三件事：
1. 这个 PR 做了什么
2. 怎么验证（跑了什么命令、点了哪些页面）
3. 有没有改契约、有没有遗留问题

先让另两位看一眼再合并。**自己不要点 merge**，除非约定好可以。

### ⑦ 合并后删分支

```bash
git switch main
git pull                                        # 把刚合并的代码拉下来
git branch -d feat/contents-list                # 删本地
git push origin --delete feat/contents-list     # 删远程
```

GitHub 上合并 PR 时有个 "Delete branch" 按钮，点它也能删远程。本地那条要自己删。

---

## 5. main 更新了怎么办

场景：你在 `feat/contents-list` 上写了三天，这三天里 Java 那边往 `main` 合了新代码。

### 正确做法：把最新 main 合进你的分支

```bash
git switch main
git pull                          # 拿到最新 main
git switch feat/contents-list
git merge main                    # 把 main 合进你的分支
```

冲突就在这一步解决。解决完 `git add` + `git commit`，然后正常 `git push`。

### 为什么不用 `git rebase`

`rebase` 会让你的提交历史变漂亮，但它会**改写提交哈希**，导致远程分支和本地对不上，
下次 push 必须 `git push --force`。新手在共享分支上 `--force`，很容易把别人的提交冲掉。

**结论：合并用 `merge`，不用 `rebase`，不用 `--force`。**

### 多久同步一次

- 开工前：必做
- 开 PR 前：必做（否则 review 时看到的 diff 会包含一堆"你落后的旧代码"）
- 开发中间：一周一次就够，不必每天

---

## 6. 冲突怎么处理

冲突不是错误，是两个人改了同一行代码，git 让你决定留哪个。

```bash
git merge main
# 输出：CONFLICT (content): Merge conflict in app-client/lib/...
```

### ① 看哪些文件冲突

```bash
git status
# 冲突文件会列在 "Unmerged paths" 下，标 both modified
```

### ② 打开冲突文件

会看到这样的标记：

```
<<<<<<< HEAD
你分支上的代码
=======
main 上的代码
>>>>>>> main
```

### ③ 改成你最终想要的样子

**把 `<<<<<<<`、`=======`、`>>>>>>>` 这三行连同不要的那份代码一起删掉**，
留下正确的结果（也可能是两边都要，那就手工拼起来）。

### ④ 标记解决完，继续

```bash
git add 冲突的文件
git merge --continue
```

想放弃这次合并、回到合并前：`git merge --abort`。

### ⑤ 拿不准就问

涉及契约字段、错误码、接口路径的冲突，**不要自己拍板**，去群里问 Java 或 Python 负责人。
界面层的冲突你自己定就行。

---

## 7. 常见报错对照

| 报错 | 原因 | 怎么办 |
| --- | --- | --- |
| `not a git repository` | 没在仓库目录里，或还没 init | `cd /d/otaku`；若没有 `.git`，回 §1 |
| `untracked working tree files would be overwritten` | 本地文件和要检出的分支文件同名 | 先删/改名本地那个文件 |
| `CONNECT tunnel failed, response 502` | 本机代理不支持 HTTP/2 的 CONNECT | `git config http.version HTTP/1.1` |
| `Permission denied (403)` | 没有仓库写权限 | 找仓库所有者加 collaborator；或 fork 后从自己仓库发 PR |
| `Updates were rejected (non-fast-forward)` | 远程有你本地没有的提交 | `git pull` 后再 push；**不要用 `--force`** |
| `Your branch is behind 'origin/main'` | 你落后了 | 正常提示，`git pull` 即可 |
| `detached HEAD` | 检出了某个 commit 而不是分支 | `git switch main` 回来 |
| `Please tell me who you are` | 没配 user.name/email | 回 §1.1 |

---

## 8. VS Code 里怎么做（不想敲命令的话）

VS Code 左下角状态栏会显示当前分支名（装了 GitLens 更清楚）：

- **点分支名** → 弹出分支列表，可以直接切换
- **列表顶部 "Create new branch..."** → 输入 `feat/contents-list`，等于 `git switch -c`
- **源代码管理面板**（左侧第三个图标）→ 改动的文件都在这里，填 commit message 点 ✓
- **同步按钮**（状态栏的 `↑↓` 数字）→ 等于 `git pull` + `git push`

命令行的好处是每一步发生了什么你看得见。前两周建议命令行，熟了再交给图形界面。

---

## 9. 第一次 PR 该带什么

别一上来就推整个业务代码。第一个 PR 只做脚手架，让另外两人先看清你的目录结构和分层：

**`feat/flutter-scaffold` 的 PR 内容：**

- `app-client/` 完整 Flutter 工程（android + windows 两个平台）
- `pubspec.yaml` + `pubspec.lock`（**lock 必须提交**，保证三人依赖版本一致）
- `lib/` 分层骨架：`core/` `data/` `features/` `shared/`
- 主题、路由、dio 封装、统一错误模型（对着 `docs/stage1-minimal-contract.md` 的错误信封写）
- Mock 仓储 + `--dart-define=USE_MOCK=true` 开关
- 更新 `app-client/README.md`：怎么跑、怎么切 Mock、目录约定

**明确不要提交：**

- `build/`、`.dart_tool/`、`.idea/`、`*.iml`、`windows/flutter/ephemeral/`
- 任何 `.apk`、`.exe`
- `D:\otaku\.workbuddy/`（本地工具目录）

---

## 10. 一页速查

```bash
# 开工
git switch main && git pull
git switch -c feat/xxx

# 干活
git status
git add <具体路径>
git commit -m "feat(范围): 描述"

# 上交
git push -u origin feat/xxx

# main 动了
git switch main && git pull
git switch feat/xxx && git merge main

# 合并后清理
git switch main && git pull
git branch -d feat/xxx
git push origin --delete feat/xxx
```
