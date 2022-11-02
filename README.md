[![](https://github.com/doitintl/gtoken/workflows/Docker%20Image%20CI/badge.svg)](https://github.com/doitintl/gtoken/actions?query=workflow%3A"Docker+Image+CI") [![Docker Pulls](https://img.shields.io/docker/pulls/doitintl/gtoken.svg?style=popout)](https://hub.docker.com/r/doitintl/gtoken "gtoken image") [![Docker Pulls](https://img.shields.io/docker/pulls/doitintl/gtoken-webhook.svg?style=popout)](https://hub.docker.com/r/doitintl/gtoken-webhook "gtoken-webhook image") [![](https://images.microbadger.com/badges/image/doitintl/gtoken.svg)](https://microbadger.com/images/doitintl/gtoken "gtoken image") [![](https://images.microbadger.com/badges/image/doitintl/gtoken-webhook.svg)](https://microbadger.com/images/doitintl/gtoken-webhook "gtoken-webhook image")

# Securely access AWS Services from GKE cluster

Ever wanted to access AWS services from Google Kubernetes cluster (GKE) without using AWS IAM credentials?

This solution can help you to get and exchange Google OIDC token for temporary AWS IAM security credentials are generated by AWS STS service. This approach allows you to access AWS services form a GKE cluster without pre-generated long-living AWS credentials.

Read more about this solution on DoiT [Securely Access AWS Services from Google Kubernetes Engine (GKE)](https://blog.doit-intl.com/securely-access-aws-from-gke-dba1c6dbccba?source=friends_link&sk=779821ca975ddb312916e1be732c637f) blog post.

# `gtoken` tool

The `gtoken` tool can get Google Cloud ID token when running with under GCP Service Account (for example, GKE Pod with Workload Identity).

## `gtoken` command syntax

```text
NAME:
   gtoken - generate ID token with current Google Cloud service account

USAGE:
   gtoken [global options] command [command options] [arguments...]

COMMANDS:
   help, h  Shows a list of commands or help for one command

GLOBAL OPTIONS:
   --refresh      auto refresh ID token before it expires (default: true)
   --file value   write ID token into file (stdout, if not specified)
   --help, -h     show help (default: false)
   --version, -v  print the version
```

# `gtoken-webhook` Kubernetes webhook

The `gtoken-webhook` is a Kubernetes mutating admission webhook, that mutates any K8s Pod running under specially annotated Kubernetes Service Account (see details below).

## `gtoken-webhook` mutation

The `gtoken-webhook` injects a `gtoken` `initContainer` into a target Pod and an additional `gtoken` sidekick container (to refresh an ID OIDC token a moment before expiration), mounts _token volume_ and injects three AWS-specific environment variables. The `gtoken` container generates a valid GCP OIDC ID Token and writes it to the _token volume_.

Injected AWS environment variables:

- `AWS_WEB_IDENTITY_TOKEN_FILE` - the path to the web identity token file (OIDC ID token)
- `AWS_ROLE_ARN` - the ARN of the role to assume by Pod containers
- `AWS_ROLE_SESSION_NAME` - the name applied to this assume-role session

The AWS SDK will automatically make the corresponding `AssumeRoleWithWebIdentity` calls to AWS STS on your behalf. It will handle in memory caching as well as refreshing credentials as needed.

## `gtoken-webhook` deployment

1. To deploy the `gtoken-webhook` server, we need to create a webhook service and a deployment in our Kubernetes cluster. It’s pretty straightforward, except one thing, which is the server’s TLS configuration. If you’d care to examine the [deployment.yaml](https://github.com/doitintl/gtoken/blob/master/deployment/deployment.yaml) file, you’ll find that the certificate and corresponding private key files are read from command line arguments, and that the path to these files comes from a volume mount that points to a Kubernetes secret:

```yaml
[...]
      args:
      [...]
      - --tls-cert-file=/etc/webhook/certs/cert.pem
      - --tls-private-key-file=/etc/webhook/certs/key.pem
      volumeMounts:
      - name: webhook-certs
        mountPath: /etc/webhook/certs
        readOnly: true
[...]
   volumes:
   - name: webhook-certs
     secret:
       secretName: gtoken-webhook-certs
```

The most important thing to remember is to set the corresponding CA certificate later in the webhook configuration, so the `apiserver` will know that it should be accepted. For now, we’ll reuse the script originally written by the Istio team to generate a certificate signing request. Then we’ll send the request to the Kubernetes API, fetch the certificate, and create the required secret from the result.

First, run [webhook-create-signed-cert.sh](https://github.com/doitintl/gtoken/blob/master/deployment/webhook-create-signed-cert.sh) script and check if the secret holding the certificate and key has been created:

```text
./deployment/webhook-create-signed-cert.sh

creating certs in tmpdir /var/folders/vl/gxsw2kf13jsf7s8xrqzcybb00000gp/T/tmp.xsatrckI71
Generating RSA private key, 2048 bit long modulus
.........................+++
....................+++
e is 65537 (0x10001)
certificatesigningrequest.certificates.k8s.io/gtoken-webhook-svc.default created
NAME                         AGE   REQUESTOR              CONDITION
gtoken-webhook-svc.default   1s    alexei@doit-intl.com   Pending
certificatesigningrequest.certificates.k8s.io/gtoken-webhook-svc.default approved
secret/gtoken-webhook-certs configured
```

**Note** For the GKE Autopilot, run the [webhook-create-self-signed-cert.sh](https://github.com/doitintl/gtoken/blob/master/deployment/webhook-create-self-signed-cert.sh) script to generate a self-signed certificate.

Export CA Bundle as environment variable:

```sh
export CA_BUNDLE=[output value of the previous script "Encoded CA:"]
```

Then, we’ll create the webhook service and deployment:

```yaml
```

Create Kubernetes Service Account to be used with `gtoken-webhook`:

```sh
kubectl create -f deployment/service-account.yaml
```

Once the secret is created, we can create deployment and service. These are standard Kubernetes deployment and service resources. Up until this point we’ve produced nothing but an HTTP server that’s accepting requests through a service on port 443:

```sh
kubectl create -f deployment/deployment.yaml

kubectl create -f deployment/service.yaml
```

### configure mutating admission webhook

Now that our webhook server is running, it can accept requests from the `apiserver`. However, we should create some configuration resources in Kubernetes first. Let’s start with our validating webhook, then we’ll configure the mutating webhook later. If you take a look at the [webhook configuration](https://github.com/doitintl/gtoken/blob/master/deployment/mutatingwebhook.yaml), you’ll notice that it contains a placeholder for `CA_BUNDLE`:

```yaml
[...]
      service:
        name: gtoken-webhook-svc
        namespace: default
        path: "/pods"
      caBundle: ${CA_BUNDLE}
[...]
```

There is a [small script](https://github.com/doitintl/gtoken/blob/master/deployment/webhook-patch-ca-bundle.sh) that substitutes the CA_BUNDLE placeholder in the configuration with this CA. Run this command before creating the validating webhook configuration:

```sh
cat ./deployment/mutatingwebhook.yaml | ./deployment/webhook-patch-ca-bundle.sh > ./deployment/mutatingwebhook-bundle.yaml
```

Create mutating webhook configuration:

```sh
kubectl create -f deployment/mutatingwebhook-bundle.yaml
```

### configure RBAC for gtoken-webhook

Define RBAC permission for webhook service account:

```sh
# create a cluster role
kubectl create -f deployment/clusterrole.yaml
# define a cluster role binding
kubectl create -f deployment/clusterrolebinding.yaml
```

## Configuration Flow

### Flow variables

- `PROJECT_ID` - GCP project ID
- `CLUSTER_NAME` - GKE cluster name
- `CLUSTER_ZONE` - GKE cluster zone
- `GSA_NAME` - Google Cloud Service Account name (choose any)
- `GSA_ID` - Google Cloud Service Account unique ID (generated by Google)
- `KSA_NAME` - Kubernetes Service Account name (choose any)
- `KSA_NAMESPACE` - Kubernetes namespace
- `AWS_ROLE_NAME` - AWS IAM role name (choose any)
- `AWS_POLICY_NAME` - an **existing** AWS IAM policy to assign to IAM role
- `AWS_ROLE_ARN` - AWS IAM Role ARN identifier (generated by AWS)

### GCP: Enable GKE Workload Identity

Create a new GKE cluster with [Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity) enabled:

```sh
gcloud container clusters create ${CLUSTER_NAME} \
    --zone=${CLUSTER_ZONE} \
    --workload-pool=${PROJECT_ID}.svc.id.goog
```

or update an existing cluster:

```sh
gcloud container clusters update ${CLUSTER_NAME} \
    --zone=${CLUSTER_ZONE} \
    --workload-pool=${PROJECT_ID}.svc.id.goog
```

### GCP: Configure GCP Service Account

Create Google Cloud Service Account:

```sh
# create GCP Service Account
gcloud iam service-accounts create ${GSA_NAME}

# get GCP SA UID to be used for AWS Role with Google OIDC Web Identity
GSA_ID=$(gcloud iam service-accounts describe --format json ${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com  | jq -r '.uniqueId')
```

Update `GSA_NAME` Google Service Account with following roles:

- `roles/iam.workloadIdentityUser` - impersonate service accounts from GKE Workloads
- `roles/iam.serviceAccountTokenCreator` - impersonate service accounts to create OAuth2 access tokens, sign blobs, or sign JWTs

```sh
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com \
  --role roles/iam.serviceAccountTokenCreator

gcloud iam service-accounts add-iam-policy-binding \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${K8S_NAMESPACE}/${KSA_NAME}]" \
  ${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com
```

### AWS: Create AWS IAM Role with Google OIDC Web Identity

```sh
# prepare role trust policy document for Google OIDC provider
cat > gcp-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "accounts.google.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "accounts.google.com:sub": "${GSA_ID}"
        }
      }
    }
  ]
}
EOF

# create AWS IAM Rome with Google Web Identity
aws iam create-role --role-name ${AWS_ROLE_NAME} --assume-role-policy-document file://gcp-trust-policy.json

# assign AWS role desired policies
aws iam attach-role-policy --role-name ${AWS_ROLE_NAME} --policy-arn arn:aws:iam::aws:policy/${AWS_POLICY_NAME}

# get AWS Role ARN to be used in K8s SA annotation
AWS_ROLE_ARN=$(aws iam get-role --role-name ${AWS_ROLE_NAME} --query Role.Arn --output text)
```

### GKE: Kubernetes Service Account

Create K8s namespace:

```sh
kubectl create namespace ${K8S_NAMESPACE}
```

Create K8s Service Account:

```sh
kubectl create serviceaccount --namespace ${K8S_NAMESPACE} ${KSA_NAME}
```

Annotate K8s Service Account with GKE Workload Identity (GCP Service Account email)

```sh
kubectl annotate serviceaccount --namespace ${K8S_NAMESPACE} ${KSA_NAME} \
  iam.gke.io/gcp-service-account=${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com

```

Annotate K8s Service Account with AWS Role ARN:

```sh
kubectl annotate serviceaccount --namespace ${K8S_NAMESPACE} ${KSA_NAME} \
  amazonaws.com/role-arn=${AWS_ROLE_ARN}
```

### Run demo

Run a new K8s Pod with K8s ${KSA_NAME} Service Account:

```sh
# run a pod (with AWS CLI onboard) in interactive mod
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: ${K8S_NAMESPACE}
spec:
  serviceAccountName: ${KSA_NAME}
  containers:
  - name: test-pod
    image: mikesir87/aws-cli
    command: ["tail", "-f", "/dev/null"]
EOF

# in Pod shell: check AWS assumed role
aws sts get-caller-identity

# the output should look similar to below
{
    "UserId": "AROA9GB4GPRFFXVHNSLCK:gtoken-webhook-gyaashbbeeqhpvfw",
    "Account": "906385953612",
    "Arn": "arn:aws:sts::906385953612:assumed-role/bucket-full-gtoken/gtoken-webhook-gyaashbbeeqhpvfw"
}

```

## External references

I've borrowed an initial mutating admission webhook code and deployment guide from [banzaicloud/admission-webhook-example](https://github.com/banzaicloud/admission-webhook-example) repository. Big thanks to Banzai Cloud team!
