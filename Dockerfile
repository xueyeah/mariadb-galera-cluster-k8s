FROM mariadb:10.3

#跟换国内源 下载
RUN cp /etc/apt/sources.list /etc/apt/sources_init.list
ADD ["sources.list", "/etc/apt/sources.list"]

RUN set -x && \
    apt-get update && apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*


ADD ["galera/", "/opt/galera/"]

ADD ["galera-peer-finder/galera-peer-finder", "/usr/local/bin/"]
ADD ["peer-finder", "/usr/local/bin/"]

RUN chmod +x /usr/local/bin/peer-finder /usr/local/bin/galera-peer-finder

RUN set -x && \
    cd /opt/galera && chmod +x *.sh


ADD ["docker-entrypoint.sh", "/usr/local/bin/"]
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["mysqld"]
