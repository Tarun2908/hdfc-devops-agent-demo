# How to deploy the EKS web app with one CloudFormation stack

Repository: https://github.com/Tarun2908/hdfc-devops-agent-demo

One stack creates a VPC, an EKS cluster with add-ons, an RDS MySQL database, and a sample web page that reads from the database. The page is served from the internet through an Application Load Balancer. Nothing needs to be run by hand after the stack is created.

## Before you start

- An AWS account and a user or role that can create VPC, EKS, EC2, RDS, IAM, KMS, Secrets Manager, CodeBuild, Lambda, EventBridge, CloudWatch Logs and ELB resources.
- The AWS CLI v2, configured for that account (`aws sts get-caller-identity` works).
- Enough quota for 2 NAT gateways, 2 Elastic IPs and 2 EC2 instances in the region.
- Roughly 25 to 40 minutes. CloudFormation gives up after 60 minutes.

## Why the template goes through S3

CloudFormation accepts templates only from an S3 URL or a direct upload. A direct upload is limited to 51,200 bytes, and `infra/eks-webapp.yaml` is about 100 KB because it embeds the app and the deploy scripts. CloudFormation also cannot read a template from a `github.com` or `raw.githubusercontent.com` URL. So the template is copied from the repository to an S3 bucket in your account first. The AWS console does this for you when you upload the file.

## Option A: AWS CLI (recommended)

Run these from the repository root. Change `REGION` and `BUCKET` first. Bucket names are global, so pick a unique one.

```bash
git clone https://github.com/Tarun2908/hdfc-devops-agent-demo.git
cd hdfc-devops-agent-demo

export REGION=ap-south-1
export BUCKET=my-unique-cfn-templates-$(aws sts get-caller-identity --query Account --output text)

# 1. Create a private bucket and upload the template
aws s3 mb s3://$BUCKET --region $REGION
aws s3 cp infra/eks-webapp.yaml s3://$BUCKET/eks-webapp.yaml --region $REGION

# 2. Check the template
aws cloudformation validate-template \
  --template-url https://$BUCKET.s3.$REGION.amazonaws.com/eks-webapp.yaml \
  --region $REGION

# 3. Create the stack with default parameters
aws cloudformation create-stack \
  --stack-name eks-webapp \
  --template-url https://$BUCKET.s3.$REGION.amazonaws.com/eks-webapp.yaml \
  --capabilities CAPABILITY_IAM \
  --region $REGION

# 4. Wait until it finishes (about 30 minutes)
aws cloudformation wait stack-create-complete --stack-name eks-webapp --region $REGION

# 5. Read the outputs
aws cloudformation describe-stacks --stack-name eks-webapp --region $REGION \
  --query "Stacks[0].Outputs" --output table
```

On Windows PowerShell, set the variables with `$env:REGION = "ap-south-1"` and use `$env:BUCKET` in place of `$BUCKET`.

## Option B: AWS console

1. Open CloudFormation in your region and choose **Create stack > With new resources**.
2. Choose **Upload a template file**, select `infra/eks-webapp.yaml` from a clone of the repository, and choose **Next**. The console stores it in S3 for you.
3. Enter a stack name such as `eks-webapp`. Leave the parameters at their defaults, or change them (see below).
4. On the review page, tick **I acknowledge that AWS CloudFormation might create IAM resources**, then choose **Submit**.
5. When the status is `CREATE_COMPLETE`, open the **Outputs** tab.

## Optional: a true one-click link

After the template is in S3 (Option A, steps 1 and 2), this link opens the console with the template and stack name filled in. Replace `REGION` and `BUCKET`.

```
https://REGION.console.aws.amazon.com/cloudformation/home?region=REGION#/stacks/quickcreate?templateURL=https%3A%2F%2FBUCKET.s3.REGION.amazonaws.com%2Feks-webapp.yaml&stackName=eks-webapp
```

You still tick the IAM acknowledgement and choose **Create stack**. The person who opens the link needs permission to read the object in the bucket. To share the link with other accounts, the bucket policy must allow it, which is outside this guide.

## Parameters you may want to change

All parameters have defaults, so none are required.

| Parameter | Default | When to change it |
|-----------|---------|-------------------|
| `ProjectName`, `Environment` | `eks-webapp`, `dev` | To name and tag resources for your team. |
| `VpcCidr` | `10.0.0.0/16` | If it overlaps another network. Prefix /16 to /24. |
| `IngressCidr` | `0.0.0.0/0` | To limit who can open the web page, for example your office range. |
| `ApiAccessCidr` | `0.0.0.0/0` | To limit who can reach the public Kubernetes API. Set it to your own IP range. |
| `KubernetesVersion` | `1.36` | To use another version in the allowed list. |
| `NodeInstanceType`, `NodeMinSize`, `NodeDesiredSize`, `NodeMaxSize` | `t3.medium`, 2, 2, 4 | To change capacity. Keep min <= desired <= max and max at least 1. |
| `AdminPrincipalArn` | empty | To give another IAM user or role cluster admin access. The stack creator always has it. |
| `DbInstanceClass`, `DbAllocatedStorage`, `DbMultiAz` | `db.t3.micro`, 20, `false` | For a larger or highly available database. |
| `EnableDbLogExport` | `false` | To send MySQL error and slow query logs to CloudWatch. |
| `AppReplicas` | 2 | To run more web pods. |
| `CertificateArn` | empty | To serve HTTPS. Give an ACM certificate ARN from the same region. HTTP then redirects to HTTPS. |

The web page is open to the whole internet by default, as you asked. For anything beyond a demo, set `IngressCidr` and `ApiAccessCidr` to known ranges.

## Check that it works

1. In the stack **Outputs**, copy `ApplicationUrl` and open it in a browser. You should see a list of five sample items read from the database.
2. Open `<ApplicationUrl>/healthz`. It should show `ok`.
3. Optional, from your own machine (the AWS identity that created the stack is a cluster admin):

```bash
# Use the KubeconfigCommand output, for example:
aws eks update-kubeconfig --name eks-webapp-dev --region $REGION
kubectl get nodes
kubectl get pods -n webapp
kubectl get ingress -n webapp
```

If you set `ApiAccessCidr`, run `kubectl` from inside that range.

## What happens during creation

1. The template checks the node size parameters.
2. The VPC, subnets, NAT gateways, security groups and KMS keys are created.
3. The EKS cluster, node group and managed add-ons are created. This is the slowest part.
4. The database and its secret are created in parallel.
5. A CodeBuild job installs the AWS Load Balancer Controller and checks that every add-on is healthy.
6. A second CodeBuild job applies the web app and waits for the load balancer address. That address becomes `ApplicationUrl`.

## Delete everything

```bash
aws cloudformation delete-stack --stack-name eks-webapp --region $REGION
aws cloudformation wait stack-delete-complete --stack-name eks-webapp --region $REGION
```

The deploy job first removes the Ingress and waits for the load balancer and its network interfaces to disappear, so the stack can delete cleanly. Expect 15 to 30 minutes.

Things that stay behind on purpose:
- A final database snapshot named after the stack. Delete it in RDS if you do not need it.
- The Secrets Manager secret stays scheduled for deletion for its recovery window (7 to 30 days) and then disappears.
- The S3 bucket and template you created for the upload. Remove them with `aws s3 rb s3://$BUCKET --force`.

## Cost

While the stack runs, you pay mainly for the EKS control plane, 2 EC2 nodes, 2 NAT gateways, the load balancer and the RDS instance. Delete the stack when you finish a demo.

## Troubleshooting

| Symptom | What to check |
|---------|---------------|
| `Template format error` or a size error on upload | You used direct upload through the API. Use the S3 URL. |
| Stack fails early with `Invalid node group sizes` | Fix `NodeMinSize <= NodeDesiredSize <= NodeMaxSize`. |
| Stack fails on `AddonsStage` or `AppStage` | Open CodeBuild, find the project named `<stack-name>-deployer`, and read the latest build log. The failure reason in the stack events names the component. |
| Stack waits a long time on `AppStage` | The load balancer is still being created. Wait up to 15 minutes. |
| The page shows "Service unavailable" | The pods cannot reach the database or cannot install their packages. Run `kubectl logs -n webapp deploy/webapp` and `kubectl describe pod -n webapp`. The pods download `pymysql` and `boto3` from PyPI when they start, through the NAT gateways. |
| Delete ends in `DELETE_FAILED` | Read the failed resource in the stack events. The most common cause is a leftover load balancer network interface. Retry the delete after a few minutes. |
| Quota errors | Request higher limits for Elastic IPs, NAT gateways or the instance type. |

## Known limits of this version

- The deploy scripts and the template have not yet been run in a real AWS account. Treat the first deploy as a test in a sandbox account.
- The web page code is embedded in the template, so changes to `app/app.py` reach the stack only after the template is rebuilt and the stack is updated.
- Pods depend on PyPI being reachable at start-up. A prebuilt container image would remove that dependency.
