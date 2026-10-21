# 生产镜像：多阶段构建，最终镜像只带 JRE 与 jar。
#
# 注意：`compose.yaml` 只用来在本地起 MySQL，后端平时是 `./mvnw spring-boot:run` 跑的。
# 这个文件是给服务器用的，本地开发不需要它。
#
#   docker build -t otaku-backend:latest .
#   docker run --rm -p 8080:8080 --env-file .env otaku-backend:latest
#
# 也可以直接 `docker compose -f compose.prod.yaml up -d --build`。

# ---------- 构建阶段 ----------
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /build

# 先只拷 pom：依赖层能被缓存住，之后改代码不会重新下载整个依赖树。
COPY pom.xml .
RUN mvn -B -q dependency:go-offline

COPY src ./src
# 跳过测试：CI 已经在 PR 上跑过了，镜像构建不该重复跑一遍；
# 真要在这里跑，加 -DskipTests=false。
RUN mvn -B -q clean package -DskipTests

# ---------- 运行阶段 ----------
FROM eclipse-temurin:17-jre-jammy
WORKDIR /app

# curl 只为 HEALTHCHECK 用。基础镜像不带，装完顺手清掉 apt 缓存。
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

# 非 root 运行。封面缓存目录必须存在且可写，否则回源缓存会失败。
RUN groupadd -r otaku \
 && useradd -r -g otaku otaku \
 && mkdir -p /app/data/covers \
 && chown -R otaku:otaku /app

COPY --from=build --chown=otaku:otaku /build/target/*.jar /app/app.jar

USER otaku
EXPOSE 8080

# start-period 给足：首次启动要跑 Flyway 迁移，小机器上会慢一些。
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/actuator/health || exit 1

# MaxRAMPercentage 而不是固定 -Xmx：轻量服务器内存小（常见 2G），
# 让 JVM 按容器实际限制算，比写死 512m 更不容易 OOM。
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
