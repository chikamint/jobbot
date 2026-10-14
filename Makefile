CLUSTER   := jobbot
NAMESPACE := jobbot
IMAGE     := jobbot:local
OVERLAY   := deploy/k8s/overlays/local

.PHONY: help tools cluster cluster-delete test image secrets deploy logs status psql

help:             ## list targets
	@grep -E '^[a-z-]+:.*##' Makefile | sed 's/:.*##/\t/'

tools:            ## install kubectl, kind, helm, terraform
	bash scripts/install-tools.sh

cluster:          ## create local kind cluster (1 control-plane + 2 workers)
	kind create cluster --config deploy/kind-cluster.yaml
	kubectl get nodes -o wide

cluster-delete:   ## delete local cluster
	kind delete cluster --name $(CLUSTER)

test:             ## run unit tests in a throwaway container
	docker run --rm -v "$(CURDIR)/app":/src -w /src python:3.12-slim \
		sh -c "pip install -q -r requirements.txt pytest==8.3.4 && python -m pytest -q -p no:cacheprovider"

image:            ## build image and load it into kind nodes
	docker build -t $(IMAGE) app/
	kind load docker-image $(IMAGE) --name $(CLUSTER)

secrets:          ## create Postgres password once (random, never in git)
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n $(NAMESPACE) get secret postgres >/dev/null 2>&1 || \
		kubectl -n $(NAMESPACE) create secret generic postgres --from-literal=password=$$(openssl rand -hex 16)

deploy: image secrets  ## build + deploy to local cluster
	kubectl apply -k $(OVERLAY)
	kubectl -n $(NAMESPACE) rollout status statefulset/postgres
	kubectl -n $(NAMESPACE) rollout restart deploy/jobbot   # same tag "local" -> force new pod
	kubectl -n $(NAMESPACE) rollout status deploy/jobbot

logs:             ## follow jobbot logs
	kubectl -n $(NAMESPACE) logs deploy/jobbot -f

status:           ## show everything in the namespace
	kubectl -n $(NAMESPACE) get all,pvc -o wide

psql:             ## open psql in the database
	kubectl -n $(NAMESPACE) exec -it postgres-0 -- psql -U postgres

# --- AWS infrastructure (Terraform) ---
# absolute path: targets may `cd` elsewhere before calling Terraform
TF_PROD  := terraform -chdir=$(CURDIR)/infra/terraform/prod
# your current public IP: only it may reach SSH and the Kubernetes API
MY_CIDR   = $$(curl -s https://checkip.amazonaws.com)/32

.PHONY: infra-bootstrap infra-plan infra-apply infra-destroy

infra-bootstrap:  ## one-time: create S3 bucket for Terraform state
	terraform -chdir=infra/terraform/bootstrap init
	terraform -chdir=infra/terraform/bootstrap apply

infra-plan:       ## show what Terraform would change in AWS
	$(TF_PROD) init -input=false
	TF_VAR_admin_cidr=$(MY_CIDR) $(TF_PROD) plan

infra-apply:      ## create/update AWS infrastructure (asks for confirmation)
	TF_VAR_admin_cidr=$(MY_CIDR) $(TF_PROD) apply

infra-destroy:    ## delete everything in prod (asks for confirmation)
	TF_VAR_admin_cidr=$(MY_CIDR) $(TF_PROD) destroy

# --- Production node (Ansible + k3s) ---
PROD_IP          = $$($(TF_PROD) output -raw public_ip)
PROD_KUBECONFIG := $(HOME)/.kube/jobbot-prod.yaml

.PHONY: provision prod-deploy prod-status prod-logs

provision:        ## configure the node: OS baseline + k3s, fetch kubeconfig
	cd infra/ansible && ansible-playbook -i "$(PROD_IP)," site.yml

prod-deploy:      ## manual apply (bootstrap / fallback; normally Flux deploys from git, see prod-sync)
	KUBECONFIG=$(PROD_KUBECONFIG) $(MAKE) secrets
	KUBECONFIG=$(PROD_KUBECONFIG) kubectl apply -k deploy/k8s/overlays/prod
	KUBECONFIG=$(PROD_KUBECONFIG) kubectl -n $(NAMESPACE) rollout status statefulset/postgres
	KUBECONFIG=$(PROD_KUBECONFIG) kubectl -n $(NAMESPACE) rollout status deploy/jobbot

prod-status:      ## pods and nodes in production
	KUBECONFIG=$(PROD_KUBECONFIG) kubectl get nodes -o wide
	KUBECONFIG=$(PROD_KUBECONFIG) kubectl -n $(NAMESPACE) get all,pvc

prod-logs:        ## follow jobbot logs in production
	KUBECONFIG=$(PROD_KUBECONFIG) kubectl -n $(NAMESPACE) logs deploy/jobbot -f

# --- GitOps (Flux): production follows the main branch ---
.PHONY: prod-flux prod-sync prod-flux-status

prod-flux:        ## install/upgrade Flux (2 controllers) and the jobbot sync config
	KUBECONFIG=$(PROD_KUBECONFIG) kubectl apply --server-side --force-conflicts -k deploy/flux

prod-sync:        ## don't wait for the 1-minute poll: fetch git and apply now
	export KUBECONFIG=$(PROD_KUBECONFIG); t=$$(date +%s); \
	kubectl -n flux-system annotate --overwrite gitrepository/jobbot reconcile.fluxcd.io/requestedAt=$$t && \
	kubectl -n flux-system annotate --overwrite kustomization/jobbot-prod reconcile.fluxcd.io/requestedAt=$$t && \
	kubectl -n flux-system wait kustomization/jobbot-prod --for=condition=Ready --timeout=5m

prod-flux-status: ## what revision is deployed, is it healthy
	KUBECONFIG=$(PROD_KUBECONFIG) kubectl -n flux-system get gitrepository,kustomization

# --- Database backup / restore (production) ---
.PHONY: prod-db-backup prod-db-restore

prod-db-backup:   ## dump production PostgreSQL to backups/ (custom format, compressed)
	mkdir -p backups
	f=backups/jobbot-$$(date +%Y%m%d-%H%M%S).dump; \
	KUBECONFIG=$(PROD_KUBECONFIG) kubectl -n $(NAMESPACE) exec postgres-0 -- pg_dump -U postgres -Fc postgres > $$f && \
	ls -lh $$f && \
	docker run --rm -i postgres:17-alpine pg_restore --list < $$f | grep -E "TABLE (DATA )?public jobs"   # dump is readable

prod-db-restore:  ## restore a dump: make prod-db-restore FILE=backups/jobbot-....dump
	@test -f "$(FILE)" || { echo "usage: make prod-db-restore FILE=backups/<file>.dump"; exit 1; }
	KUBECONFIG=$(PROD_KUBECONFIG) kubectl -n $(NAMESPACE) exec -i postgres-0 -- \
		pg_restore -U postgres -d postgres --clean --if-exists --no-owner < $(FILE)
	KUBECONFIG=$(PROD_KUBECONFIG) kubectl -n $(NAMESPACE) exec postgres-0 -- \
		psql -U postgres -tAc "select count(*) as jobs, count(posted_at) as posted from jobs"

# --- Automated backups in S3 (CronJob postgres-backup, bucket from Terraform) ---
BACKUP_BUCKET = $$($(TF_PROD) output -raw backup_bucket)

.PHONY: prod-backup-now prod-backups prod-db-restore-s3

prod-backup-now:  ## run the backup CronJob right now and show its logs
	j=backup-manual-$$(date +%s); export KUBECONFIG=$(PROD_KUBECONFIG); \
	kubectl -n $(NAMESPACE) create job --from=cronjob/postgres-backup $$j && \
	kubectl -n $(NAMESPACE) wait --for=condition=complete job/$$j --timeout=300s; \
	kubectl -n $(NAMESPACE) logs job/$$j --all-containers --prefix

prod-backups:     ## list dumps in S3
	aws s3 ls s3://$(BACKUP_BUCKET)/postgres/ --region eu-north-1

prod-db-restore-s3: ## restore from S3: make prod-db-restore-s3 [KEY=jobbot-....dump] (default: latest)
	mkdir -p backups
	k="$(KEY)"; b=$(BACKUP_BUCKET); \
	[ -n "$$k" ] || k=$$(aws s3 ls s3://$$b/postgres/ --region eu-north-1 | sort | tail -1 | awk '{print $$4}'); \
	echo "restoring $$k"; aws s3 cp s3://$$b/postgres/$$k backups/$$k --region eu-north-1 --only-show-errors && \
	$(MAKE) prod-db-restore FILE=backups/$$k

# --- Monitoring (kube-prometheus-stack) ---
KPS_VERSION := 92.4.0
PROD_KUBECTL = KUBECONFIG=$(PROD_KUBECONFIG) kubectl -n monitoring

.PHONY: prod-monitoring-secrets prod-monitoring prod-prometheus prod-alertmanager test-alerts

prod-monitoring-secrets:  ## once: Telegram bot token + your chat id for alerts (asked interactively)
	$(PROD_KUBECTL) create namespace monitoring --dry-run=client -o yaml | KUBECONFIG=$(PROD_KUBECONFIG) kubectl apply -f -
	@$(PROD_KUBECTL) get secret alertmanager-telegram >/dev/null 2>&1 || { \
		read -rsp "Telegram bot token for alerts: " t; echo; read -rp "Your Telegram chat id (number): " c; \
		echo "$$t" | grep -qE '^[0-9]+:[A-Za-z0-9_-]{30,}$$' || { echo "token format is wrong (expected 123456:ABC...)"; exit 1; }; \
		echo "$$c" | grep -qE '^-?[0-9]+$$' || { echo "chat id must be a number"; exit 1; }; \
		$(PROD_KUBECTL) create secret generic alertmanager-telegram --from-literal=token="$$t" --from-literal=chat_id="$$c"; }

prod-monitoring:  ## install/upgrade Prometheus + Alertmanager in production
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
	KUBECONFIG=$(PROD_KUBECONFIG) helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
		--version $(KPS_VERSION) -n monitoring -f deploy/monitoring/values.yaml \
		--set-file 'alertmanager.templateFiles.telegram\.tmpl=deploy/monitoring/telegram.tmpl' --wait --timeout 10m

prod-prometheus:  ## open Prometheus UI on http://localhost:9090 (targets, alerts, graphs)
	$(PROD_KUBECTL) port-forward svc/monitoring-kube-prometheus-prometheus 9090

prod-alertmanager: ## open Alertmanager UI on http://localhost:9093 (active alerts, silences)
	$(PROD_KUBECTL) port-forward svc/monitoring-kube-prometheus-alertmanager 9093

test-alerts:      ## unit-test alert rules (promtool) and render the Telegram template (amtool)
	python3 -c "import yaml,sys; yaml.safe_dump(yaml.safe_load(open('deploy/k8s/components/monitoring/prometheusrule.yaml'))['spec'], open('deploy/k8s/components/monitoring/tests/rules.yml','w'))"
	docker run --rm -v "$(CURDIR)/deploy/k8s/components/monitoring/tests":/t -w /t --entrypoint promtool \
		quay.io/prometheus/prometheus:v3.15.0 test rules rules_test.yml
	docker run --rm -v "$(CURDIR)/deploy/monitoring":/t -w /t --entrypoint amtool quay.io/prometheus/alertmanager:v0.34.1 \
		template render --template.glob=telegram.tmpl --template.data=tests/telegram-data.json \
		--template.text='{{ template "telegram.jobbot" . }}'
