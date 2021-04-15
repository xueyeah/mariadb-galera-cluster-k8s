#!/bin/bash
set -eo pipefail 
shopt -s nullglob #对于nullglob来说, 就是在使用shell 的通配符*匹配文件时，如果没有匹配到任何文件时，那就会输出null string，而不是通配符字符本身。

#set -x   #测试先打开 
if [ "$TRACE" = "1" ]; then
	set -x   #运行结果之前，先输出执行的指令
fi

################################################################
# 若启动命令时附加了参数，则在参数前添加mysqld，如$0 -f test，则经过此代码处理后，
# $@参数变mysqld -f test。其中${1:0:1}从$1参数第0个位置取1字符，如$1为-f，则
# 取'-'字符，若条件为真，通过set命令重置$@参数，添加mysqld前缀，即经过处理后$1变
# 为mysqld。
################################################################
# if command starts with an option, prepend mysqld 如果命令以一个选项开始，则在mysqld前加上前缀
if [ "${1:0:1}" = '-' ]; then
    # "set --" 后无内容，将当前 shell 脚本的参数置空，$1 $? $@ 等都为空。
    # "set --" 后有内容，当前 shell 脚本的参数被替换为 "set --" 后的内容，$1 $? $@ 等相应地被改变。
	set -- mysqld "$@"
fi

# 解析参数，是否是获取帮助信息参数，并设置wantHelp值
# skip setup if they want an option that stops mysqld
wantHelp=
for arg; do
	case "$arg" in
		-'?'|--help|--print-defaults|-V|--version)
			wantHelp=1
			break
			;;
	esac
done

#############################
# 从文件中读取变量值
#############################
# usage: file_env VAR [DEFAULT]
#	ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

###########################################################################
# 运行mysqld --help --verbose --help 2>&1 >/dev/null命令，
# 此命令会检查配置文件，若配置文件没问题，则成功，不成功则输出错误信息，及if中添
# 加！取不成功。
###########################################################################
_check_config() {
	toRun=( "$@" --verbose --help --log-bin-index="$(mktemp -u)" )
	if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
		cat >&2 <<-EOM
			ERROR: mysqld failed while attempting to check config
			command was: "${toRun[*]}"
			$errors
		EOM
		exit 1
	fi
}

_datadir() {
	"$@" --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null | awk '$1 == "datadir" { print $2; exit }'
}


_select_start_node() {

	####################### 本节点 host name     ###############
	local_hostname=$(hostname)
	###################  本节点  wsrep  position   ############### 
	echo "-- $1  $2 -- "  
	local_wsrep_position=0
	if  [ $1 ] ; then
		local_wsrep_position=${1#*:} 
	fi

	#获取域名
	local_full_name=`grep -F "wsrep_node_address=" /etc/mysql/conf.d/galera.cnf`
	domain=${local_full_name#*.}  ### galera.default.svc.cluster.local
	echo "domain is : $domain"

	# Parse out cluster name, formatted as: petset_name-index
	IFS='-' read -ra ADDR <<< "$(hostname)"
	sts_name="${ADDR[0]}"

	all_node_names=("${sts_name}-0.$domain" "${sts_name}-1.$domain" "${sts_name}-2.$domain") 

	count=0;
	for i in ${!all_node_names[@]}
	do
		if [[ "${all_node_names[$i]}" == *"${local_hostname}"* ]]; then # 把自己排除出来， 不用获取自己的数据
				echo  "exclude myself ${all_node_names[$i]}"
				continue
		fi
		other_nodes[count++]=${all_node_names[$i]}
	done
	echo "${other_nodes[*]}"

	###  其它数据库都没有启动 开始选举， 如果有一个启动了 ， 常规启动不需要选举了
	for _f_node_name in ${other_nodes[@]} 
	do
		if echo 'SELECT 1' | mysql -uroot "-p$2" -h${_f_node_name}  &> /dev/null; then
			mkdir -p "$DATADIR/mysql"
			echo "$_f_node_name has been started ..."
			return  
		fi
	done

	echo "local_wsrep_position :  $local_wsrep_position $local_hostname"

	wsrep_result="$local_hostname" # 初始化本节点

	#echo "begin loop all nodes and find the first node  that allow start"
	for _s_node_name in ${other_nodes[@]} 
	do
		echo  "deal with $_s_node_name"
		while [ "1" = "1" ]
		do
			# curl -s -w "%{http_code}" -o /tmp/tmpFile  http://mysql-0.galera.default.svc.cluster.local:8899/wsrep
			# curl -s -w "%{http_code}" -o /tmp/tmpFile  http://mysql-1.galera.default.svc.cluster.local:8899/wsrep
			# curl -s -w "%{http_code}" -o /tmp/tmpFile  http://mysql-2.galera.default.svc.cluster.local:8899/wsrep
			#echo "curl -s -w "%{http_code}" -o /tmp/tmpFile  http://$_node_name:8899/wsrep"
			set +e 
			http_code=`curl -s -w "%{http_code}" -o /tmp/$_s_node_name  http://$_s_node_name:8899/wsrep`
			set -e
			if [ "$http_code" != "200" ]; then # 没有正常返回， 接着取
				#echo "curl failed : $http_code"
				continue;
			fi

			#取到结果
			tmp_wsrep=`cat /tmp/$_s_node_name`
			echo "$http_code    ---   $tmp_wsrep"

			wsrep_array=(${tmp_wsrep//:/ })
			wsrep_position=${wsrep_array[1]}
			wsrep_node=${wsrep_array[2]}
			echo "wsrep_position, wsrep_node: $wsrep_position  $wsrep_node"

			## 本节点 number 大
			if [ $local_wsrep_position -gt $wsrep_position ]; then
				break;
			fi

			###  number 相同 ， 取 hostname 小的节点 FINAL=`echo ${STR: -1}`
			if [ $local_wsrep_position -eq $wsrep_position ] && [ ${wsrep_node: -1} -gt ${wsrep_result: -1} ]; then
				break;
			fi

			wsrep_result=$wsrep_node
			break
		done
	done
	#echo " end loop all nodes and find the first node  that allow start"

	echo "the first node should be  $wsrep_result "

	#如果选举的节点 最后是本节点则 则执行, 否则等到有一个节点起来了，再启动
	if [ $wsrep_result != "$local_hostname" ] ; then
	   
		while [ "1" = "1" ]
		do
			### 有其它数据库启动了 , 我就开始启动
			for _th_node_name in ${other_nodes[@]} 
			do
				if echo 'SELECT 1' | mysql -uroot "-p$2" -h${_th_node_name}  &> /dev/null; then
					# Run Galera at non-first node on Kubernetes
					if hash peer-finder 2>/dev/null; then
						peer-finder -on-start=/opt/galera/on-start.sh -service="${GALERA_SERVICE:-galera}"
					fi

					echo "$_th_node_name has been started , so begin start node : $local_hostname"
					return  
				fi
			done
		done
	else
		# Run Galera at first node on Kubernetes
		# if hash peer-finder 2>/dev/null; then
		#     peer-finder -on-start=/opt/galera/on-start-first.sh -service="${GALERA_SERVICE:-galera}"
		# fi

		# hard code , first node should be wsrep_cluster_address=gcomm://
		sed -i -e "s|^wsrep_cluster_address[[:space:]]*=.*$|wsrep_cluster_address=gcomm://|" /etc/mysql/conf.d/galera.cnf
	fi

	return
}


# 1. $1参数为mysqld 以及 wanthelp 参数为空 以及root用户，执行此代码；
# 2. _check_config检查配置文件是否正确
# 3. 获取DATADIR目录，执行mysqld --verbose --help --log-bin-index=/tmp/tmp.4SyApJWeIo| \
#         awk '$1 == "'"datadir"'" { print $2; exit }'
# 4. 创建并修改目录权限
# 5. 执行exec gosu mysql docker-entrypoint.sh "$@"，即重新以mysql用户再次调用脚
#    本
# allow the container to be started with `--user`
echo "var wantHelp is $wantHelp"
if [ "$1" = 'mysqld' -a -z "$wantHelp" -a "$(id -u)" = '0' ]; then
	_check_config "$@"
	export DATADIR="$(_datadir "$@")"
	mkdir -p "$DATADIR"

	# Run Galera auto-discovery on Kubernetes
	if hash peer-finder 2>/dev/null; then
		peer-finder -on-start=/opt/galera/on-start.sh -service="${GALERA_SERVICE:-galera}"
	fi

	chown -R mysql:mysql "$DATADIR"
	echo "gosu mysql $BASH_SOURCE $@"
	exec gosu mysql "$BASH_SOURCE" "$@"
fi

# $1参数为mysqld 以及 wanthelp 参数为空，执行此代码，及exec gosu会执行此代码；
if [ "$1" = 'mysqld' -a -z "$wantHelp" ]; then
	# still need to check config, container may have started with --user
	echo "_check_config $@"
	_check_config "$@"

	# Get config
	DATADIR="$(_datadir "$@")"
	echo "DATADIR is : $DATADIR"

	# 若mysql数据库未创建，则执行本段逻辑 
	if [ ! -d "$DATADIR/mysql" ]; then
		#file_env 'MYSQL_ROOT_PASSWORD'
		if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			echo >&2 'error: database is uninitialized and password option is not specified '
			echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
			exit 1
		fi

		# 创建目录
		#mkdir -p "$DATADIR"

		# 执行mysqld命令初始化数据库
		echo 'Initializing database'
		mysql_install_db --datadir="$DATADIR" --rpm
		echo 'Database initialized'

		# 获取socket值并启动mysql
		"$@" --skip-networking --socket=/var/run/mysqld/mysqld.sock &
		pid="$!"

		# 设置mysql变量（列表形式），而后可以${mysql[@]}调用
		mysql=( mysql --protocol=socket -uroot -hlocalhost --socket=/var/run/mysqld/mysqld.sock )

		#运行30次，验证mysql是否已经启动完毕
		for i in {30..0}; do
			if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
				break
			fi
			echo 'MySQL init process in progress...'
			sleep 1
		done

		#若i为0值，则表明mysql启动失败
		if [ "$i" = 0 ]; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		# 解决时区bug
		# echo "MYSQL_INITDB_SKIP_TZINFO is $MYSQL_INITDB_SKIP_TZINFO"
		# if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
		# 	# sed is for https://bugs.mysql.com/bug.php?id=20545
		# 	mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
		# fi

		# 生成root随机密码  不会用
		if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			export MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
			echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
		fi
		
		# root 用户名密码
		echo " ---- ${mysql[@]}  -----"
		"${mysql[@]}" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;

			DELETE FROM mysql.user ;
			CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
			DROP DATABASE IF EXISTS test ;
			-- add for haproxy 
			create user 'haproxy' ;
			FLUSH PRIVILEGES ;
		EOSQL

		# 已设置root密码，故mysql需加上root密码
		echo "MYSQL_ROOT_PASSWORD is $MYSQL_ROOT_PASSWORD"
		if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
			echo " ---- ${mysql[@]}  -----"
			mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
		fi

		# 若配置了MYSQL_DATABASE变量，则创建
		file_env 'MYSQL_DATABASE'
		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
			mysql+=( "$MYSQL_DATABASE" )
		fi

		# 在数据库内创建用户
		file_env 'MYSQL_USER'
		file_env 'MYSQL_PASSWORD'
		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"

			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
			fi

			echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
		fi

		# 执行/docker-entrypoint-initdb.d目录下面的脚本，包含shell、sql
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)	 echo "$0: running $f"; . "$f" ;;
				*.sql)	echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
				*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
				*)		echo "$0: ignoring $f" ;;
			esac
			echo
		done

		# kill -s TERM "$pid" 杀掉mysql进程，执行成功则返回0，而！kill取反，即kill成
		# 功后才执行后面的!wait命令
		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		# 初始化成功后，再次启动
		echo
		echo 'MySQL init process done. Ready for start up.'
		echo
	fi
fi

# Run Galera auto-recovery
if [ -f /var/lib/mysql/ibdata1 ]; then
	echo "Galera - Determining recovery position..."
	set +e  ###
	start_pos_opt=$(/opt/galera/galera-recovery.sh "${@:2}")
	set -e
	if [ $? -eq 0 ]; then
		echo "Galera recovery position: $start_pos_opt"
		set -- "$@" $start_pos_opt	
	else
		echo "FATAL - Galera recovery failed!"
		exit 1
	fi
fi

echo " --  SINGLE_INSTANCE_MODE: $SINGLE_INSTANCE_MODE  --"
if [ "$SINGLE_INSTANCE_MODE" != "1" ] ; then  # 单节点运行
	#启动rest 服务， 供查询使用
	nohup galera-peer-finder -position=$start_pos_opt &
	echo " ----------------begin select start node ----------------------"
	file_env 'MYSQL_ROOT_PASSWORD'
	_select_start_node "$start_pos_opt" "$MYSQL_ROOT_PASSWORD"
fi

#######  wsrep_sst_method=mariabackup wsrep_sst_auth=  ########
sed -i -e "s|^wsrep_sst_auth[[:space:]]*=.*$|wsrep_sst_auth=root:${MYSQL_ROOT_PASSWORD}|" "/etc/mysql/conf.d/galera.cnf"


# echo " ----------------begin myinit.sh ----------------------"
# result=_select_start_node $start_pos_opt $MYSQL_ROOT_PASSWORD
# echo "选举结果： $result"

# 正式启动数据库
echo "finally exec: $@"
exec "$@"

# can_start=/myinit.sh $start_pos_opt $MYSQL_ROOT_PASSWORD)
# if [ $? -eq 0 ]; then
# 	echo "entrypoints.sh xxxxxxxx : $can_start "
# 	# 正式启动数据库
# 	echo "finally exec: $@"
# 	exec "$@"
# else
# 	echo " ----------------failed myinit.sh ----------------------"
# 	exit 1
# fi



