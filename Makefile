
# Image URL to use all building/pushing image targets
IMG ?= controller:latest
# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.24.2

OPERATOR_IMAGE = ytsaurus/k8s-operator
OPERATOR_TAG = 0.0.0-alpha
OPERATOR_CHART = ytop-chart

ifdef RELEASE_VERSION
DOCKER_BUILD_ARGS += --build-arg VERSION="$(RELEASE_VERSION)"
else
DOCKER_BUILD_ARGS += --build-arg VERSION="$(OPERATOR_TAG)"
endif
DOCKER_BUILD_ARGS += --build-arg REVISION="$(shell git rev-parse HEAD)"
DOCKER_BUILD_ARGS += --build-arg BUILD_DATE="$(shell date --rfc-3339=seconds)"

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

GINKGO_PROCS ?= 1

GINKGO_FLAGS += --vv
GINKGO_FLAGS += --trace
GINKGO_FLAGS += --procs="$(GINKGO_PROCS)"
GINKGO_FLAGS += --timeout=1h
GINKGO_FLAGS += --poll-progress-after=5m
GINKGO_FLAGS += --poll-progress-interval=1m

.PHONY: all
all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd:maxDescLen=80 webhook paths="{\"./api/...\" , \"./controllers/...\", \"./pkg/...\"}" output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="{\"./api/...\" , \"./controllers/...\", \"./pkg/...\"}"
	$(MAKE) docs/api.md

docs/api.md: config/crd-ref-docs/config.yaml $(CRD_REF_DOCS) $(wildcard api/v1/*_types.go)
	$(CRD_REF_DOCS) --config $< --renderer=markdown --source-path=api/v1 --output-path=$@

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: test
test: manifests generate fmt vet envtest ## Run tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" \
	go test -v ./... -coverprofile cover.out -timeout 1800s

.PHONY: test-e2e
test-e2e: manifests generate fmt vet envtest ginkgo ## Run e2e tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" \
	YTSAURUS_ENABLE_E2E_TESTS=true \
	$(GINKGO) $(GINKGO_FLAGS) ./test/e2e/... -coverprofile cover.out -timeout 1800s

.PHONY: lint
lint: golangci-lint ## Run golangci-lint linter.
	$(GOLANGCI_LINT) run

.PHONY: lint-fix
lint-fix: golangci-lint ## Run golangci-lint linter and perform fixes.
	$(GOLANGCI_LINT) run --fix

.PHONY: lint-generated
lint-generated: generate helm ## Check that generated files are uptodate.
	test -z "$(shell git status --porcelain api docs/api.md config ytop-chart)"

.PHONY: canonize
canonize: manifests generate fmt vet envtest ## Canonize tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" \
	CANONIZE=y \
	go test -v ./... -coverprofile cover.out

.PHONY: helm-kind-install
helm-kind-install: ## Install helm chart from sources in kind.
	docker build ${DOCKER_BUILD_ARGS} -t ${OPERATOR_IMAGE}:${OPERATOR_TAG} .
	kind load docker-image ${OPERATOR_IMAGE}:${OPERATOR_TAG}
	helm upgrade -i ytsaurus $(OPERATOR_CHART) --set controllerManager.manager.image.repository=${OPERATOR_IMAGE} --set controllerManager.manager.image.tag=${OPERATOR_TAG}

TEST_IMAGES = \
	ytsaurus/ytsaurus-nightly:dev-23.1-28ccaedbf353b870bedafb6e881ecf386a0a3779 \
	ytsaurus/ytsaurus-nightly:dev-23.1-9779e0140ff73f5a786bd5362313ef9a74fcd0de \
	ytsaurus/ytsaurus-nightly:dev-23.2-9c50056eacfa4fe213798a5b9ee828ae3acb1bca
.PHONY: kind-load-test-images
kind-load-test-images:
	$(foreach img,$(TEST_IMAGES),docker pull $(img) && kind load docker-image $(img);)

.PHONY: k8s-install-cert-manager
k8s-install-cert-manager:
	$(KUBECTL) apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.11.0/cert-manager.yaml

.PHONY: helm-minikube-install
helm-minikube-install: helm ## Install helm chart from sources in minikube.
	eval $$(minikube docker-env) && docker build ${DOCKER_BUILD_ARGS} -t ${OPERATOR_IMAGE}:${OPERATOR_TAG} .
	helm install ytsaurus ytop-chart/

.PHONY: helm-uninstall
helm-uninstall: ## Uninstal kind tests env.
	helm uninstall ytsaurus

##@ Build

.PHONY: build
build: generate fmt vet ## Build manager binary.
	go build -o bin/manager main.go

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./main.go

.PHONY: docker-build
docker-build: test ## Build docker image with the manager.
	docker build ${DOCKER_BUILD_ARGS} -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	docker push ${IMG}

.PHONY: helm
helm: manifests kustomize helmify build ## Generate helm chart.
	$(KUSTOMIZE) build config/default | $(HELMIFY) $(OPERATOR_CHART)

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) create -f -

.PHONY: update
update: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) replace -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | $(KUBECTL) create -f -

.PHONY: undeploy
undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/default | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

release: manifests kustomize helmify ## Release operator docker imager and helm chart.
	docker build ${DOCKER_BUILD_ARGS} -t $(OPERATOR_IMAGE):${RELEASE_VERSION} .
	docker push $(OPERATOR_IMAGE):${RELEASE_VERSION}
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(OPERATOR_IMAGE):${RELEASE_VERSION}
	$(KUSTOMIZE) build config/default | $(HELMIFY) $(OPERATOR_CHART)
	sed -iE "s/appVersion: \".*\"/appVersion: \"${RELEASE_VERSION}\"/" $(OPERATOR_CHART)/Chart.yaml
	sed -iE "s/version:.*/version: ${RELEASE_VERSION}/" $(OPERATOR_CHART)/Chart.yaml
	helm package $(OPERATOR_CHART)
	helm push $(OPERATOR_CHART)-${RELEASE_VERSION}.tgz oci://registry-1.docker.io/ytsaurus

##@ Build Dependencies

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
KUBECTL ?= kubectl
KUSTOMIZE ?= $(LOCALBIN)/kustomize-$(KUSTOMIZE_VERSION)
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen-$(CONTROLLER_GEN_VERSION)
ENVTEST ?= $(LOCALBIN)/setup-envtest-$(ENVTEST_VERSION)
HELMIFY ?= $(LOCALBIN)/helmify-$(HELMIFY_VERSION)
GOLANGCI_LINT ?= $(LOCALBIN)/golangci-lint-$(GOLANGCI_LINT_VERSION)
GINKGO ?= $(LOCALBIN)/ginkgo-$(GINKGO_VERSION)
CRD_REF_DOCS ?= $(LOCALBIN)/crd-ref-docs-$(CRD_REF_DOCS_VERSION)

## Tool Versions
KUSTOMIZE_VERSION ?= v5.3.0
CONTROLLER_GEN_VERSION ?= v0.14.0
ENVTEST_VERSION ?= latest
HELMIFY_VERSION ?= v0.4.5
GOLANGCI_LINT_VERSION ?= v1.56.2
GINKGO_VERSION ?= $(call go-get-version,github.com/onsi/ginkgo/v2)
CRD_REF_DOCS_VERSION ?= v0.0.12

.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary.
$(KUSTOMIZE): $(LOCALBIN)
	$(call go-install-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v5,$(KUSTOMIZE_VERSION))

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary.
$(CONTROLLER_GEN): $(LOCALBIN)
	$(call go-install-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen,$(CONTROLLER_GEN_VERSION))

.PHONY: envtest
envtest: $(ENVTEST) ## Download envtest-setup locally if necessary.
$(ENVTEST): $(LOCALBIN)
	$(call go-install-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest,$(ENVTEST_VERSION))

.PHONY: helmify
helmify: $(HELMIFY) ## Download helmify locally if necessary.
$(HELMIFY): $(LOCALBIN)
	$(call go-install-tool,$(HELMIFY),github.com/arttor/helmify/cmd/helmify,$(HELMIFY_VERSION))

.PHONY: golangci-lint
golangci-lint: $(GOLANGCI_LINT) ## Download golangci-lint locally if necessary.
$(GOLANGCI_LINT): $(LOCALBIN)
	$(call go-install-tool,$(GOLANGCI_LINT),github.com/golangci/golangci-lint/cmd/golangci-lint,${GOLANGCI_LINT_VERSION})

.PHONY: ginkgo
ginkgo: $(GINKGO) ## Download ginkgo locally if necessary.
$(GINKGO): $(LOCALBIN)
	$(call go-install-tool,$(GINKGO),github.com/onsi/ginkgo/v2/ginkgo,$(GINKGO_VERSION))

.PHONY: crd-ref-docs
crd-ref-docs: $(CRD_REF_DOCS) ## Download crd-ref-docs locally if necessary.
$(CRD_REF_DOCS): $(LOCALBIN)
	$(call go-install-tool,$(CRD_REF_DOCS),github.com/elastic/crd-ref-docs,$(CRD_REF_DOCS_VERSION))

# go-install-tool will 'go install' any package with custom target and name of binary, if it doesn't exist
# $1 - target path with name of binary (ideally with version)
# $2 - package url which can be installed
# $3 - specific version of package
define go-install-tool
@[ -f $(1) ] || { \
set -e; \
package=$(2)@$(3) ;\
echo "Downloading $${package}" ;\
GOBIN=$(LOCALBIN) go install $${package} ;\
mv "$$(echo "$(1)" | sed "s/-$(3)$$//")" $(1) ;\
}
endef

# go-get-version will retrieve version of module $1 from go.mod
go-get-version = $(shell go list -m $1 | awk '{print $$2}')
