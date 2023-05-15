#!/bin/bash

# install jq
yum install -y jq
echo "[`date +%Y/%m/%d-%H:%M:%S`] - install jq"

# ENV
# export AWS_DEFAULT_REGION=ap-northeast-1
export AWS_DEFAULT_REGION=$(curl http://169.254.169.254/latest/dynamic/instance-identity/document -s| jq -r ".region")
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
export AWS_BUCKET=eks-20230519-${AWS_ACCOUNT_ID}
export AWS_FARGATE_ROLE=EKSFargatePodExecRole1
export AWS_EKS_CLUSTER_NAME=eks-fargate
export KUBERNETES_VERSION=1.25


# install awscli2
mkdir temp
cd temp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf /bin/aws
ln -s /usr/local/bin/aws /bin/aws
echo "[`date +%Y/%m/%d-%H:%M:%S`] - install awscli2"

# install eksctl
curl -OL "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz"
tar -zxf eksctl_$(uname -s)_amd64.tar.gz
mv -f ./eksctl /usr/bin
echo "[`date +%Y/%m/%d-%H:%M:%S`] - install eksctl"

# install kubectl
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.26.2/2023-03-17/bin/linux/amd64/kubectl
chmod +x ./kubectl
mv ./kubectl /usr/local/bin
echo "[`date +%Y/%m/%d-%H:%M:%S`] - install kubectl"

# create Fargate IAM Role
cat <<EOF > role-trust-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "eks-fargate-pods.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

cat <<EOF > role-inline-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogStream",
                "logs:CreateLogGroup",
                "logs:DescribeLogStreams",
                "logs:PutLogEvents"
            ],
            "Resource": "*"
        }
    ]
}
EOF

aws iam create-role --role-name ${AWS_FARGATE_ROLE} --assume-role-policy-document file://role-trust-policy.json

aws iam attach-role-policy --role-name ${AWS_FARGATE_ROLE} --policy-arn arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy

aws iam put-role-policy --role-name ${AWS_FARGATE_ROLE} --policy-name cloudwatchlogs --policy-document file://role-inline-policy.json

echo "[`date +%Y/%m/%d-%H:%M:%S`] - create Fargate IAM Role"

# create EKS Fargate Cluster

cat <<EOF > eks_cluster.yml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
    name: ${AWS_EKS_CLUSTER_NAME}
    region: ${AWS_DEFAULT_REGION}
    version: "${KUBERNETES_VERSION}"
vpc:
    clusterEndpoints:
        publicAccess: true
        privateAccess: true
# availabilityZones:
#      - us-east-1a
#      - us-east-1b
#      - us-east-1c
cloudWatch:
    clusterLogging:
      enableTypes: 
        - "all"
      logRetentionInDays: 30
fargateProfiles:
    - name: default
      podExecutionRoleARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/EKSFargatePodExecRole
      selectors:
      - namespace: default
    - name: kube-system
      podExecutionRoleARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/EKSFargatePodExecRole
      selectors:
      - namespace: kube-system
    - name: fargate-container-insights
      podExecutionRoleARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/EKSFargatePodExecRole
      selectors:
      - namespace: fargate-container-insights
EOF

eksctl create cluster -f eks_cluster.yml

echo "[`date +%Y/%m/%d-%H:%M:%S`] - create EKS Fargate Cluster"

# create OIDC Provider
eksctl utils associate-iam-oidc-provider --cluster=${AWS_EKS_CLUSTER_NAME} --approve
echo "[`date +%Y/%m/%d-%H:%M:%S`] - create OIDC Provider"

echo "[`date +%Y/%m/%d-%H:%M:%S`] - init completed"

