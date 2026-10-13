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
TF_PROD  := terraform -chdir=infra/terraform/prod
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
