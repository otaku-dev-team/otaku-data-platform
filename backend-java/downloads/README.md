# downloads

nginx 静态托管的客户端安装包与更新清单。客户端启动时拉 `/downloads/latest.json`，
按 `versionCode` 判断新旧；安装包走 `/downloads/*.apk`。完整发布流程见
[`docs/app-update.md`](../../docs/app-update.md)。

- `latest.json`：**不入库**（各部署环境不同），从 `latest.json.example` 复制后填写
- `*.apk`：**不入库**，发布时拷进来

最小操作：

```bash
# 1. 构建（发版必须递增 --version-code）
./build_site.sh --site otaku --target apk --build-mode debug \
  --version-name 1.1.0 --version-code 2 \
  --update-base-url https://<域名>/downloads

# 2. 计算哈希
sha256sum build/app/outputs/flutter-apk/app-debug.apk

# 3. 放到本目录，并写 latest.json
cp app-debug.apk otaku-1.1.0.apk
cp latest.json.example latest.json   # 填 versionCode / downloadUrl / sha256

# 4. 让 nginx 读到（挂载是只读目录，改文件不用重启；首次新增目录才需要 up）
docker compose -f compose.prod.yaml up -d nginx
```
