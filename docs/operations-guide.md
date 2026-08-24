# Operations guide

Day-to-day operation, monitoring, and troubleshooting for `cloud-devops-lab-2025`.

---

## Contents

- [Starting and stopping the environment](#starting-and-stopping-the-environment)
- [Reaching the services](#reaching-the-services)
- [Monitoring](#monitoring)
- [Alerting](#alerting)
- [Routine tasks](#routine-tasks)
- [Troubleshooting](#troubleshooting)
- [Recovery](#recovery)

---

## Starting and stopping the environment

### Starting up

```bash
# 1. Restore the NAT gateway
cd terraform/main
terraform apply

# 2. Start both instances
aws ec2 start-instances --region us-east-1 --instance-ids <bastion-id> <app-id>

# 3. Confirm connectivity (wait ~60s for boot)
cd ../../ansible
ansible all -m ping

# 4. Bring the containers up
ansible app -m shell -a "cd /opt/tool-stack && docker compose up -d" --become

# 5. Open the tunnel
ssh -f -N -o ServerAliveInterval=30 -L 8080:10.0.2.219:80 \
  -i ~/.ssh/devops-lab.pem ubuntu@<bastion-eip>
```

The bastion address is an Elastic IP and does not change between sessions.

Instance IDs, if needed:

```bash
aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:Name,Values=devops-lab-*" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,ID:InstanceId,State:State.Name}' \
  --output table
```

### Shutting down

```bash
cd terraform/main
terraform apply -var enable_nat=false
aws ec2 stop-instances --region us-east-1 --instance-ids <bastion-id> <app-id>
```

The NAT gateway is the only resource that bills continuously with no stopped state. Destroying
it between sessions is the single most effective cost measure. Docker volumes and the EBS
root volumes survive both operations, so Jenkins jobs, Grafana dashboards and SonarQube
history are preserved.

---

## Reaching the services

Everything runs on the private application server, which has no public IP. Access is via an
SSH tunnel through the bastion:

```bash
ssh -f -N -o ServerAliveInterval=30 -L 8080:10.0.2.219:80 \
  -i ~/.ssh/devops-lab.pem ubuntu@<bastion-eip>
```

| Service | URL |
|---------|-----|
| Jenkins | `http://localhost:8080/jenkins` |
| SonarQube | `http://localhost:8080/sonar` |
| Grafana | `http://localhost:8080/grafana` |

`ServerAliveInterval=30` keeps the connection from being dropped as idle. Add
`ExitOnForwardFailure=yes` to fail loudly rather than connecting without forwarding when the
port is already occupied.

Check whether a tunnel is running:

```bash
pgrep -fl "8080:10.0.2.219"
curl -I http://localhost:8080/jenkins       # expect HTTP 301
```

Stop it:

```bash
pkill -f "8080:10.0.2.219"
```

If the tunnel drops repeatedly, `autossh` reconnects automatically:

```bash
brew install autossh
autossh -f -N -M 0 -o ServerAliveInterval=30 \
  -L 8080:10.0.2.219:80 -i ~/.ssh/devops-lab.pem ubuntu@<bastion-eip>
```

---

## Monitoring

### What is collected

Prometheus scrapes five targets every fifteen seconds:

| Job | Target | Provides |
|-----|--------|----------|
| `prometheus` | `localhost:9090` | Prometheus's own health |
| `node` | `node-exporter:9100` | Host CPU, memory, disk, network |
| `cadvisor` | `cadvisor:8080` | Per-container resource usage |
| `jenkins` | `jenkins:8080/jenkins/prometheus` | Build durations, counts, queue |
| `app` | `devops-lab-app:5000` | Application request rates and latency |

Check target health:

```bash
ansible app -m shell -a \
  "docker exec tool-stack-prometheus-1 wget -qO- 'http://localhost:9090/api/v1/targets'" --become
```

Look for `"health":"up"` on each. The `app` target reports down whenever the application
container is not running — expected after a shutdown, and resolved by running the pipeline.

### Dashboards

**Node Exporter Full** (Grafana dashboard 1860) covers the host. The top gauge row shows CPU
busy, memory used, swap used and disk used at a glance.

**Jenkins metrics** is a custom dashboard. The metric names carry a `default_` prefix:

| Metric | Meaning |
|--------|---------|
| `default_jenkins_builds_last_build_duration_milliseconds` | Duration of the most recent build |
| `default_jenkins_builds_success_build_count_total` | Cumulative successful builds |
| `default_jenkins_builds_health_score` | Jenkins' own 0–100 job health rating |

These change only when a build runs, so the graphs show flat lines with steps rather than
continuous variation.

**SonarQube** presents its own code quality view at `/sonar`, covering bugs, vulnerabilities,
code smells and duplication.

### Interpreting host metrics

| Signal | Healthy | Investigate |
|--------|---------|-------------|
| CPU busy | Under 40% idle, spikes during builds | Sustained above 70% |
| Memory used | Under 80% | Above 90%, or swap climbing |
| Swap used | Near zero | Any sustained use — memory pressure |
| Disk used | Under 70% | Above 85% — prune images |

Swap in active use is the earliest warning of memory exhaustion. The kernel will begin killing
processes if memory runs out entirely; containers terminated this way exit with code 137.

### CloudWatch

CloudWatch monitors from outside the instance, which matters because Prometheus runs *on* the
application server and dies with it. If the instance fails, CloudWatch is the only thing still
watching.

- **Log group** `/devops-lab/app-server` receives forwarded syslog, retained seven days
- **Alarm** `devops-lab-app-high-cpu` fires on two consecutive five-minute periods above 70%

The two-period requirement prevents build-time CPU spikes from triggering it.

---

## Alerting

Three rules are defined in `docker/alerts.yml`:

| Alert | Condition | Duration |
|-------|-----------|----------|
| `JenkinsDown` | `up{job="jenkins"} == 0` | 5 minutes |
| `HighCPU` | Host CPU above 70% | 5 minutes |
| `AppDown` | `up{job="app"} == 0` | 2 minutes |

`up` is generated automatically by Prometheus for every target, so no instrumentation is
required for availability checks.

The `for` duration on each rule prevents alerting on transient blips — the condition must hold
continuously for the full period before the alert fires.

Alertmanager receives fired alerts and posts to Slack. With `send_resolved: true` it also
sends a recovery message when the condition clears.

### Testing the alerting path

```bash
ansible app -m shell -a "docker stop devops-lab-app" --become
```

Sequence: Prometheus notices within 15 seconds, the rule enters pending, and after two minutes
of continuous failure it fires and Slack receives the message. Restore by triggering a Jenkins
build, which recreates the container.

This is worth running periodically — an alerting pipeline that has never fired is an untested
one.

---

## Routine tasks

### Deploying a code change

Push to `main`. Jenkins builds, tests, scans, publishes and deploys automatically. Watch the
console output; the commit message at the top confirms which revision was built.

### Changing a service configuration

Files in `docker/` are mounted into containers from `/opt/tool-stack` on the server. Editing
locally is not enough:

```bash
cd ansible
ansible-playbook deploy-stack.yml
ansible app -m shell -a "cd /opt/tool-stack && docker compose restart <service>" --become
```

The first command ships the file; the second makes the service re-read it.

### Adding a Prometheus target

Add a `scrape_configs` entry in `docker/prometheus.yml`, then deploy and restart as above.
Targets are addressed by Docker service name, not IP.

### Rolling back a deployment

Images are tagged with the build number, so any previous build can be redeployed:

```bash
ansible app -m shell -a \
  "docker rm -f devops-lab-app && docker run -d --name devops-lab-app \
   --network tool-stack_default -p 5000:5000 rayyan43/devops-lab-app:<n>" --become
```

### Reclaiming disk

The pipeline prunes dangling images after every run. For a deeper clean:

```bash
ansible app -m shell -a "docker system df" --become
ansible app -m shell -a "docker image prune -a -f" --become
```

`prune -a` removes all images not currently used by a container, including ones you may want
to roll back to. Check `docker images` first.

---

## Troubleshooting

### AWS API rejects every request

```
InvalidSignatureException: Signature expired
SignatureDoesNotMatch
```

System clock drift. AWS rejects requests signed more than five minutes out of sync, and the
error never mentions time.

```bash
sudo sntp -sS time.apple.com
date -u                                    # compare against real UTC
sudo systemsetup -getusingnetworktime      # check automatic sync is on
```

If drift recurs, point at a different time server:

```bash
sudo systemsetup -setnetworktimeserver time.google.com
sudo systemsetup -setusingnetworktime on
```

### SSH to the bastion times out

Your public address has changed and the security group no longer permits it. A timeout rather
than a refusal is the signature of a firewall silently dropping packets.

```bash
curl -4 ifconfig.me
cd terraform/main
terraform apply -var "my_ip=$(curl -4 -s ifconfig.me)/32"
```

The `-4` is essential. On a dual-stack network `curl ifconfig.me` returns an IPv6 address,
which will never match an IPv4 security group rule.

If the address is correct, confirm the instances are actually running.

### Ansible fails on the app server only

```
Connection timed out during banner exchange
```

The bastion connects but the tunnel to the private instance does not complete. Three causes,
in order of likelihood:

**The `ProxyCommand` holds a stale address.** The bastion IP appears twice in
`inventory.ini` — as the host in `[bastion]`, and inside the `ProxyCommand` string. Confirm
both:

```bash
grep <bastion-ip> inventory.ini      # expect two lines
```

**The connection was simply slow.** Tunnelled connections take longer to establish than
Ansible's default timeout allows. Raise it in `ansible.cfg`:

```ini
timeout = 60
```

**The instance is still booting.** Test the hop directly, which shows the underlying error
that Ansible suppresses:

```bash
ssh -o ProxyCommand="ssh -W %h:%p -q ubuntu@<bastion-ip> -i ~/.ssh/devops-lab.pem" \
    -i ~/.ssh/devops-lab.pem ubuntu@10.0.2.219
```

### Browser cannot reach a service

Determine which layer failed:

```bash
curl -I http://localhost:8080/jenkins
```

| Response | Cause | Action |
|----------|-------|--------|
| `301` or `403` | Working | Refresh the browser |
| Connection refused | Tunnel down | Restart the tunnel |
| `502 Bad Gateway` | Backend container down | `docker compose up -d <service>` |
| Hangs indefinitely | Instance unreachable | Check instance state and security group |

A running SSH process does not guarantee a working forward — a stale connection can persist
after the tunnel has stopped functioning. Kill and reconnect rather than assuming.

### nginx will not start

```
host not found in upstream "sonarqube"
```

nginx resolves upstream hostnames once at startup and refuses to start if any are missing, so
one stopped backend takes down the entire proxy. The configuration works around this by
placing each backend in a variable, which defers resolution to request time:

```nginx
resolver 127.0.0.11 valid=10s;
set $sonar sonarqube:9000;
proxy_pass http://$sonar$request_uri;
```

A missing service now returns 502 on its own path while everything else keeps working. If the
error reappears, check that the resolver directive is present.

### Pipeline fails at Build image

```
docker: not found
```

The Jenkins image contains Java, not the Docker CLI. Mounting the socket grants access to the
daemon but supplies no client to talk to it.

```bash
ansible-playbook deploy-stack.yml   # includes the CLI install task
ansible app -m shell -a "cd /opt/tool-stack && docker compose restart jenkins" --become
```

If the error becomes *permission denied* rather than *not found*, the `jenkins` user is not in
a group matching the socket's owner GID on the host.

### SonarQube analysis fails to bootstrap

```
Failed to parse the entry in the bootstrap index: <!doctype html>
```

The scanner received an HTML page instead of an API response. SonarQube is served under the
`/sonar` context path, so its API is at `/sonar/api/...`:

```
-Dsonar.host.url=http://sonarqube:9000/sonar
```

Omitting the suffix returns the login page, which the scanner cannot parse.

### Jenkins builds green but nothing changed

Jenkins built a different revision than the one you edited. The commit message at the top of
the console output is the only reliable confirmation:

```
Commit message: "..."
```

Check that the branch specifier in the job configuration matches the branch you pushed to, and
that the push actually succeeded — branch protection rejects direct pushes to `main`.

### Grafana panels show no data

Check in this order:

1. **Data source configured** — Connections → Data sources → Prometheus at
   `http://prometheus:9090`, tested green
2. **Target healthy** — query the Prometheus targets API
3. **Metric name correct** — query the label values endpoint and grep:

```bash
ansible app -m shell -a \
  "docker exec tool-stack-prometheus-1 wget -qO- \
   'http://localhost:9090/api/v1/label/__name__/values' | tr ',' '\n' | grep <prefix>" --become
```

Community dashboards frequently reference metric names from older exporter versions. If a
dashboard is empty while the underlying metrics exist, the dashboard is outdated, not the
collection.

### Container exits immediately

```bash
ansible app -m shell -a "docker ps -a --filter status=exited" --become
ansible app -m shell -a "docker logs --tail 50 <container>" --become
```

Exit code 137 means the kernel terminated it for memory. Check available memory and consider
running fewer services concurrently or resizing the instance.

---

## Recovery

### Terraform state is locked

```
Error acquiring the state lock
```

If a previous run was interrupted, the lock persists after the process is gone. The error
names who holds it and when it was taken — confirm no run is genuinely in progress before
forcing:

```bash
terraform force-unlock <LOCK_ID>
```

Force-unlocking a live operation causes exactly the state corruption locking exists to
prevent.

### Locked out of the application server

The private instance has no public IP, so SSH misconfiguration cannot be fixed remotely.
Recovery requires stopping the instance, detaching its root EBS volume, attaching it to
another instance, mounting it, correcting `/etc/ssh/sshd_config`, and reattaching.

This is why `hardening.yml` should always be run with a second SSH session already open — an
established connection survives the SSH daemon restarting and provides a way back in.

### State file lost or corrupted

The S3 bucket has versioning enabled. Restore a previous version through the S3 console or:

```bash
aws s3api list-object-versions --bucket <bucket> --prefix infra/terraform.tfstate
aws s3api get-object --bucket <bucket> --key infra/terraform.tfstate \
  --version-id <version> terraform.tfstate
```

Without state, Terraform loses track of every resource it created — they keep running and
billing while becoming invisible to it.

### Everything from scratch

The environment is fully reproducible from this repository. Follow the setup sequence in the
README: bootstrap, infrastructure, Ansible, tool stack, Jenkins, monitoring. The only manual
steps are creating the key pair and entering credentials into Jenkins and SonarQube.