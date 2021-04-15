# mariadb-galera-cluster-k8s安装手册

### k8s环境

安装mariadb-galera-cluster 需要有一套k8s环境，如下为实验室环境详情：

```bash
[root@maap-mongo-dev-01 mariadb-galera-clusters]# cat /etc/redhat-release
CentOS Linux release 7.7.1908 (Core)


[root@maap-mongo-dev-01 mariadb-galera-clusters]# kubeadm version
kubeadm version: &version.Info{Major:"1", Minor:"16", GitVersion:"v1.16.4", GitCommit:"224be7bdce5a9dd0c2fd0d46b83865648e2fe0ba", GitTreeState:"clean", BuildDate:"2019-12-11T12:44:45Z", GoVersion:"go1.12.12", Compiler:"gc", Platform:"linux/amd64"}


[root@maap-mongo-dev-01 mariadb-galera-clusters]# docker version
Client: Docker Engine - Community
 Version:           19.03.13
 API version:       1.40
 Go version:        go1.13.15
 Git commit:        4484c46d9d
 Built:             Wed Sep 16 17:03:45 2020
 OS/Arch:           linux/amd64
 Experimental:      false

Server: Docker Engine - Community
 Engine:
  Version:          19.03.13
  API version:      1.40 (minimum version 1.12)
  Go version:       go1.13.15
  Git commit:       4484c46d9d
  Built:            Wed Sep 16 17:02:21 2020
  OS/Arch:          linux/amd64
  Experimental:     false
 containerd:
  Version:          1.3.7
  GitCommit:        8fba4e9a7d01810a393d5d25a3621dc101981175
 runc:
  Version:          1.0.0-rc10
  GitCommit:        dc9208a3303feef5b3839f4323d9beb36df0a9dd
 docker-init:
  Version:          0.18.0
  GitCommit:        fec3683
```



### 一、安装文件列表说明

mariadb-galera-cluster-k8s.zip 解压后目录如下：

```bash
.
├── busybox1.30.1.tar                      #bash命令镜像压缩包，
├── docker-entrypoint.sh                   #构建mariadb镜像源文件
├── Dockerfile							   #构建mariadb镜像源文件
├── galera                                 #构建mariadb镜像源文件夹
│   ├── galera.cnf 						   
│   ├── galera-recovery.sh
│   └── on-start.sh
├── galera-peer-finder
│   ├── build.sh                           #go环境下编译galera-peer-finder.go文件生成 galera-peer-finder文件
│   ├── galera-peer-finder
│   └── galera-peer-finder.go
├── mariadb-galera-cluster10.3.16.tar     #mariadb 10.3版本基础镜像压缩包
├── peer-finder 
├── README.md
├── sources.list                          #替换镜像下载源文件
├── template                              #k8s部署mariadb 集群模板文件夹
│   ├── galera.yaml                       
│   ├── mysql.pv.yml
│   ├── namespaces.yaml
│   ├── pvc.yaml
│   └── secrets-development.yaml
└── test                                  #测试脚本
    ├── 0_as_fisrt.sh
    ├── 1_as_fisrt.sh
    ├── 2_as_fisrt.sh
    ├── 2_sql.log
    └── sql.sh

```



### 二、构建并导入镜像

构建镜像两种方式：

方式一（推荐）：通过已经构建好的镜像压缩包通过如下docker命令导入docker本地仓库。

进入mariadb-galera-cluster-k8s解压目录执行：

```bash
docker load -i mariadb-galera-cluster10.3.16.tar
docker load -i busybox1.30.1.tar
```

方式二：通过docker命令手动创建镜像

进入mariadb-galera-cluster-k8s目录，在有Dockerfile文件的当前目录下，执行如下命令

```bash
docker build -t mariadb-galera-cluster:10.3.16 .
```

busybox需要连接公网执行如下命令拉取镜像

```
docker pull busybox:1.30.1
```



导入镜像成功后，执行如下命令，可显示已导入的镜像：

```bash
[root@maap-mongo-dev-02 ~]# docker images
REPOSITORY                                               TAG                 IMAGE ID            CREATED             SIZE
mariadb-galera-cluster                                   10.3.16             35868e3f0354        24 hours ago        412MB
busybox                                                  1.30.1              64f5d945efcc        22 months ago       1.2MB

```



### 三、k8s安装mariadb集群

##### 1.创建命名空间

```
[root@maap-mongo-dev-01 mariadb-galera-clusters]# kubectl apply -f template/namespaces.yaml
```

##### 2.创建密钥属性配置

部署mariadb容器的时候，可读取里面为mariadb配置的base64加密的密码

```
[root@maap-mongo-dev-01 mariadb-galera-clusters]# kubectl apply -f template/secrets-development.yaml

```

##### 3.部署单节点mariadb

首先确定 template/galera.yaml  文件中如下属性是否配置正确。单节点配置（replicas: 1     value: "1" ）

```bash
101   selector:
102     matchLabels:
103       app: mysql
104   serviceName: "galera"
105   replicas: 3      ##########单节点部署的时候，这里要配置成1
106   podManagementPolicy:  "Parallel"
107   template:
108     metadata:
109       labels:
110         app: mysql

```

```bash
 136         env:
 137         # 1:数据库不跑集群， 以单节点运行 ， 请一定吧副本数设置 为 1
 138         # 否则：3 节点 galera集群方式
 139         - name: SINGLE_INSTANCE_MODE
 140           value: "0"     ############单节点部署的时候，这里配置成1
 141         - name: TZ
 142           value: Asia/Shanghai
 143         - name: POD_NAMESPACE
 144           valueFrom:

```

执行部署命令：

```bash
[root@maap-mongo-dev-01 mariadb-galera-clusters]# kubectl apply -f template/galera.yaml

```

先部署单节点初始化容器，部署成功后，可显示如下信息：

```
[root@maap-mongo-dev-01 mariadb-galera-clusters]# kubectl get pod -n incloud -o wide
NAME      READY   STATUS    RESTARTS   AGE     IP             NODE                NOMINATED NODE   READINESS GATES
mysql-0   1/1     Running   0          3h24m   10.244.4.94    maap-mongo-dev-02   <none>           <none>

```

READY为 1/1  ,STATUS为Running即部署成功。NODE 为maap-mongo-dev-02表示k8s把容器分配到该机器运行，容器对外暴露的端口为31586 ，可通过mysql 客户端连接是否可以成功

31586 可以在 template/galera.yaml 中配置

```bash
     30 spec:
     31   type: NodePort
     32   ports:
     33   - port: 3306
     34     targetPort: 3306
     35     nodePort: 31586 #对外暴露端口
     36     name: mysql
     37   selector:
     38     app: mysql

```



mysql 中root默认密码配置在 template/secrets-development.yaml

```bash
      1 apiVersion: v1
      2 kind: Secret
      3 metadata:
      4   name: mysql
      5   namespace: incloud
      6 type: Opaque
      7 data:
      8   # Root password (base64): 123456a?
      9  # password: MTIzNDU2YT8=
     10    password: MTIzNDU2YT8=

```



mysql测试

```bash
[nxuser@cm-mmsc-xieliangjun-2 ~]$ mysql -h 192.168.208.123 -uroot -p123456a? --port 31586 -e 'show databases;'
+--------------------+
| Database           |
+--------------------+
| information_schema |
| maap               |
| mysql              |
| performance_schema |
+--------------------+
[nxuser@cm-mmsc-xieliangjun-2 ~]$

```

##### 4.部署3节点集群

部署完单节点后，把template/galera.yaml  文件中属性配置修改为（replicas: 3     value: "0" ）

执行如下部署命令

```
[root@maap-mongo-dev-01 mariadb-galera-clusters]# kubectl apply -f template/galera.yaml

```

查看集群部署情况

```
[root@maap-mongo-dev-01 mariadb-galera-clusters]# kubectl get pod -n incloud -o wide
NAME      READY   STATUS    RESTARTS   AGE     IP             NODE                NOMINATED NODE   READINESS GATES
mysql-0   1/1     Running   0          3h42m   10.244.4.94    maap-mongo-dev-02   <none>           <none>
mysql-1   1/1     Running   1          3h42m   10.244.3.115   maap-mongo-dev-03   <none>           <none>
mysql-2   1/1     Running   0          119m    10.244.5.52    maap-mongo-dev-06   <none>           <none>

```

分别到部署容器上的NODE上看下是否有31586 监听端口，对于有连接的监听端口，用客户端去连接即可。

实验室环境在maap-mongo-dev-03与maap-mongo-dev-06有监听端口（有两台机器上监听端口，任意连接一个效果一样，两个是支持高可用）

```bash
[root@maap-mongo-dev-06 ~]# netstat -anp|grep 31586
tcp6       0      0 :::31586                :::*                    LISTEN      29629/kube-proxy
[root@maap-mongo-dev-06 ~]#

[root@maap-mongo-dev-03 ~]# netstat -anp|grep 31586
tcp6       0      0 :::31586                :::*                    LISTEN      997807/kube-proxy
[root@maap-mongo-dev-03 ~]#

[root@maap-mongo-dev-02 ~]# netstat -anp|grep 31586
[root@maap-mongo-dev-02 ~]#

```

参考地址：

https://gitee.com/guu13/mariadb-galera-cluster.git

