#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get upgrade -y
apt-get install -y linux-aws
apt-get install -y awscli jq
apt install python -y
apt install python-apt -y

EC2_INSTANCE_ID=$(wget -q -O - http://169.254.169.254/latest/meta-data/instance-id || die \"wget instance-id has failed: $?\")
EC2_AVAIL_ZONE=$(wget -q -O - http://169.254.169.254/latest/meta-data/placement/availability-zone || die \"wget availability-zone has failed: $?\")
EC2_REGION="`echo \"$EC2_AVAIL_ZONE\" | sed -e 's:\([0-9][0-9]*\)[a-z]*\$:\\1:'`"

# Install docker
apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"
apt-get install -y docker-ce
usermod -aG docker ubuntu

# Install docker-compose
curl -L https://github.com/docker/compose/releases/download/1.21.0/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

mkdir /data
chown -R ubuntu:ubuntu /data/
mkfs.ext4 /dev/xvdf
mount /dev/xvdf /data

mkdir -p /home/ubuntu/data
ln -s /data /home/ubuntu/data

# Create the file ansible hardening depends on. Playbook fails if this file does not exist.
# TODO: Investigate why the existence of file, even empty, is needed. Or configure it accordingly.
touch /etc/security/limits.d/10.hardcore.conf

cat<<EOF >>/home/ubuntu/docker-compose.yaml
version: '3'
services:
  nginx:
    depends_on:
      - citizen
    image: 'nginx:1.17.3'
    container_name: 'nginx'
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf
      - ./nginx/access_lists/:/etc/nginx/access_lists/
      - ./nginx/log/:/var/log/nginx/
    ports:
      - 9000:9000
      - 7100:7100
    external_links:
      - citizen
    restart: always
  citizen:
    image: 'iconloop/citizen-node:1908271151xd2b7a4'
    container_name: 'citizen'
    environment:
      LOG_OUTPUT_TYPE: "file"
      LOOPCHAIN_LOG_LEVEL: "DEBUG"
      FASTEST_START: "yes"     # Restore from lastest snapshot DB

    volumes:
      - ./data:/data  # mount a data volumes
      - ./keys:/citizen_pack/keys  # Automatically generate cert key files here
    expose:
      - '9000'
      - '7100'
    restart: always

EOF

mkdir -p /home/ubuntu/nginx/access_lists

cat<<EOF >>/home/ubuntu/nginx/access_lists/update_grpc_whitelist.sh
#!/bin/sh

USER="ubuntu"
PREP_NODE_LIST_API="localhost:9000/api/v3"
GRPC_WHITELIST="/home/$USER/nginx/access_lists/grpc_whitelist.conf"
GRPC_WHITELIST_UPDATED="/home/$USER/nginx/access_lists/grpc_whitelist_updated.conf"
DOCKER_ID=`docker ps | grep nginx | awk '{ print $1 }'`
UPDATE_LOG="/home/$USER/nginx/access_lists/grpc_whitelist_update.log"
DATE_TIME=`date`

# Check if nginx is running, otherwise we can't access the prep json rpc api
if [ -z "$DOCKER_ID" ]; then
	echo "$DATE_TIME: ERROR: NGINX docker was not running!" >> $UPDATE_LOG
	exit 1
fi

repshash=`curl -s $PREP_NODE_LIST_API -d '{ "jsonrpc" : "2.0", "method": "icx_getBlock", "id": 1234 }' | jq '.result.repsHash'`

for IP in `curl -s $PREP_NODE_LIST_API -d '{ "jsonrpc" : "2.0", "method": "rep_getListByHash", "id": 1234, "params": {"repsHash": '$repshash'} }' | jq '.result[].p2pEndpoint' | sed s/\"//g | awk -F: '{ print $1 }'`
do
	echo "allow $IP;" >> "$GRPC_WHITELIST_UPDATED"
done

oldChecksum=`cksum $GRPC_WHITELIST | awk '{ print $1 }'`
newChecksum=`cksum $GRPC_WHITELIST_UPDATED | awk '{ print $1 }'`

if [ "$newChecksum" != "$oldChecksum" ]; then
	# Update whitelist
	cat $GRPC_WHITELIST_UPDATED > $GRPC_WHITELIST
	rm $GRPC_WHITELIST_UPDATED
	# Reload NGINX
	docker exec -it $DOCKER_ID sh -c "nginx -s reload"
	echo "$DATE_TIME: Whitelist has been updated!" >> $UPDATE_LOG
else
	rm $GRPC_WHITELIST_UPDATED
	echo "$DATE_TIME: Skip whitelist update due to no changes!" >> $UPDATE_LOG
fi

EOF


cat<<EOF >>/home/ubuntu/nginx/access_lists/grpc_whitelist.conf
#allow <IP ADDRESS OR RANGE>;
EOF

cat<<EOF >>/home/ubuntu/nginx/access_lists/api_blacklist.conf
#deny <IP ADDRESS OR RANGE>;
EOF

cat<<EOF >>/home/ubuntu/nginx/nginx.conf
worker_processes 4;

events {
  worker_connections 500;
}

http {
  geo \$limit {
    default 1;
  }
  map \$limit \$limit_key {
      0 "";
      1 \$binary_remote_addr;
  }
  limit_req_zone \$limit_key zone=LimitZoneAPI:10m rate=200r/s;

  map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
  }

  upstream citizen-api {
    server citizen:9000;
  }

  log_format api_log 'Proxy IP: \$remote_addr | Client IP: \$http_x_forwarded_for | Time: \$time_local' ' Request: "\$request" | Status: \$status | Bytes Sent: \$body_bytes_sent | Referrer: "\$http_referer"' ' User Agent: "\$http_user_agent"';

  server {
    listen 9000;
    listen [::]:9000;

    access_log /var/log/nginx/access_api.log api_log;

    # Apply throtteling
    limit_req zone=LimitZoneAPI burst=50 delay=10;

    location / {
      # Apply blacklist
      include /etc/nginx/access_lists/api_blacklist.conf;
      allow all;

      # Forward traffic
      proxy_pass http://citizen-api;
      proxy_set_header X-Forwarded-For \$remote_addr;
      proxy_set_header X-Forwarded-Host \$host;

      # Websocket support
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
    }
  }
}

stream {
  limit_conn_zone \$binary_remote_addr zone=LimitZoneGRPC:10m;

  upstream citizen-grpc {
    server citizen:7100;
  }

  log_format grpc_log 'Client IP: \$remote_addr | Time: \$time_local';

  server {
    listen 7100;
    listen [::]:7100;

    access_log /var/log/nginx/access_grpc.log grpc_log;

    # Apply throtteling
    limit_conn LimitZoneGRPC 100;

    # Apply whitelist
    #include /etc/nginx/access_lists/grpc_whitelist.conf;
    #deny all;

    # Forward traffic
    proxy_pass citizen-grpc;
  }
}
EOF

#TODO: Add keystore to bucket for TestNet.  Need to streamline keystore handling
# We could  SCP it in via terraform

# Cloudwatch
curl https://s3.amazonaws.com//aws-cloudwatch/downloads/latest/awslogs-agent-setup.py -O
chmod +x ./awslogs-agent-setup.py
/awslogs-agent-setup.py -n -r us-east-1 -c s3://${log_config_bucket}/${log_config_key}.

#wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
#dpkg -i amazon-cloudwatch-agent.deb
# OLD ^^^


docker-compose up -f /home/ubuntu/docker-compose.yaml -d
