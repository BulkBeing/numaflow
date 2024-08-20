SHELL:=/bin/bash

PACKAGE=github.com/numaproj/numaflow
CURRENT_DIR=$(shell pwd)

HOST_ARCH=$(shell arch)
# Github actions instances are x86_64
ifeq ($(HOST_ARCH),x86_64)
	HOST_ARCH=amd64
endif
ifeq ($(HOST_ARCH),aarch64)
	HOST_ARCH=arm64
endif

DIST_DIR=${CURRENT_DIR}/dist
BINARY_NAME:=numaflow
DOCKERFILE:=Dockerfile
DEV_BASE_IMAGE:=debian:bookworm
RELEASE_BASE_IMAGE:=scratch

BUILD_DATE=$(shell date -u +'%Y-%m-%dT%H:%M:%SZ')
GIT_COMMIT=$(shell git rev-parse HEAD)
GIT_BRANCH=$(shell git rev-parse --symbolic-full-name --verify --quiet --abbrev-ref HEAD)
GIT_TAG=$(shell if [[ -z "`git status --porcelain`" ]]; then git describe --exact-match --tags HEAD 2>/dev/null; fi)
GIT_TREE_STATE=$(shell if [[ -z "`git status --porcelain`" ]]; then echo "clean" ; else echo "dirty"; fi)

DOCKER_PUSH?=false
DOCKER_BUILD_ARGS?=
IMAGE_NAMESPACE?=quay.io/numaproj
VERSION?=latest
BASE_VERSION:=latest

override LDFLAGS += \
  -X ${PACKAGE}.version=${VERSION} \
  -X ${PACKAGE}.buildDate=${BUILD_DATE} \
  -X ${PACKAGE}.gitCommit=${GIT_COMMIT} \
  -X ${PACKAGE}.gitTreeState=${GIT_TREE_STATE}

ifeq (${DOCKER_PUSH},true)
PUSH_OPTION="--push"
ifndef IMAGE_NAMESPACE
$(error IMAGE_NAMESPACE must be set to push images (e.g. IMAGE_NAMESPACE=quay.io/numaproj))
endif
endif

ifneq (${GIT_TAG},)
VERSION=$(GIT_TAG)
override LDFLAGS += -X ${PACKAGE}.gitTag=${GIT_TAG}
endif

# Check Python
PYTHON:=$(shell command -v python 2> /dev/null)
ifndef PYTHON
PYTHON:=$(shell command -v python3 2> /dev/null)
endif
ifndef PYTHON
$(error "Python is not available, please install.")
endif

CURRENT_CONTEXT:=$(shell [[ "`command -v kubectl`" != '' ]] && kubectl config current-context 2> /dev/null || echo "unset")
IMAGE_IMPORT_CMD:=$(shell [[ "`command -v k3d`" != '' ]] && [[ "$(CURRENT_CONTEXT)" =~ k3d-* ]] && echo "k3d image import -c `echo $(CURRENT_CONTEXT) | cut -c 5-`")
ifndef IMAGE_IMPORT_CMD
IMAGE_IMPORT_CMD:=$(shell [[ "`command -v minikube`" != '' ]] && [[ "$(CURRENT_CONTEXT)" =~ minikube* ]] && echo "minikube image load")
endif
ifndef IMAGE_IMPORT_CMD
IMAGE_IMPORT_CMD:=$(shell [[ "`command -v kind`" != '' ]] && [[ "$(CURRENT_CONTEXT)" =~ kind-* ]] && echo "kind load docker-image")
endif

DOCKER:=$(shell command -v docker 2> /dev/null)
ifndef DOCKER
DOCKER:=$(shell command -v podman 2> /dev/null)
endif

.PHONY: build
build: dist/$(BINARY_NAME)-linux-amd64.gz dist/$(BINARY_NAME)-linux-arm64.gz dist/$(BINARY_NAME)-linux-arm.gz dist/$(BINARY_NAME)-linux-ppc64le.gz dist/$(BINARY_NAME)-linux-s390x.gz dist/e2eapi

dist/$(BINARY_NAME)-%.gz: dist/$(BINARY_NAME)-%
	@[[ -e dist/$(BINARY_NAME)-$*.gz ]] || gzip -k dist/$(BINARY_NAME)-$*

dist/$(BINARY_NAME): GOARGS = GOOS= GOARCH=
dist/$(BINARY_NAME)-linux-amd64: GOARGS = GOOS=linux GOARCH=amd64
dist/$(BINARY_NAME)-linux-arm64: GOARGS = GOOS=linux GOARCH=arm64
dist/$(BINARY_NAME)-linux-arm: GOARGS = GOOS=linux GOARCH=arm
dist/$(BINARY_NAME)-linux-ppc64le: GOARGS = GOOS=linux GOARCH=ppc64le
dist/$(BINARY_NAME)-linux-s390x: GOARGS = GOOS=linux GOARCH=s390x

dist/$(BINARY_NAME):
	@echo -e "\n------MAKE: $@ ------"
	go build -v -ldflags '${LDFLAGS}' -o ${DIST_DIR}/$(BINARY_NAME) ./cmd

dist/e2eapi:
	@echo -e "\n------MAKE: $@ ------"
	CGO_ENABLED=0 GOOS=linux go build -v -ldflags '${LDFLAGS}' -o ${DIST_DIR}/e2eapi ./test/e2e-api

dist/$(BINARY_NAME)-%:
	@echo -e "\n------MAKE: $@ ------"
	CGO_ENABLED=0 $(GOARGS) go build -v -ldflags '${LDFLAGS}' -o ${DIST_DIR}/$(BINARY_NAME)-$* ./cmd

.PHONY: test
test:
	@echo -e "\n------MAKE: $@ ------"
	go test $(shell go list ./... | grep -v /vendor/ | grep -v /numaflow/test/) -race -short -v -timeout 60s

.PHONY: test-coverage
test-coverage:
	@echo -e "\n------MAKE: $@ ------"
	go test -covermode=atomic -coverprofile=test/profile.cov $(shell go list ./... | grep -v /vendor/ | grep -v /numaflow/test/ | grep -v /pkg/client/ | grep -v /pkg/proto/ | grep -v /hack/)
	go tool cover -func=test/profile.cov


.PHONY: test-coverage-with-isb
test-coverage-with-isb:
	@echo -e "\n------MAKE: $@ ------"
	go test -covermode=atomic -coverprofile=test/profile.cov -tags=isb_redis $(shell go list ./... | grep -v /vendor/ | grep -v /numaflow/test/ | grep -v /pkg/client/ | grep -v /pkg/proto/ | grep -v /hack/)
	go tool cover -func=test/profile.cov

.PHONY: test-code
test-code:
	go test -tags=isb_redis -race -v $(shell go list ./... | grep -v /vendor/ | grep -v /numaflow/test/) -timeout 120s

test-e2e:
test-kafka-e2e:
test-map-e2e:
test-reduce-one-e2e:
test-reduce-two-e2e:
test-api-e2e:
test-udsource-e2e:
test-transformer-e2e:
test-diamond-e2e:
test-sideinputs-e2e:
test-monovertex-e2e:
test-idle-source-e2e:
test-builtin-source-e2e:
test-%:
	@echo -e "\n------MAKE: $@ ------"
	$(MAKE) cleanup-e2e
	$(MAKE) image e2eapi-image
	$(MAKE) restart-control-plane-components
	cat test/manifests/e2e-api-pod.yaml | sed 's@quay.io/numaproj/@$(IMAGE_NAMESPACE)/@' | sed 's/:latest/:$(VERSION)/' | kubectl -n numaflow-system apply -f -
	go generate $(shell find ./test/$* -name '*.go')
	go test -v -timeout 15m -count 1 --tags test -p 1 ./test/$* || kubectl get po --all-namespaces && kubectl -n numaflow-system describe pod && kubectl -n numaflow-system logs -l 'app.kubernetes.io/component=mono-vertex' --all-containers
	$(MAKE) cleanup-e2e

image-restart:
	@echo -e "\n------MAKE: $@ ------"
	$(MAKE) image
	$(MAKE) restart-control-plane-components

restart-control-plane-components:
	@echo -e "\n------MAKE: $@ ------"
	kubectl -n numaflow-system delete po -lapp.kubernetes.io/component=controller-manager,app.kubernetes.io/part-of=numaflow --ignore-not-found=true
	kubectl -n numaflow-system delete po -lapp.kubernetes.io/component=numaflow-ux,app.kubernetes.io/part-of=numaflow --ignore-not-found=true
	kubectl -n numaflow-system delete po -lapp.kubernetes.io/component=numaflow-webhook,app.kubernetes.io/part-of=numaflow --ignore-not-found=true

.PHONY: cleanup-e2e
cleanup-e2e:
	@echo -e "\n------MAKE: $@ ------"
	kubectl -n numaflow-system delete svc -lnumaflow-e2e=true --ignore-not-found=true
	kubectl -n numaflow-system delete sts -lnumaflow-e2e=true --ignore-not-found=true
	kubectl -n numaflow-system delete deploy -lnumaflow-e2e=true --ignore-not-found=true
	kubectl -n numaflow-system delete cm -lnumaflow-e2e=true --ignore-not-found=true
	kubectl -n numaflow-system delete secret -lnumaflow-e2e=true --ignore-not-found=true
	kubectl -n numaflow-system delete po -lnumaflow-e2e=true --ignore-not-found=true

# To run just one of the e2e tests by name (i.e. 'make TestCreateSimplePipeline'):
Test%:
	@echo -e "\n------MAKE: $@ ------"
	$(MAKE) cleanup-e2e
	$(MAKE) image e2eapi-image
	kubectl -n numaflow-system delete po -lapp.kubernetes.io/component=controller-manager,app.kubernetes.io/part-of=numaflow
	kubectl -n numaflow-system delete po e2e-api-pod  --ignore-not-found=true
	go generate $(shell find $(shell grep -rl $(*) ./test/*-e2e/*.go))
	cat test/manifests/e2e-api-pod.yaml |  sed 's@quay.io/numaproj/@$(IMAGE_NAMESPACE)/@' | sed 's/:latest/:$(VERSION)/' | kubectl -n numaflow-system apply -f -
	-go test -v -timeout 15m -count 1 --tags test -p 1 ./test/$(shell grep $(*) -R ./test | head -1 | awk -F\/ '{print $$3}' ) -run='.*/$*'
	$(MAKE) cleanup-e2e

.PHONY: ui-build
ui-build:
	@echo -e "\n------MAKE: $@ ------"
	./hack/build-ui.sh

.PHONY: ui-test
ui-test: ui-build
	@echo -e "\n------MAKE: $@ ------"
	./hack/test-ui.sh

.PHONY: image
image: clean ui-build dist/$(BINARY_NAME)-linux-$(HOST_ARCH)
	@echo -e "\n------MAKE: $@ ------"
ifdef GITHUB_ACTIONS
	# The binary will be built in a separate Github Actions job
	cp -pv numaflow-rs-linux-amd64 dist/numaflow-rs-linux-amd64
else
	$(MAKE) build-rust-in-docker
endif
	DOCKER_BUILDKIT=1 $(DOCKER) build --build-arg "BASE_IMAGE=$(DEV_BASE_IMAGE)" $(DOCKER_BUILD_ARGS) -t $(IMAGE_NAMESPACE)/$(BINARY_NAME):$(VERSION) --target $(BINARY_NAME) -f $(DOCKERFILE) .
	@if [[ "$(DOCKER_PUSH)" = "true" ]]; then $(DOCKER) push $(IMAGE_NAMESPACE)/$(BINARY_NAME):$(VERSION); fi
ifdef IMAGE_IMPORT_CMD
	$(IMAGE_IMPORT_CMD) $(IMAGE_NAMESPACE)/$(BINARY_NAME):$(VERSION)
endif

.PHONY: build-rust-in-docker
build-rust-in-docker:
	mkdir -p dist
	-$(DOCKER) container ls --all --filter=ancestor='$(IMAGE_NAMESPACE)/$(BINARY_NAME)-rust-builder:$(VERSION)' --format "{{.ID}}" | xargs docker rm
	-$(DOCKER) image rm $(IMAGE_NAMESPACE)/$(BINARY_NAME)-rust-builder:$(VERSION)
	DOCKER_BUILDKIT=1 $(DOCKER) build --build-arg "BASE_IMAGE=$(DEV_BASE_IMAGE)" $(DOCKER_BUILD_ARGS) -t $(IMAGE_NAMESPACE)/$(BINARY_NAME)-rust-builder:$(VERSION) --target rust-builder -f $(DOCKERFILE) .
	export CTR=$$(docker create $(IMAGE_NAMESPACE)/$(BINARY_NAME)-rust-builder:$(VERSION)) && $(DOCKER) cp $$CTR:/root/numaflow dist/numaflow-rs-linux-$(HOST_ARCH) && $(DOCKER) rm $$CTR && $(DOCKER) image rm $(IMAGE_NAMESPACE)/$(BINARY_NAME)-rust-builder:$(VERSION)

image-multi: ui-build set-qemu dist/$(BINARY_NAME)-linux-arm64.gz dist/$(BINARY_NAME)-linux-amd64.gz
	@echo -e "\n------MAKE: $@ ------"
	$(DOCKER) buildx build --sbom=false --provenance=false --build-arg "BASE_IMAGE=$(RELEASE_BASE_IMAGE)" $(DOCKER_BUILD_ARGS) -t $(IMAGE_NAMESPACE)/$(BINARY_NAME):$(VERSION) --target $(BINARY_NAME) --platform linux/amd64,linux/arm64 --file $(DOCKERFILE) ${PUSH_OPTION} .

set-qemu:
	@echo -e "\n------MAKE: $@ ------"
	$(DOCKER) pull tonistiigi/binfmt:latest
	$(DOCKER) run --rm --privileged tonistiigi/binfmt:latest --install amd64,arm64


.PHONY: swagger
swagger:
	@echo -e "\n------MAKE: $@ ------"
	./hack/swagger-gen.sh ${VERSION}
	$(MAKE) api/json-schema/schema.json

api/json-schema/schema.json: api/openapi-spec/swagger.json hack/json-schema/main.go
	@echo -e "\n------MAKE: $@ ------"
	go run ./hack/json-schema

.PHONY: codegen
codegen:
	@echo -e "\n------MAKE: $@ ------"
	./hack/generate-proto.sh
	./hack/update-codegen.sh
	./hack/openapi-gen.sh
	$(MAKE) swagger
	./hack/update-api-docs.sh
	$(MAKE) manifests
	rm -rf ./vendor
	go mod tidy
	$(MAKE) --directory rust/numaflow-models generate

clean:
	@echo -e "\n------MAKE: $@ ------"
	-rm -rf ${CURRENT_DIR}/dist

.PHONY: crds
crds:
	@echo -e "\n------MAKE: $@ ------"
	./hack/crdgen.sh

.PHONY: manifests
manifests: crds
	@echo -e "\n------MAKE: $@ ------"
	kubectl kustomize config/cluster-install > config/install.yaml
	kubectl kustomize config/namespace-install > config/namespace-install.yaml
	kubectl kustomize config/advanced-install/namespaced-controller > config/advanced-install/namespaced-controller-wo-crds.yaml
	kubectl kustomize config/advanced-install/namespaced-numaflow-server > config/advanced-install/namespaced-numaflow-server.yaml
	kubectl kustomize config/advanced-install/numaflow-server > config/advanced-install/numaflow-server.yaml
	kubectl kustomize config/advanced-install/minimal-crds > config/advanced-install/minimal-crds.yaml
	kubectl kustomize config/advanced-install/numaflow-dex-server > config/advanced-install/numaflow-dex-server.yaml
	kubectl kustomize config/extensions/webhook > config/validating-webhook-install.yaml

$(GOPATH)/bin/golangci-lint:
	@echo -e "\n------MAKE: $@ ------"
	curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b `go env GOPATH`/bin v1.54.1

.PHONY: lint
lint: $(GOPATH)/bin/golangci-lint
	@echo -e "\n------MAKE: $@ ------"
	go mod tidy
	golangci-lint run --fix --verbose --concurrency 4 --timeout 5m --enable goimports

.PHONY: start
start: image
	@echo -e "\n------MAKE: $@ ------"
	kubectl apply -f test/manifests/numaflow-ns.yaml
	kubectl -n numaflow-system delete cm numaflow-cmd-params-config --ignore-not-found=true
	kubectl kustomize test/manifests | sed 's@quay.io/numaproj/@$(IMAGE_NAMESPACE)/@' | sed 's/:$(BASE_VERSION)/:$(VERSION)/' | kubectl -n numaflow-system apply -l app.kubernetes.io/part-of=numaflow --prune=false --force -f -
	kubectl -n numaflow-system wait -lapp.kubernetes.io/part-of=numaflow --for=condition=Ready --timeout 60s pod --all

.PHONY: e2eapi-image
e2eapi-image: clean dist/e2eapi
	@echo -e "\n------MAKE: $@ ------"
	DOCKER_BUILDKIT=1 $(DOCKER) build . --target e2eapi --tag $(IMAGE_NAMESPACE)/e2eapi:$(VERSION) --build-arg VERSION="$(VERSION)"
	@if [[ "$(DOCKER_PUSH)" = "true" ]]; then $(DOCKER) push $(IMAGE_NAMESPACE)/e2eapi:$(VERSION); fi
ifdef IMAGE_IMPORT_CMD
	$(IMAGE_IMPORT_CMD) $(IMAGE_NAMESPACE)/e2eapi:$(VERSION)
endif

/usr/local/bin/mkdocs:
	@echo -e "\n------MAKE: $@ ------"
	$(PYTHON) -m pip install mkdocs==1.3.0 mkdocs_material==8.3.9 mkdocs-embed-external-markdown==2.3.0

/usr/local/bin/lychee:
ifeq (, $(shell which lychee))
ifeq ($(shell uname),Darwin)
	brew install lychee
else
	curl -sSfL https://github.com/lycheeverse/lychee/releases/download/v0.13.0/lychee-v0.13.0-$(shell uname -m)-unknown-linux-gnu.tar.gz | sudo tar xz -C /usr/local/bin/
endif
endif

# docs

.PHONY: docs
docs: /usr/local/bin/mkdocs docs-linkcheck
	@echo -e "\n------MAKE: $@ ------"
	mkdocs build

.PHONY: docs-serve
docs-serve: docs
	@echo -e "\n------MAKE: $@ ------"
	mkdocs serve

.PHONY: docs-linkcheck
docs-linkcheck: /usr/local/bin/lychee
	@echo -e "\n------MAKE: $@ ------"
	lychee --exclude-path=CHANGELOG.md --exclude-mail *.md --include "https://github.com/numaproj/*" $(shell find ./test -type f) $(wildcard ./docs/*.md)

# pre-push checks

.git/hooks/%: hack/git/hooks/%
	@echo -e "\n------MAKE: $@ ------"
	@mkdir -p .git/hooks
	cp hack/git/hooks/$* .git/hooks/$*

.PHONY: githooks
githooks: .git/hooks/commit-msg
	@echo -e "\n------MAKE: $@ ------"

.PHONY: pre-push
pre-push: codegen lint
	@echo -e "\n------MAKE: $@ ------"
	# marker file, based on it's modification time, we know how long ago this target was run
	touch dist/pre-push

.PHONY: checksums
checksums:
	@echo -e "\n------MAKE: $@ ------"
	sha256sum ./dist/$(BINARY_NAME)-*.gz | awk -F './dist/' '{print $$1 $$2}' > ./dist/$(BINARY_NAME)-checksums.txt

# release - targets only available on release branch
ifneq ($(findstring release,$(GIT_BRANCH)),)

.PHONY: prepare-release
prepare-release: check-version-warning clean update-manifests-version codegen
	@echo -e "\n------MAKE: $@ ------"
	git status
	@git diff --quiet || echo "\n\nPlease run 'git diff' to confirm the file changes are correct.\n"

.PHONY: release
release: check-version-warning
	@echo -e "\n------MAKE: $@ ------"
	@echo
	@echo "1. Make sure you have run 'VERSION=$(VERSION) make prepare-release', and confirmed all the changes are expected."
	@echo
	@echo "2. Run following commands to commit the changes to the release branch, add give a tag."
	@echo
	@echo "git commit -am \"Update manifests to $(VERSION)\""
	@echo "git push {your-remote}"
	@echo
	@echo "git tag -a $(VERSION) -m $(VERSION)"
	@echo "git push {your-remote} $(VERSION)"
	@echo

endif

.PHONY: check-version-warning
check-version-warning:
	@echo -e "\n------MAKE: $@ ------"
	@if [[ ! "$(VERSION)" =~ ^v[0-9]+\.[0-9]+\.[0-9]+.*$  ]]; then echo -n "It looks like you're not using a version format like 'v1.2.3', or 'v1.2.3-rc2', that version format is required for our releases. Do you wish to continue anyway? [y/N]" && read ans && [[ $${ans:-N} = y ]]; fi

.PHONY: update-manifests-version
update-manifests-version:
	@echo -e "\n------MAKE: $@ ------"
	cat config/base/kustomization.yaml | sed 's/newTag: .*/newTag: $(VERSION)/' | sed 's@value: quay.io/numaproj/numaflow:.*@value: quay.io/numaproj/numaflow:$(VERSION)@' > /tmp/tmp_kustomization.yaml
	mv /tmp/tmp_kustomization.yaml config/base/kustomization.yaml
	cat config/advanced-install/namespaced-controller/kustomization.yaml | sed 's/newTag: .*/newTag: $(VERSION)/' | sed 's@value: quay.io/numaproj/numaflow:.*@value: quay.io/numaproj/numaflow:$(VERSION)@' > /tmp/tmp_kustomization.yaml
	mv /tmp/tmp_kustomization.yaml config/advanced-install/namespaced-controller/kustomization.yaml
	cat config/advanced-install/namespaced-numaflow-server/kustomization.yaml | sed 's/newTag: .*/newTag: $(VERSION)/' | sed 's@value: quay.io/numaproj/numaflow:.*@value: quay.io/numaproj/numaflow:$(VERSION)@' > /tmp/tmp_kustomization.yaml
	mv /tmp/tmp_kustomization.yaml config/advanced-install/namespaced-numaflow-server/kustomization.yaml
	cat config/advanced-install/numaflow-server/kustomization.yaml | sed 's/newTag: .*/newTag: $(VERSION)/' | sed 's@value: quay.io/numaproj/numaflow:.*@value: quay.io/numaproj/numaflow:$(VERSION)@' > /tmp/tmp_kustomization.yaml
	mv /tmp/tmp_kustomization.yaml config/advanced-install/numaflow-server/kustomization.yaml
	cat config/extensions/webhook/kustomization.yaml | sed 's/newTag: .*/newTag: $(VERSION)/' | sed 's@value: quay.io/numaproj/numaflow:.*@value: quay.io/numaproj/numaflow:$(VERSION)@' > /tmp/tmp_kustomization.yaml
	mv /tmp/tmp_kustomization.yaml config/extensions/webhook/kustomization.yaml
	cat Makefile | sed 's/^VERSION?=.*/VERSION?=$(VERSION)/' | sed 's/^BASE_VERSION:=.*/BASE_VERSION:=$(VERSION)/' > /tmp/ae_makefile
	mv /tmp/ae_makefile Makefile
