# p2p_file_sharing — AWS infrastructure

Terraform for deploying [J0Ss3/p2p_file_sharing](https://github.com/J0Ss3/p2p_file_sharing):
a single ECS container behind CloudFront, which supplies HTTPS and a stable URL without a
load balancer, domain, or certificate to manage.

```
CloudFront (TLS, WebSocket passthrough)
  -> EC2 t3.micro + Elastic IP (ECS-optimized AMI, default VPC)
     -> ECS service, 1 task, host :80 -> container :3000
```

The app keeps WebRTC signalling rooms in process memory, so the service is pinned to a
single task. Files move browser-to-browser over WebRTC and never reach this infrastructure.

## Prerequisites

- `terraform` >= 1.6, `aws` CLI, and `docker` (the image is built locally and pushed to ECR)
- AWS credentials with permissions for ECR, ECS, EC2, IAM, CloudWatch Logs, and CloudFront

If `docker` is not usable by your user, pass `-var container_cli=podman`; the build and push
work identically under podman.

## Usage

```bash
terraform init
terraform apply
terraform output -raw url
```

The first apply takes roughly ten minutes; most of that is CloudFront propagating.

To rebuild after upstream changes, bump the ref and apply again:

```bash
terraform apply -var app_ref=main -replace=terraform_data.image
```

## Verifying a deployment

```bash
URL=$(terraform output -raw url)
curl -sI "$URL" | head -1                      # HTTP/2 200

curl -s -i --http1.1 -N --max-time 5 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H "Sec-WebSocket-Key: $(head -c16 /dev/urandom | base64)" \
  "$URL/ws" | head -1                          # HTTP/1.1 101 Switching Protocols
```

Note the WebSocket check must be a GET; a `HEAD` request to `/ws` returns 405.

Then open the URL in two browsers on different networks, pick a file in one, and open the
generated link or QR code in the other. Container logs land in the `/ecs/p2p-files`
CloudWatch log group.

## Cost

About **$14/month** in `us-east-1`: EC2 t3.micro $7.59, 30 GB gp3 $2.40, Elastic IP $3.60,
ECR storage ~$0.03. CloudFront traffic falls inside the perpetual 1 TB/month free tier.
Setting `-var instance_type=t3.nano` brings it to roughly $9/month, at the cost of leaving
very little memory for the ECS agent and dockerd.

```bash
terraform destroy
```

## Variables

| Name | Default | Purpose |
| --- | --- | --- |
| `region` | `us-east-1` | Deployment region |
| `name` | `p2p-files` | Name prefix for all resources |
| `instance_type` | `t3.micro` | Container instance size |
| `app_ref` | `main` | Git ref of the upstream repo to build |
| `container_cli` | `docker` | Tool used to build and push the image (`docker` or `podman`) |

## Known limits

- **One instance, no redundancy.** In-memory room state rules out scaling out. Moving
  signalling to Redis is the prerequisite for a second task.
- **No TURN server.** The client ships a STUN-only ICE config, so two peers that are both
  behind symmetric NAT will fail to connect. Fixing that needs a coturn deployment plus an
  `iceServers` change in the client.
- **Caching is disabled on all paths**, so static assets always hit the origin. Fine at this
  scale; split `/ws` into its own behavior and switch the default to `CachingOptimized` if
  traffic grows.
- **Terraform state is local.** Add an S3 backend before a second person runs apply.
