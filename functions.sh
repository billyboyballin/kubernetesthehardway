#! /bin/bash

set -euo pipefail

############################### Prerequisites ###############################
install_awscli () {
  sudo apt install unzip
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip awscliv2.zip
  sudo ./aws/install
}

install_cfssl () {
  wget -q --show-progress --https-only --timestamping \
    https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/1.4.1/linux/cfssl \
    https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/1.4.1/linux/cfssljson
  chmod +x cfssl cfssljson
  sudo mv cfssl /usr/local/bin/
  sudo mv cfssljson /usr/local/bin/
}

install_kubectl () {
  wget https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kubectl
  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/
}

# check everything installed correctly by running
# 'cfssl version && cfssljson --version && kubectl version --client'

############################### Infrastructure ###############################

create_vpc () {
  VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --output text --query 'Vpc.VpcId')
  aws ec2 create-tags --resources ${VPC_ID} --tags Key=Name,Value=kubernetes-the-hard-way
  aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-support '{"Value": true}'
  aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-hostnames '{"Value": true}'
}

create_subnet () {
  SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id ${VPC_ID} \
    --cidr-block 10.0.1.0/24 \
    --output text --query 'Subnet.SubnetId')
  aws ec2 create-tags --resources ${SUBNET_ID} --tags Key=Name,Value=kubernetes
}

create_internetgateway () {
  INTERNET_GATEWAY_ID=$(aws ec2 create-internet-gateway --output text --query 'InternetGateway.InternetGatewayId')
  aws ec2 create-tags --resources ${INTERNET_GATEWAY_ID} --tags Key=Name,Value=kubernetes
  aws ec2 attach-internet-gateway --internet-gateway-id ${INTERNET_GATEWAY_ID} --vpc-id ${VPC_ID}
}

create_routetable () {
  ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id ${VPC_ID} --output text --query 'RouteTable.RouteTableId')
  aws ec2 create-tags --resources ${ROUTE_TABLE_ID} --tags Key=Name,Value=kubernetes
  aws ec2 associate-route-table --route-table-id ${ROUTE_TABLE_ID} --subnet-id ${SUBNET_ID}
  aws ec2 create-route --route-table-id ${ROUTE_TABLE_ID} --destination-cidr-block 0.0.0.0/0 --gateway-id ${INTERNET_GATEWAY_ID}
}

create_securitygroups () {
  SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name kubernetes \
    --description "Kubernetes security group" \
    --vpc-id ${VPC_ID} \
    --output text --query 'GroupId')
  aws ec2 create-tags --resources ${SECURITY_GROUP_ID} --tags Key=Name,Value=kubernetes
  aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol all --cidr 10.0.0.0/16
  aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol all --cidr 10.200.0.0/16
  aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol tcp --port 22 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol tcp --port 6443 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol tcp --port 443 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol icmp --port -1 --cidr 0.0.0.0/0
}

create_networkloadbalancer () {
  LOAD_BALANCER_ARN=$(aws elbv2 create-load-balancer \
    --name kubernetes \
    --subnets ${SUBNET_ID} \
    --scheme internet-facing \
    --type network \
    --output text --query 'LoadBalancers[].LoadBalancerArn')

  TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
    --name kubernetes \
    --protocol TCP \
    --port 6443 \
    --vpc-id ${VPC_ID} \
    --target-type ip \
    --output text --query 'TargetGroups[].TargetGroupArn')

  aws elbv2 register-targets --target-group-arn ${TARGET_GROUP_ARN} --targets Id=10.0.1.1{0,1,2}

  aws elbv2 create-listener \
    --load-balancer-arn ${LOAD_BALANCER_ARN} \
    --protocol TCP \
    --port 443 \
    --default-actions Type=forward,TargetGroupArn=${TARGET_GROUP_ARN} \
    --output text --query 'Listeners[].ListenerArn'
}

get_kubernetespublicaddress () {
  KUBERNETES_PUBLIC_ADDRESS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns ${LOAD_BALANCER_ARN} \
    --output text --query 'LoadBalancers[].DNSName')
}

create_imageid () {
  IMAGE_ID=$(aws ec2 describe-images --owners 099720109477 \
    --filters \
    'Name=root-device-type,Values=ebs' \
    'Name=architecture,Values=x86_64' \
    'Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*' \
    | jq -r '.Images|sort_by(.Name)[-1]|.ImageId')
}

create_sshkey () {
  aws ec2 create-key-pair --key-name kubernetes --output text --query 'KeyMaterial' > kubernetes.id_rsa
  chmod 600 kubernetes.id_rsa
}

create_masternodes () {
  for i in 0 1 2; do
    instance_id=$(aws ec2 run-instances \
      --associate-public-ip-address \
      --image-id ${IMAGE_ID} \
      --count 1 \
      --key-name kubernetes \
      --security-group-ids ${SECURITY_GROUP_ID} \
      --instance-type t3.micro \
      --private-ip-address 10.0.1.1${i} \
      --user-data "name=controller-${i}" \
      --subnet-id ${SUBNET_ID} \
      --block-device-mappings='{"DeviceName": "/dev/sda1", "Ebs": { "VolumeSize": 50 }, "NoDevice": "" }' \
      --output text --query 'Instances[].InstanceId')
    aws ec2 modify-instance-attribute --instance-id ${instance_id} --no-source-dest-check
    aws ec2 create-tags --resources ${instance_id} --tags "Key=Name,Value=controller-${i}"
    echo "controller-${i} created "
  done
}

create_workernodes () {
  for i in 0 1 2; do
    instance_id=$(aws ec2 run-instances \
      --associate-public-ip-address \
      --image-id ${IMAGE_ID} \
      --count 1 \
      --key-name kubernetes \
      --security-group-ids ${SECURITY_GROUP_ID} \
      --instance-type t3.micro \
      --private-ip-address 10.0.1.2${i} \
      --user-data "name=worker-${i}|pod-cidr=10.200.${i}.0/24" \
      --subnet-id ${SUBNET_ID} \
      --block-device-mappings='{"DeviceName": "/dev/sda1", "Ebs": { "VolumeSize": 50 }, "NoDevice": "" }' \
      --output text --query 'Instances[].InstanceId')
    aws ec2 modify-instance-attribute --instance-id ${instance_id} --no-source-dest-check
    aws ec2 create-tags --resources ${instance_id} --tags "Key=Name,Value=worker-${i}"
    echo "worker-${i} created"
  done
}

############################### Certificates ###############################

# Certificate authority. Creates
# ca-key.pem and ca.pem
generate_certificateauthority () {
  cat > ca-config.json <<EOF
  {
    "signing": {
      "default": {
        "expiry": "8760h"
      },
      "profiles": {
        "kubernetes": {
          "usages": ["signing", "key encipherment", "server auth", "client auth"],
          "expiry": "8760h"
        }
      }
    }
  }
EOF

  cat > ca-csr.json <<EOF
  {
    "CN": "Kubernetes",
    "key": {
      "algo": "rsa",
      "size": 2048
    },
    "names": [
      {
        "C": "US",
        "L": "Ashburn",
        "O": "Kubernetes",
        "OU": "CA",
        "ST": "Virginia"
      }
    ]
  }
EOF

  cfssl gencert -initca ca-csr.json | cfssljson -bare ca
}

# Admin client certificate. Creates
# admin-key.pem and admin.pem
create_admincerts () {
  cat > admin-csr.json <<EOF
  {
    "CN": "admin",
    "key": {
      "algo": "rsa",
      "size": 2048
    },
    "names": [
      {
        "C": "US",
        "L": "Ashburn",
        "O": "system:masters",
        "OU": "Kubernetes The Hard Way",
        "ST": "Virginia"
      }
    ]
  }
EOF

  cfssl gencert \
    -ca=ca.pem \
    -ca-key=ca-key.pem \
    -config=ca-config.json \
    -profile=kubernetes \
    admin-csr.json | cfssljson -bare admin
}

# Kubelet client certificates. Creates
# worker-0-key.pem and worker-0.pem
# worker-1-key.pem and worker-1.pem
# worker-2-key.pem and worker-2.pem
create_workercerts () {
  for i in 0 1 2; do
    instance="worker-${i}"
    instance_hostname="ip-10-0-1-2${i}"
    cat > ${instance}-csr.json <<EOF
  {
    "CN": "system:node:${instance_hostname}",
    "key": {
      "algo": "rsa",
      "size": 2048
    },
    "names": [
      {
        "C": "US",
        "L": "Ashburn",
        "O": "system:nodes",
        "OU": "Kubernetes The Hard Way",
        "ST": "Virginia"
      }
    ]
  }
EOF

    external_ip=$(aws ec2 describe-instances --filters \
      "Name=tag:Name,Values=${instance}" \
      "Name=instance-state-name,Values=running" \
      --output text --query 'Reservations[].Instances[].PublicIpAddress')

    internal_ip=$(aws ec2 describe-instances --filters \
      "Name=tag:Name,Values=${instance}" \
      "Name=instance-state-name,Values=running" \
      --output text --query 'Reservations[].Instances[].PrivateIpAddress')

    cfssl gencert \
      -ca=ca.pem \
      -ca-key=ca-key.pem \
      -config=ca-config.json \
      -hostname=${instance_hostname},${external_ip},${internal_ip} \
      -profile=kubernetes \
      worker-${i}-csr.json | cfssljson -bare worker-${i}
  done
}

# Kube controller manager client certificate. Creates
# kube-controller-manager-key.pem kube-controller-manager.pem
create_controllercerts () {
  cat > kube-controller-manager-csr.json <<EOF
  {
    "CN": "system:kube-controller-manager",
    "key": {
      "algo": "rsa",
      "size": 2048
    },
    "names": [
      {
        "C": "US",
        "L": "Ashburn",
        "O": "system:kube-controller-manager",
        "OU": "Kubernetes The Hard Way",
        "ST": "Virginia"
      }
    ]
  }
EOF

  cfssl gencert \
    -ca=ca.pem \
    -ca-key=ca-key.pem \
    -config=ca-config.json \
    -profile=kubernetes \
    kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager
}

# Kube proxy client certificates. Creates
# kube-proxy-key.pem and kube-proxy.pem
create_proxycerts () {
  cat > kube-proxy-csr.json <<EOF
  {
    "CN": "system:kube-proxy",
    "key": {
      "algo": "rsa",
      "size": 2048
    },
    "names": [
      {
        "C": "US",
        "L": "Ashburn",
        "O": "system:node-proxier",
        "OU": "Kubernetes The Hard Way",
        "ST": "Virginia"
      }
    ]
  }
EOF

  cfssl gencert \
    -ca=ca.pem \
    -ca-key=ca-key.pem \
    -config=ca-config.json \
    -profile=kubernetes \
    kube-proxy-csr.json | cfssljson -bare kube-proxy
}

# Kube schedular client certificates. Creates
# kube-schedular-key.pem and kube-schedular.pem
create_schedularcerts () {
  cat > kube-scheduler-csr.json <<EOF
  {
    "CN": "system:kube-scheduler",
    "key": {
      "algo": "rsa",
      "size": 2048
    },
    "names": [
      {
        "C": "US",
        "L": "Ashburn",
        "O": "system:kube-scheduler",
        "OU": "Kubernetes The Hard Way",
        "ST": "Virginia"
      }
    ]
  }
EOF

  cfssl gencert \
    -ca=ca.pem \
    -ca-key=ca-key.pem \
    -config=ca-config.json \
    -profile=kubernetes \
    kube-scheduler-csr.json | cfssljson -bare kube-scheduler

}

# Kube API server certificates. Creates
# kubernetes-key.pem and kubernetes.pem
create_apicerts () {
  cat > kubernetes-csr.json <<EOF
  {
    "CN": "kubernetes",
    "key": {
      "algo": "rsa",
      "size": 2048
    },
    "names": [
      {
        "C": "US",
        "L": "Ashburn",
        "O": "Kubernetes",
        "OU": "Kubernetes The Hard Way",
        "ST": "Virginia"
      }
    ]
  }
EOF

  cfssl gencert \
    -ca=ca.pem \
    -ca-key=ca-key.pem \
    -config=ca-config.json \
    -hostname=10.32.0.1,10.0.1.10,10.0.1.11,10.0.1.12,${KUBERNETES_PUBLIC_ADDRESS},127.0.0.1,kubernetes.default \
    -profile=kubernetes \
    kubernetes-csr.json | cfssljson -bare kubernetes
}

# Service account key pair. Creates
# service-account-key.pem and service-account.pem
create_serviceaccountcerts () {
  cat > service-account-csr.json <<EOF
  {
    "CN": "service-accounts",
    "key": {
      "algo": "rsa",
      "size": 2048
    },
    "names": [
      {
        "C": "US",
        "L": "Ashburn",
        "O": "Kubernetes",
        "OU": "Kubernetes The Hard Way",
        "ST": "Virginia"
      }
    ]
  }
EOF

  cfssl gencert \
    -ca=ca.pem \
    -ca-key=ca-key.pem \
    -config=ca-config.json \
    -profile=kubernetes \
    service-account-csr.json | cfssljson -bare service-account
}

# Distribute
distribute_workers () {
  for instance in worker-0 worker-1 worker-2; do
    external_ip=$(aws ec2 describe-instances --filters \
      "Name=tag:Name,Values=${instance}" \
      "Name=instance-state-name,Values=running" \
      --output text --query 'Reservations[].Instances[].PublicIpAddress')

    scp -i kubernetes.id_rsa ca.pem ${instance}-key.pem ${instance}.pem ubuntu@${external_ip}:~/
  done
}

distribute_controllers () {
  for instance in controller-0 controller-1 controller-2; do
    external_ip=$(aws ec2 describe-instances --filters \
      "Name=tag:Name,Values=${instance}" \
      "Name=instance-state-name,Values=running" \
      --output text --query 'Reservations[].Instances[].PublicIpAddress')

    scp -i kubernetes.id_rsa \
      ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem \
      service-account-key.pem service-account.pem ubuntu@${external_ip}:~/
  done
}

############################### Kubeconfig Files ###############################

# Creates worker-0.kubeconfig worker-1.kubeconfig worker-2.kubeconfig
create_worker_kubeconfig () {
  for instance in worker-0 worker-1 worker-2; do
    kubectl config set-cluster kubernetes-the-hard-way \
      --certificate-authority=ca.pem \
      --embed-certs=true \
      --server=https://${KUBERNETES_PUBLIC_ADDRESS}:443 \
      --kubeconfig=${instance}.kubeconfig

    kubectl config set-credentials system:node:${instance} \
      --client-certificate=${instance}.pem \
      --client-key=${instance}-key.pem \
      --embed-certs=true \
      --kubeconfig=${instance}.kubeconfig

    kubectl config set-context default \
      --cluster=kubernetes-the-hard-way \
      --user=system:node:${instance} \
      --kubeconfig=${instance}.kubeconfig

    kubectl config use-context default --kubeconfig=${instance}.kubeconfig
  done
}

# Creates kube-proxy.kubeconfig
create_kubeproxy_kubeconfig () {
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:443 \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-credentials system:kube-proxy \
    --client-certificate=kube-proxy.pem \
    --client-key=kube-proxy-key.pem \
    --embed-certs=true \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-proxy \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig
}

# Creates kube-controller-manager.kubeconfig
create_controllermanager_kubeconfig () {
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config set-credentials system:kube-controller-manager \
    --client-certificate=kube-controller-manager.pem \
    --client-key=kube-controller-manager-key.pem \
    --embed-certs=true \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-controller-manager \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig
}

# Creates kube-scheduler.kubeconfig
create_schedular_kubeconfig () {
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config set-credentials system:kube-scheduler \
    --client-certificate=kube-scheduler.pem \
    --client-key=kube-scheduler-key.pem \
    --embed-certs=true \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-scheduler \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig
}

# Creates admin.kubeconfig
create_admin_kubeconfig () {
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=admin.kubeconfig

  kubectl config set-credentials admin \
    --client-certificate=admin.pem \
    --client-key=admin-key.pem \
    --embed-certs=true \
    --kubeconfig=admin.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=admin \
    --kubeconfig=admin.kubeconfig

  kubectl config use-context default --kubeconfig=admin.kubeconfig
}

# Distribute
distrubte_kubelet_kubeproxy_workers () {
  for instance in worker-0 worker-1 worker-2; do
    external_ip=$(aws ec2 describe-instances --filters \
      "Name=tag:Name,Values=${instance}" \
      "Name=instance-state-name,Values=running" \
      --output text --query 'Reservations[].Instances[].PublicIpAddress')

    scp -i kubernetes.id_rsa \
      ${instance}.kubeconfig kube-proxy.kubeconfig ubuntu@${external_ip}:~/
  done
}

distrubute_controllermanager_schedular_controllers () {
  for instance in controller-0 controller-1 controller-2; do
    external_ip=$(aws ec2 describe-instances --filters \
      "Name=tag:Name,Values=${instance}" \
      "Name=instance-state-name,Values=running" \
      --output text --query 'Reservations[].Instances[].PublicIpAddress')

    scp -i kubernetes.id_rsa \
      admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig ubuntu@${external_ip}:~/
  done
}
