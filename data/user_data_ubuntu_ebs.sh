#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get upgrade -y
apt-get install -y linux-aws
apt-get install -y awscli
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

# Create the file ansible hardening depends on. Playbook fails if this file does not exist.
# TODO: Investigate why the existence of file, even empty, is needed. Or configure it accordingly.
touch /etc/security/limits.d/10.hardcore.conf

cat<<EOF>>/home/ubuntu/docker-compose.yaml
version: '3'
services:
  citizen:
    image: 'iconloop/citizen-node:1908271151xd2b7a4'
    network_mode: host
    environment:
      LOG_OUTPUT_TYPE: "file"
      LOOPCHAIN_LOG_LEVEL: "DEBUG"
      FASTEST_START: "yes"     # Restore from lastest snapshot DB

    volumes:
      - ./data:/data  # mount a data volumes
      - ./keys:/citizen_pack/keys  # Automatically generate cert key files here
    ports:
      - 9000:9000
EOF
#TODO: Add keystore to bucket for TestNet.  Need to streamline keystore handling
# We could  SCP it in via terraform

# Cloudwatch
#curl https://s3.amazonaws.com//aws-cloudwatch/downloads/latest/awslogs-agent-setup.py -O
#chmod +x ./awslogs-agent-setup.py
#/awslogs-agent-setup.py -n -r us-east-1 -c s3://${log_config_bucket}/${log_config_key}.

#wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
#dpkg -i amazon-cloudwatch-agent.deb
# OLD ^^^

