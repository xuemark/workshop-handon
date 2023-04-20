#!/bin/bash
yum install -y jq
# ENV
# export AWS_DEFAULT_REGION=ap-northeast-1
export AWS_DEFAULT_REGION=$(curl -s 169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
export AWS_BUCKET=forecast-20230421-${AWS_ACCOUNT_ID}
export AWS_FORECAST_ROLE=forecast-execrole
export FORECAST_DATASET_1=forecastdata
# install awscli2
mkdir temp
cd temp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf /bin/aws
ln -s /usr/local/bin/aws /bin/aws
echo "[`date +%Y/%m/%d-%H:%M:%S`] - install awscli2"
# create Forecast exec role
cat <<EOF > role-inline-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::*"
            ]
        }
    ]
}
EOF
cat <<EOF > role-trust-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "forecast.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
aws iam create-role --role-name ${AWS_FORECAST_ROLE} --assume-role-policy-document file://role-trust-policy.json
aws iam put-role-policy --role-name ${AWS_FORECAST_ROLE} --policy-name policy --policy-document file://role-inline-policy.json
echo "[`date +%Y/%m/%d-%H:%M:%S`] - create IAM role"
sleep 10
# create S3 bucket
aws s3 mb s3://${AWS_BUCKET}
# upload dataset
wget https://static.us-east-1.prod.workshops.aws/public/bbb9acaf-724c-43c7-ac07-f0aa6a1e468b/static/attachments/Lab1/NYC_Taxi_TimeSeriesDataset.csv
aws s3 cp NYC_Taxi_TimeSeriesDataset.csv s3://${AWS_BUCKET}/
echo "[`date +%Y/%m/%d-%H:%M:%S`] - upload dataset to s3"
# create Dataset
echo "[`date +%Y/%m/%d-%H:%M:%S`] - Start Tasks - ${FORECAST_DATASET_1}"
aws forecast create-dataset-group --dataset-group-name ${FORECAST_DATASET_1} --domain CUSTOM

aws forecast create-dataset --dataset-name ${FORECAST_DATASET_1} --domain CUSTOM --dataset-type TARGET_TIME_SERIES --data-frequency 1H \
    --schema 'Attributes=[{AttributeName=item_id,AttributeType=string},{AttributeName=timestamp,AttributeType=timestamp},{AttributeName=target_value,AttributeType=float}]'
aws forecast update-dataset-group --dataset-group-arn arn:aws:forecast:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:dataset-group/${FORECAST_DATASET_1} --dataset-arns arn:aws:forecast:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:dataset/${FORECAST_DATASET_1}
aws forecast create-dataset-import-job --dataset-import-job-name ${FORECAST_DATASET_1} --timestamp-format 'yyyy-MM-dd HH:mm:ss' \
    --no-use-geolocation-for-time-zone --format CSV \
    --dataset-arn arn:aws:forecast:ap-northeast-1:${AWS_ACCOUNT_ID}:dataset/${FORECAST_DATASET_1} \
    --data-source 'S3Config={Path='s3://${AWS_BUCKET}/NYC_Taxi_TimeSeriesDataset.csv',RoleArn='arn:aws:iam::${AWS_ACCOUNT_ID}:role/${AWS_FORECAST_ROLE}'}'

while  [ "$(aws forecast describe-dataset-import-job --dataset-import-job-arn arn:aws:forecast:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:dataset-import-job/${FORECAST_DATASET_1}/${FORECAST_DATASET_1}  --query Status --output text)" != "ACTIVE" ];
do
    echo "[`date +%Y/%m/%d-%H:%M:%S`] - $(aws forecast describe-dataset-import-job --dataset-import-job-arn arn:aws:forecast:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:dataset-import-job/${FORECAST_DATASET_1}/${FORECAST_DATASET_1}  --query Status --output text)";
    sleep 10;
done

echo "[`date +%Y/%m/%d-%H:%M:%S`] - Dataset Import Job Completed"
# create auto predictor
cat <<EOF > data-config.json
{
    "DatasetGroupArn": "arn:aws:forecast:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:dataset-group/${FORECAST_DATASET_1}",
    "AttributeConfigs": [
        {
            "AttributeName": "target_value",
            "Transformations": {
                "aggregation": "sum",
                "backfill": "zero",
                "frontfill": "none",
                "middlefill": "zero"
            }
        }
    ],
    "AdditionalDatasets": [
        {
            "Name": "holiday",
            "Configuration": {
                "CountryCode": [
                    "US"
                ]
            }
        }
    ]
}
EOF
export FORECAST_PREDICTOR_ARN=$(aws forecast create-auto-predictor --predictor-name ${FORECAST_DATASET_1} --explain-predictor  --forecast-types "0.10" "0.50" "0.9" \
    --forecast-frequency 1H --forecast-horizon 24 \
    --data-config file://data-config.json \
    --query PredictorArn --output text)
echo "FORECAST_PREDICTOR_ARN: ${FORECAST_PREDICTOR_ARN}"
while  [ "$(aws forecast describe-auto-predictor --predictor-arn ${FORECAST_PREDICTOR_ARN} --query Status --output text)" != "ACTIVE" ];
do
    echo "[`date +%Y/%m/%d-%H:%M:%S`] - $(aws forecast describe-auto-predictor --predictor-arn ${FORECAST_PREDICTOR_ARN} --query Status --output text)";
    sleep 30;
done
echo "[`date +%Y/%m/%d-%H:%M:%S`] - Create Auto Predictor Completed"
# create forecast
aws forecast create-forecast --forecast-name ${FORECAST_DATASET_1} --predictor-arn  ${FORECAST_PREDICTOR_ARN} --forecast-types "0.10" "0.50" "0.9" 
while  [ "$(aws forecast describe-forecast --forecast-arn arn:aws:forecast:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:forecast/${FORECAST_DATASET_1}  --query Status --output text)" != "ACTIVE" ];
do
    echo "[`date +%Y/%m/%d-%H:%M:%S`] - $(aws forecast describe-forecast --forecast-arn arn:aws:forecast:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:forecast/${FORECAST_DATASET_1}  --query Status --output text)";
    sleep 30;
done
echo "[`date +%Y/%m/%d-%H:%M:%S`] - Create Forecast Completed"
# create explainability
cat <<EOF > itemids.csv
item_id
1
2
3
4
5
6
7
8
9
10
11
12
13
14
15
16
17
18
19
20
EOF
aws s3 cp itemids.csv s3://${AWS_BUCKET}/
aws forecast create-explainability --explainability-name ${FORECAST_DATASET_1}_forecast \
--resource-arn arn:aws:forecast:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:forecast/${FORECAST_DATASET_1} \
--data-source 'S3Config={Path='s3://${AWS_BUCKET}/itemids.csv',RoleArn='arn:aws:iam::${AWS_ACCOUNT_ID}:role/${AWS_FORECAST_ROLE}'}' \
--schema 'Attributes={AttributeName=item_id,AttributeType=string}' --enable-visualization \
--explainability-config 'TimeSeriesGranularity=SPECIFIC,TimePointGranularity=ALL'
while  [ "$(aws forecast describe-explainability --explainability-arn arn:aws:forecast:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:explainability/${FORECAST_DATASET_1}_forecast --query Status --output text)" != "ACTIVE" ];
do
    echo "[`date +%Y/%m/%d-%H:%M:%S`] - $(aws forecast describe-explainability --explainability-arn arn:aws:forecast:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:explainability/${FORECAST_DATASET_1}_forecast --query Status --output text)";
    sleep 30;
done
echo "[`date +%Y/%m/%d-%H:%M:%S`] - Create Forecast Explainability Completed"
# create Forecast Export Job
aws forecast create-forecast-export-job --forecast-export-job-name ${FORECAST_DATASET_1} \
--forecast-arn arn:aws:forecast:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:forecast/${FORECAST_DATASET_1} \
--destination 'S3Config={Path='s3://${AWS_BUCKET}/export/',RoleArn='arn:aws:iam::${AWS_ACCOUNT_ID}:role/${AWS_FORECAST_ROLE}'}'
while  [ "$(aws forecast describe-forecast-export-job --forecast-export-job-arn arn:aws:forecast:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:forecast-export-job/${FORECAST_DATASET_1}/${FORECAST_DATASET_1} --query Status --output text)" != "ACTIVE" ];
do
    echo "[`date +%Y/%m/%d-%H:%M:%S`] - $(aws forecast describe-forecast-export-job --forecast-export-job-arn arn:aws:forecast:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:forecast-export-job/${FORECAST_DATASET_1}/${FORECAST_DATASET_1} --query Status --output text)";
    sleep 30;
done
echo "[`date +%Y/%m/%d-%H:%M:%S`] - Create Forecast Export Job Completed"