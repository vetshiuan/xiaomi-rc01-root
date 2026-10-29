# OPA 能力边界实测（1.1.56）

`opa-docker-authz` 是小米在 Docker daemon 层加的授权插件。它不是「全禁」，
而是一条条判的 —— 下表是逐项实测结果，省得一个个试。

## 容器参数

通过 SimpleDocker 面板创建容器：

| 配置 | 结果 |
|---|---|
| 无任何挂载（bridge） | ✅ 成功 |
| bind mount 宿主目录 | ❌ OPA 拒绝 |
| 命名卷 `vol:/data` | ❌ 拒绝（面板只接受绝对路径） |
| `--network host` | ✅ 放行 |
| `--device /dev/net/tun` | ✅ 放行 |
| `--privileged` | ❌ 拒绝 |
| `--cap-add NET_ADMIN` | ❌ 拒绝 |
| `--pid=host` + SYS_ADMIN | ❌ 拒绝 |

**结论**：面板只允许创建「无状态、无特权」的容器。
装 IT-Tools、Excalidraw、PairDrop 这类可以，任何需要持久化或特权的都不行。

## 挂 docker.sock 也不行

```sh
docker run -v /var/run/docker.sock:/var/run/docker.sock portainer/portainer
```

```
authorization denied by plugin opa-docker-authz: request rejected by administrative policy
```

OPA 是 Docker daemon 层的插件，任何客户端（Portainer / CLI / 直接 curl API）
都走同一道门，换客户端没有意义。

## `docker cp` 读宿主配置 —— 读到的是 Alpine

```sh
docker cp /etc/config/mi_docker <container>:/tmp/
# → no such file or directory
```

`docker cp /etc` 拷出来的目录里是 `alpine-release`、`apk`、`os-release`，
**不是 OpenWrt 的 `/etc`**。

原因：小米的 Docker daemon 跑在一个 Alpine 隔离环境里（不是宿主命名空间），
所以 `docker cp` 的「本地路径」是那个 Alpine 根，不是真实宿主根。

**这条线走不通。**

## 解除 OPA

拿到 root 之后，改配置文件即可：

```sh
cp /etc/config/mi_docker /data/mi_docker.bak
sed -i "s/authorization_plugins .*/authorization_plugins ''/g" /etc/config/mi_docker
/etc/init.d/mi_docker restart
```

验证：

```sh
/mnt/usb/mi_docker/docker-binaries/docker run --rm --privileged --network host \
  nginx:alpine-slim echo OPA_REMOVED
```

**注意**：`/etc` 是 ramfs，重启会还原。必须 `uci set` + `uci commit` 才会写进
`/data/etc/config/mi_docker`（持久）。

```sh
uci set mi_docker.globals.authorization_plugins=''
uci commit mi_docker
grep authorization /data/etc/config/mi_docker     # 应为 authorization_plugins ''
```

## 解除之后的风险

`opa-docker-authz` 是这台机器上唯一的容器授权层。清掉之后：

- 任何容器都能 `--privileged`、能挂宿主根目录、能改宿主网络
- 跑一个来路不明的镜像 = 把整台路由器交出去
- 小米后台的容器管理面板不再有任何兜底

## 这份边界表的用法

想做「装个容器跑点东西」：先照上表挑参数，能过 OPA 的只有无状态方案。
真的需要特权：先解 OPA，再确认你只跑自己构建或高度可信的镜像。
