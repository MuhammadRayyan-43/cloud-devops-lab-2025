# Decision log

Why each tool and pattern was chosen, what was rejected, and which constraints forced certain
outcomes. Entries are grouped by area rather than strictly chronological.

---

## Repository and process

### Repository structured by tool rather than environment

Top-level directories map to tools — `terraform/`, `ansible/`, `docker/`, `app/` — rather than
to environments such as `dev/` and `prod/`.

This is a single-environment project, so an environment split would create empty directories
and imply a promotion pipeline that does not exist. The tool boundaries also map cleanly onto
the pipeline stages, which makes the repository navigable by anyone who understands the
architecture.

For a multi-environment deployment the layout would invert: environment at the top level,
tools beneath, with shared modules extracted.

### Branch protection requires pull requests but zero approvals

A ruleset on `main` requires changes to arrive via pull request, blocks force pushes, and
prevents deletion. Required approvals are set to zero.

GitHub does not permit self-approval, so a non-zero requirement would make it impossible for a
sole contributor to merge anything. Zero approvals preserves the workflow — branch, push,
open, merge — while keeping the history reviewable and the branch protected against accidental
force pushes.

In a team the approval requirement would be at least one, and status checks would be required
to pass before merge.

### Kanban board populated retrospectively

The board was created and filled in at the end of the build rather than maintained throughout.

This is a limitation worth stating plainly. The value of a Kanban board is in making work
visible *while it is happening* — surfacing what is blocked, and limiting how much is in
flight at once. A board completed afterwards documents rather than tracks.

In a team setting the board would be the source of truth from the first day, with cards
created before work began and moved as it progressed.

---

## Terraform and state

### State backend split into a separate bootstrap directory

The S3 bucket and DynamoDB lock table are created by `terraform/bootstrap/`, which uses local
state. `terraform/main/` then uses them as its remote backend.

There is a circular dependency otherwise: a configuration cannot store its state in a bucket
it has not yet created. Splitting resolves it, and gives a second benefit — running
`terraform destroy` on the infrastructure can never delete the bucket holding that operation's
own state.

The alternative, creating the bucket in the main configuration and migrating afterwards, works
but leaves the bucket managed by state stored inside itself. Unwinding that at teardown is
awkward.

### Remote state configured before any infrastructure existed

The backend was set up as the first Terraform task, while the state file was empty.

Migrating state is a delicate operation. Doing it with nothing to lose costs nothing; doing it
once the VPC, instances, IAM and monitoring are tracked is a genuine risk. State locking also
matters as soon as more than one actor can run Terraform — a laptop and a CI pipeline — so
building it in from the start avoids retrofitting under pressure.

### DynamoDB locking retained despite deprecation

The project brief specifies DynamoDB for state locking. Recent AWS provider versions deprecate
`dynamodb_table` in favour of S3-native locking via `use_lockfile`, which removes the DynamoDB
dependency entirely.

The deprecated parameter was kept to match the requirement as written, accepting a warning on
every run. The modern equivalent would be a single configuration change.

### Managed NAT gateway over a NAT instance

A NAT instance on `t3.micro` would be free-tier eligible; the managed gateway costs roughly
$0.045/hour.

The instance alternative requires disabling `source_dest_check`, configuring IP forwarding and
iptables masquerading through `user_data`, and identifying the correct network interface name
for the instance type. Each of these fails silently — the symptom is package installs hanging
with no error to search for. It also provides no failover: if the instance stops, the private
subnet loses internet access entirely.

Cost is instead controlled by an `enable_nat` variable gating the gateway, its Elastic IP and
its route. `terraform apply -var enable_nat=false` removes the only continuously-billing
resource between working sessions while leaving the rest of the network intact.

### Bastion architecture rather than a directly exposed application server

The application server has no public IP and sits in a private subnet. Administrative access is
through a bastion host in the public subnet whose SSH port is restricted to a single address.

The application server holds Jenkins with Docker Hub credentials and pipeline access to the
AWS account, SonarQube, and Grafana. Exposing it directly would place all of that behind a
single correctly-configured firewall rule. The bastion is deliberately minimal — nothing runs
on it beyond SSH — so the internet-facing surface is small enough to reason about.

### Security group rules reference security groups, not CIDR ranges

The application server permits traffic from the bastion's *security group* rather than its IP
address.

An IP-based rule breaks whenever the bastion is replaced or its address changes. A group
reference expresses the actual intent — "anything that is the bastion" — and continues to hold
across rebuilds.

### IAM instance profile instead of credential files

The application server calls AWS using an attached IAM role with S3 read, CloudWatch agent and
SSM read permissions. No access keys exist on the instance.

Credential files are the most common source of AWS account compromise: they get committed to
repositories, baked into images, and copied into backups. A role has no file. AWS issues
temporary credentials to the instance and rotates them automatically.

The payoff is visible in the CloudWatch and SSM playbooks, which contain no credentials of any
kind and work regardless.

### Elastic IP attached to the bastion

The bastion's public address changed on every stop and start, requiring updates in two places
in the Ansible inventory each time. Four separate failures traced to updating one and not the
other.

A five-line Elastic IP resource made the address permanent. It is free while attached to a
running instance. Given the number of stop/start cycles across a multi-day build, this was
clearly worth the cost.

---

## Instance sizing

### Free-plan restrictions dictated instance selection

The account is on the AWS free plan, which rejects non-free-tier instance types at the API
level:

```
FreeTierRestrictionError: This operation is not available for free plan accounts
```

This is a hard refusal, not a billing warning. The initial plan of resizing to `t3.medium` for
SonarQube was therefore impossible.

Querying what the account actually permits revealed a wider set than expected:

```bash
aws ec2 describe-instance-types --region us-east-1 \
  --filters "Name=free-tier-eligible,Values=true" \
  --query 'InstanceTypes[].{Type:InstanceType,MemoryMiB:MemoryInfo.SizeInMiB}' --output table
```

`c7i-flex.large` at 4 GB was available and became the application server. The lesson is worth
recording: query the constraint rather than assuming its shape.

### Swap provisioned via user_data

The application server originally ran on `t3.micro` with 1 GB of memory. A 4 GB swap file is
created on first boot through `user_data`.

Without swap, memory exhaustion causes the kernel to terminate processes without warning —
containers exit with code 137 and no useful log. Swap is slow but survivable, and turns a hard
failure into degraded performance.

The block was retained after the resize. `user_data` runs only on first boot, so modifying it
later would require destroying and recreating the instance.

### Bastion kept at t3.micro

Only the application server was resized. The bastion runs nothing beyond SSH and has no reason
to be larger.

---

## Ansible

### SSH ProxyCommand for the private instance

The inventory reaches the application server through an SSH tunnel via the bastion, configured
once as a group variable:

```ini
ansible_ssh_common_args='-o ProxyCommand="ssh -W %h:%p -q ubuntu@<bastion> -i <key>"'
```

Ansible then addresses the private instance as though it were directly reachable, and SSH
performs the hop transparently. No manual jump is required for any playbook.

The trade-off is that the bastion address appears twice in the inventory — as a host and
inside the ProxyCommand — and updating only one produces a `banner exchange` timeout with no
indication of the cause. The Elastic IP removed the need to update it at all.

### Both UFW and Fail2Ban, though the brief permits either

The requirement reads "Fail2Ban **or** UFW." Both were applied, alongside the AWS security
groups already in place.

They defend against different things. Security groups and UFW are static: rules written in
advance, enforced identically every time. Fail2Ban is reactive — it reads authentication logs
and bans addresses exhibiting brute-force behaviour. A static rule cannot do this because the
attacker's address is unknown in advance.

Having UFW *and* security groups is defence in depth. A misconfigured security group — which
happened during this build — leaves the host firewall still standing.

### Sudoers file validated before installation

The task installing the `devops` sudoers rule uses `validate: visudo -cf %s`.

A malformed sudoers file can leave no user able to escalate privileges. On an instance with no
public IP and no console access, that is close to unrecoverable. Validation runs a syntax
check before the file is placed; on failure the task aborts and the broken file is never
installed.

### SSH hardening run with a second session held open

`hardening.yml` disables root login and password authentication, then restarts the SSH daemon.

An error in that configuration would lock out the only access path to a machine with no public
IP. Recovery would mean stopping the instance, detaching its root volume, mounting it
elsewhere, correcting the file and reattaching.

Restarting the SSH daemon does not terminate established sessions, so an already-open
connection provides a way back in. This is documented in the operations guide as a required
precaution rather than an optional one.

### Ansible Vault and SSM Parameter Store both used

They solve the same problem at different points.

**Vault** encrypts a file that lives in the repository. The encrypted file is safe to commit;
the vault password lives outside version control in a git-ignored file.

**SSM Parameter Store** holds values that never enter the repository at all. The code contains
only the parameter's *name*, which is harmless on its own.

SSM is the stronger mechanism, since there is no encrypted blob to attack offline. Vault is
useful where a value must travel with the code — a template variable, or configuration a
playbook needs before it can reach AWS.

Terraform creates the SSM parameters with `lifecycle { ignore_changes = [value] }` and
placeholder contents; real values are written separately with the AWS CLI. This keeps secrets
out of both the configuration and the Terraform state file.

---

## Docker and the tool stack

### Reverse proxy in front of the services

nginx receives all traffic and routes `/jenkins`, `/sonar` and `/grafana` to their respective
containers. No other service publishes a host port.

This gives a single entry point to control, a single place to configure timeouts and upload
limits, and — most importantly — means the backends cannot be reached directly even from
within the network. Adding a service requires one location block rather than another exposed
port.

### nginx configured to resolve upstreams per request

nginx resolves upstream hostnames once at startup and refuses to start if any cannot be
resolved. With six backends and limited memory, services are routinely started in groups —
which meant a single stopped container prevented the entire proxy from starting.

Placing each backend in a variable defers resolution to request time:

```nginx
resolver 127.0.0.11 valid=10s;
set $sonar sonarqube:9000;
proxy_pass http://$sonar$request_uri;
```

A missing service now returns 502 on its own path while every other route continues working.
`$request_uri` is required because variable-based `proxy_pass` does not forward the path
automatically.

### Docker CLI installed into the Jenkins container

The Jenkins image ships with Java and the Jenkins server. Mounting `/var/run/docker.sock`
grants access to the host's Docker daemon but provides no client to communicate with it.

The CLI is installed by an Ansible task after the container starts. This is the pragmatic
choice, not the correct one — it is undone whenever the container is recreated.

The durable alternative is a custom image:

```dockerfile
FROM jenkins/jenkins:lts
USER root
RUN apt-get update && apt-get install -y docker.io
USER jenkins
```

That would survive recreation and belongs in a longer-lived setup.

### Application server chosen over the bastion for the tool stack

Everything runs on the private instance. The bastion remains a bare SSH jump host.

Jenkins holds Docker Hub credentials, a Docker socket granting effective root on the host, and
pipeline access to AWS. Placing that on the internet-facing machine would defeat the purpose
of having a bastion at all.

---

## Pipeline

### Tests and linting run inside the built image

Rather than assembling a Python environment on the Jenkins agent, the pipeline builds the
Docker image first and then runs flake8 and pytest inside it:

```groovy
sh "docker run --rm ${IMAGE_NAME}:${IMAGE_TAG} python -m pytest tests/ -v"
```

This began as a workaround — the Jenkins image has no Python, so the original venv-based
approach failed immediately — but it is the better design regardless.

**The artifact that passes the tests is byte-for-byte the artifact that gets deployed.** The
earlier approach tested one environment and shipped another; they were probably identical, but
"probably" is where this class of bug lives. If the image is missing a dependency, the tests
catch it.

It also keeps Jenkins free of language runtimes. Every project brings its own environment in
its own image, and the build server never accumulates toolchains.

### Stage ordering: cheap checks before expensive ones

```
Checkout → Build image → Lint → Test → SonarQube → Push → Deploy → Smoke test
```

flake8 completes in about a second, pytest takes longer, and SonarQube longer still. Failing
on the cheapest check first minimises wasted time.

More importantly, all quality gates precede the push. A failing test or quality gate stops the
image from ever reaching Docker Hub. Placing analysis after publication would mean bad code
ships and is then flagged, which inverts the point.

### Images tagged with the build number and latest

Every build produces `:<BUILD_NUMBER>` and `:latest`.

The build number makes each image traceable to the exact pipeline run that produced it, and
makes rollback a specific rather than approximate operation. `:latest` is a moving pointer and
means nothing on its own — it is provided for convenience, not for deployment decisions.

### Deployment via docker run rather than Ansible

The Deploy stage runs `docker run` directly on the application server.

The brief specifies deployment via Ansible. The direct approach was chosen to get the pipeline
working end to end first; converting the stage to `ansible-playbook deploy-app.yml` is a
contained change that would match the requirement more precisely and centralise deployment
logic in one place.

This is recorded as a known deviation rather than an oversight.

### Smoke test after deployment

The pipeline finishes by curling `/health` on the deployed container with `curl -f`, so an
HTTP error exits non-zero and fails the build.

Without it, a container that starts but does not function would produce a green pipeline. The
`/health` endpoint exists specifically to give the deploy stage something cheap to verify
against.

---

## Application

### Deliberately minimal Flask application

Three routes, one helper function, three tests, a Dockerfile and a lint configuration.

The deliverable is the pipeline and the infrastructure. The pipeline behaves identically
whether the application is three endpoints or three hundred, so time spent on features would
demonstrate nothing the pipeline does not already exercise.

What the application does need, it has: tests that can genuinely fail, enough code for static
analysis to have something to report, a `/health` endpoint for deployment verification, and a
`/metrics` endpoint for Prometheus.

### Prometheus instrumentation via prometheus-flask-exporter

Two lines add request counts, latencies and status codes:

```python
from prometheus_flask_exporter import PrometheusMetrics
metrics = PrometheusMetrics(app)
```

Without this the `app` scrape target returns 404 and the only available data is container-level
resource usage from cAdvisor. Application-level metrics are what make an application dashboard
meaningful.

---

## Monitoring

### Prometheus and CloudWatch both used

They observe from different vantage points, and the difference matters.

Prometheus runs *on* the application server. If that instance fails, Prometheus fails with it
— and no alert is raised about the failure that matters most.

CloudWatch runs in AWS, outside the instance boundary. It keeps collecting when the machine is
gone, which is exactly when its data is most valuable.

Prometheus provides high-frequency application and container metrics at no cost; CloudWatch
provides durable infrastructure metrics and log retention. Neither substitutes for the other.

### Community dashboards imported rather than built

Grafana dashboard 1860 (Node Exporter Full) provides complete host metrics immediately.
Reproducing it by hand would take an hour and produce something worse.

Dashboard 193 for container metrics was imported and abandoned — it queries metric names from
an older cAdvisor and renders empty against current versions. The underlying metrics were
confirmed present by querying Prometheus directly, so the dashboard was the outdated
component, not the collection. Container metrics are not a stated requirement, so this was
left rather than pursued.

The general lesson: verify the data exists before debugging the visualisation.

### Alert rules use a for duration

Each rule requires its condition to hold continuously before firing — five minutes for Jenkins
and CPU, two for the application.

Instantaneous alerting on any transient failure produces noise that trains people to ignore
alerts. The `for` clause distinguishes a genuine outage from a momentary scrape failure.

`JenkinsDown` uses the `up` metric that Prometheus generates automatically for every target,
so availability alerting requires no instrumentation.

### Alertmanager separate from Prometheus

Prometheus evaluates rules and decides that something is wrong. Alertmanager receives fired
alerts and decides who hears about it, how often, and in what grouping.

Separating detection from notification means routing can change — different severities to
different channels, silencing during maintenance — without touching the rules themselves.

`send_resolved: true` is enabled so recovery is reported as well as failure. An alert with no
resolution message leaves the reader unsure whether the problem is still live.

### Slack webhook is a placeholder in version control

`docker/alertmanager.yml` contains a placeholder URL. The real webhook is substituted at
deploy time.

A webhook URL is a credential — anyone holding it can post to the channel. Committing one to a
public repository exposes it permanently, including in history after it is replaced. The
correct long-term approach is to store it in Ansible Vault and template the file at deploy
time, which the existing Vault setup already supports.

---

## Quality

### SonarQube served under a context path

SonarQube runs with `SONAR_WEB_CONTEXT: /sonar` so nginx can route to it by path rather than
requiring a separate port or hostname.

The consequence is that its API also moves, and the scanner must be pointed at
`http://sonarqube:9000/sonar`. Omitting the suffix returns the login page HTML, which the
scanner cannot parse — producing an error that names neither the URL nor the context path as
the cause.

### PostgreSQL for SonarQube persistence

SonarQube requires a database for analysis history, mounted on a named volume so that history
survives container recreation.

The embedded database SonarQube ships with is explicitly unsupported for anything beyond
evaluation and cannot be upgraded across versions.

### Default quality gate retained

SonarQube's built-in "Sonar way" gate fails on new blocker or critical issues and on
insufficient coverage of new code.

For a project of this size a custom gate would be arbitrary — thresholds invented to be met
rather than derived from anything. The default encodes reasonable community practice and, more
usefully, focuses on *new* code rather than the existing baseline, which is how quality gates
work in practice on real codebases.

---

## Known deviations

Recorded for completeness rather than hidden:

| Item | Status |
|------|--------|
| Deployment via `docker run` rather than Ansible | Works; conversion to a playbook is a contained change |
| Docker CLI installed into the Jenkins container at runtime | A custom image would survive container recreation |
| Kanban board populated retrospectively | Documents the work rather than having tracked it |
| Slack webhook placeholder in version control | Should be templated from Vault at deploy time |
| Container metrics dashboard not completed | Not a stated requirement; source dashboard is outdated |
| `dynamodb_table` deprecated | Retained deliberately to match the brief |

---

## What would change at scale

**Terraform modules.** The current configuration is flat. Beyond one environment, networking,
compute and IAM would become modules consumed by per-environment root configurations.

**Ansible roles.** Playbooks are linear. With more hosts or host types, roles with defaults,
handlers and templates would replace them.

**Container orchestration.** Docker Compose on a single instance has no failover and no
horizontal scaling. ECS or Kubernetes would be the next step.

**Jenkins agents.** All builds run on the controller. Separate agents would isolate build
workloads from the controller and allow parallelism.

**Certificates and TLS.** Everything is HTTP behind an SSH tunnel. A public deployment would
need a load balancer, a real domain, and certificates from a certificate authority.

**Secrets at runtime.** SSM is in place but only lightly used. A production setup would fetch
all credentials at runtime rather than storing any in Jenkins' own credential store.