include ./Makefile.Common

### VARIABLES


# BUILD_TYPE should be one of (dev, release).
BUILD_TYPE?=release
VERSION?=latest

GIT_SHA=$(shell git rev-parse --short HEAD)
GO_ACC=go-acc
GOARCH=$(shell go env GOARCH)
GOOS=$(shell go env GOOS)

FIND_MOD_ARGS=-type f -name "go.mod"
TO_MOD_DIR=dirname {} \; | sort | egrep  '^./'
# NONROOT_MODS includes ./* dirs (excludes . dir)
NONROOT_MODS := $(shell find . $(FIND_MOD_ARGS) -exec $(TO_MOD_DIR) )

# CircleCI runtime.NumCPU() is for host machine despite container instance only granting 2.
# If we are in a CI job, limit to 2 (and scale as we increase executor size).
NUM_CORES := $(shell if [ -z ${CIRCLE_JOB} ]; then echo `getconf _NPROCESSORS_ONLN` ; else echo 2; fi )
GOTEST=go test -p $(NUM_CORES)

# Currently integration tests are flakey when run in parallel due to internal metric and config server conflicts
GOTEST_SERIAL=go test -p 1

BUILD_INFO_IMPORT_PATH=github.com/signalfx/splunk-otel-collector/internal/version
BUILD_INFO_IMPORT_PATH_TESTS=github.com/signalfx/splunk-otel-collector/tests/internal/version
BUILD_INFO_IMPORT_PATH_CORE=go.opentelemetry.io/collector/internal/version
VERSION=$(shell git describe --match "v[0-9]*" HEAD)
BUILD_X1=-X $(BUILD_INFO_IMPORT_PATH).Version=$(VERSION)
BUILD_X2=-X $(BUILD_INFO_IMPORT_PATH_CORE).Version=$(VERSION)
BUILD_INFO=-ldflags "${BUILD_X1} ${BUILD_X2}"
BUILD_INFO_TESTS=-ldflags "-X $(BUILD_INFO_IMPORT_PATH_TESTS).Version=$(VERSION)"

SMART_AGENT_RELEASE=$(shell cat internal/buildscripts/packaging/smart-agent-release.txt)
SKIP_COMPILE=false
ARCH=amd64

# For integration testing against local changes you can run
# SPLUNK_OTEL_COLLECTOR_IMAGE='otelcol:latest' make -e docker-otelcol integration-test
# for local docker build testing or
# SPLUNK_OTEL_COLLECTOR_IMAGE='' make -e otelcol integration-test
# for local binary testing (agent-bundle configuration required)
export SPLUNK_OTEL_COLLECTOR_IMAGE?=quay.io/signalfx/splunk-otel-collector-dev:latest

# ALL_MODULES includes ./* dirs (excludes . dir)
ALL_GO_MODULES := $(shell find . -type f -name "go.mod" -exec dirname {} \; | sort | egrep  '^./' )
ALL_PYTHON_DEPS := $(shell find . -type f \( -name "setup.py" -o -name "requirements.txt" \) -exec dirname {} \; | sort | egrep  '^./')
ALL_DOCKERFILES := $(shell find . -type f -name Dockerfile -exec dirname {} \; | grep -v '^./tests' | sort)
DEPENDABOT_PATH=./.github/dependabot.yml

### TARGETS

.DEFAULT_GOAL := all

.PHONY: all
all: checklicense impi lint misspell test otelcol

.PHONY: for-all
for-all:
	@echo "running $${CMD} in root"
	@$${CMD}
	@set -e; for dir in $(NONROOT_MODS); do \
	  (cd "$${dir}" && \
	  	echo "running $${CMD} in $${dir}" && \
	 	$${CMD} ); \
	done

.PHONY: integration-vet
integration-vet:
	cd tests && go vet ./...

.PHONY: integration-test
integration-test:
	@set -e; for dir in $(shell find tests -name '*_test.go' | xargs -L 1 dirname | uniq | sort -r); do \
	  echo "go test ./... in $${dir}"; \
	  (cd "$${dir}" && \
	   $(GOTEST_SERIAL) $(BUILD_INFO_TESTS) --tags=integration -v -timeout 5m -count 1 ./... ); \
	done

.PHONY: end-to-end-test
end-to-end-test:
	@set -e; cd tests/endtoend && $(GOTEST) -v -tags endtoend -timeout 5m -count 1 ./...

.PHONY: test-with-cover
test-with-cover:
	@echo Verifying that all packages have test files to count in coverage
	@echo pre-compiling tests
	@time go test -p $(NUM_CORES) -i $(ALL_PKG_DIRS)
	$(GO_ACC) $(ALL_PKG_DIRS)
	go tool cover -html=coverage.txt -o coverage.html

.PHONY: gendependabot
gendependabot:
	@echo "Recreate dependabot.yml file"
	@echo "# File generated by \"make gendependabot\"; DO NOT EDIT.\n" > ${DEPENDABOT_PATH}
	@echo "version: 2" >> ${DEPENDABOT_PATH}
	@echo "updates:" >> ${DEPENDABOT_PATH}
	@echo "Add entry for \"/\""
	@echo "  - package-ecosystem: \"gomod\"\n    directory: \"/\"\n    schedule:\n      interval: \"daily\"" >> ${DEPENDABOT_PATH}
	@set -e; for dir in $(ALL_GO_MODULES); do \
		(echo "Add entry for \"$${dir:1}\"" && \
		  echo "  - package-ecosystem: \"gomod\"\n    directory: \"$${dir:1}\"\n    schedule:\n      interval: \"daily\"" >> ${DEPENDABOT_PATH} ); \
	done
	@set -e; for dir in $(ALL_PYTHON_DEPS); do \
		(echo "Add entry for \"$${dir:1}\"" && \
		  echo "  - package-ecosystem: \"pip\"\n    directory: \"$${dir:1}\"\n    schedule:\n      interval: \"daily\"" >> ${DEPENDABOT_PATH} ); \
	done
	@set -e; for dir in $(ALL_DOCKERFILES); do \
		(echo "Add entry for \"$${dir:1}\"" && \
		  echo "  - package-ecosystem: \"docker\"\n    directory: \"$${dir:1}\"\n    schedule:\n      interval: \"daily\"" >> ${DEPENDABOT_PATH} ); \
	done

.PHONY: tidy-all
tidy-all:
	$(MAKE) $(FOR_GROUP_TARGET) TARGET="tidy"
	go mod tidy -compat=1.18

.PHONY: install-tools
install-tools:
	cd ./internal/tools && go install github.com/client9/misspell/cmd/misspell
	cd ./internal/tools && go install github.com/golangci/golangci-lint/cmd/golangci-lint
	cd ./internal/tools && go install github.com/google/addlicense
	cd ./internal/tools && go install github.com/jstemmer/go-junit-report
	cd ./internal/tools && go install github.com/ory/go-acc
	cd ./internal/tools && go install github.com/pavius/impi/cmd/impi
	cd ./internal/tools && go install github.com/tcnksm/ghr
	cd ./internal/tools && go install golang.org/x/tools/go/analysis/passes/fieldalignment/cmd/fieldalignment

.PHONY: otelcol
otelcol:
	go generate ./...
	GO111MODULE=on CGO_ENABLED=0 go build -o ./bin/otelcol_$(GOOS)_$(GOARCH)$(EXTENSION) $(BUILD_INFO) ./cmd/otelcol
	ln -sf otelcol_$(GOOS)_$(GOARCH)$(EXTENSION) ./bin/otelcol

.PHONY: translatesfx
translatesfx:
	go generate ./...
	GO111MODULE=on CGO_ENABLED=0 go build -o ./bin/translatesfx_$(GOOS)_$(GOARCH)$(EXTENSION) $(BUILD_INFO) ./cmd/translatesfx
	ln -sf translatesfx_$(GOOS)_$(GOARCH)$(EXTENSION) ./bin/translatesfx

.PHONY: migratecheckpoint
migratecheckpoint:
	go generate ./...
	GO111MODULE=on CGO_ENABLED=0 go build -o ./bin/migratecheckpoint_$(GOOS)_$(GOARCH)$(EXTENSION) $(BUILD_INFO) ./cmd/migratecheckpoint
	ln -sf migratecheckpoint_$(GOOS)_$(GOARCH)$(EXTENSION) ./bin/migratecheckpoint

.PHONY: add-tag
add-tag:
	@[ "${TAG}" ] || ( echo ">> env var TAG is not set"; exit 1 )
	@echo "Adding tag ${TAG}"
	@git tag -a ${TAG} -s -m "Version ${TAG}"

.PHONY: delete-tag
delete-tag:
	@[ "${TAG}" ] || ( echo ">> env var TAG is not set"; exit 1 )
	@echo "Deleting tag ${TAG}"
	@git tag -d ${TAG}

.PHONY: docker-otelcol
docker-otelcol:
ifneq ($(SKIP_COMPILE), true)
	$(MAKE) binaries-linux_$(ARCH)
endif
	cp ./bin/otelcol_linux_$(ARCH) ./cmd/otelcol/otelcol
	cp ./bin/translatesfx_linux_$(ARCH) ./cmd/otelcol/translatesfx
	cp ./bin/migratecheckpoint_linux_$(ARCH) ./cmd/otelcol/migratecheckpoint
	cp ./internal/buildscripts/packaging/collect-libs.sh ./cmd/otelcol/collect-libs.sh
	docker buildx build --platform linux/$(ARCH) -o type=image,name=otelcol:$(ARCH),push=false --build-arg ARCH=$(ARCH) --build-arg SMART_AGENT_RELEASE=$(SMART_AGENT_RELEASE) ./cmd/otelcol/
	docker tag otelcol:$(ARCH) otelcol:latest
	rm ./cmd/otelcol/otelcol
	rm ./cmd/otelcol/translatesfx
	rm ./cmd/otelcol/migratecheckpoint
	rm ./cmd/otelcol/collect-libs.sh

.PHONY: binaries-all-sys
binaries-all-sys: binaries-darwin_amd64 binaries-linux_amd64 binaries-linux_arm64 binaries-windows_amd64

.PHONY: binaries-darwin_amd64
binaries-darwin_amd64:
	GOOS=darwin  GOARCH=amd64 $(MAKE) otelcol
	GOOS=darwin  GOARCH=amd64 $(MAKE) translatesfx
	GOOS=darwin  GOARCH=amd64 $(MAKE) migratecheckpoint

.PHONY: binaries-linux_amd64
binaries-linux_amd64:
	GOOS=linux   GOARCH=amd64 $(MAKE) otelcol
	GOOS=linux   GOARCH=amd64 $(MAKE) translatesfx
	GOOS=linux   GOARCH=amd64 $(MAKE) migratecheckpoint

.PHONY: binaries-linux_arm64
binaries-linux_arm64:
	GOOS=linux   GOARCH=arm64 $(MAKE) otelcol
	GOOS=linux   GOARCH=arm64 $(MAKE) translatesfx
	GOOS=linux   GOARCH=arm64 $(MAKE) migratecheckpoint

.PHONY: binaries-windows_amd64
binaries-windows_amd64:
	GOOS=windows GOARCH=amd64 EXTENSION=.exe $(MAKE) otelcol
	GOOS=windows GOARCH=amd64 EXTENSION=.exe $(MAKE) translatesfx
	GOOS=windows GOARCH=amd64 EXTENSION=.exe $(MAKE) migratecheckpoint

.PHONY: deb-rpm-tar-package
%-package:
ifneq ($(SKIP_COMPILE), true)
	$(MAKE) binaries-linux_$(ARCH)
endif
	docker build -t otelcol-fpm internal/buildscripts/packaging/fpm
	docker run --rm -v $(CURDIR):/repo -e PACKAGE=$* -e VERSION=$(VERSION) -e ARCH=$(ARCH) -e SMART_AGENT_RELEASE=$(SMART_AGENT_RELEASE) otelcol-fpm

.PHONY: msi
msi:
ifneq ($(SKIP_COMPILE), true)
	$(MAKE) binaries-windows_amd64
endif
	./internal/buildscripts/packaging/msi/build.sh "$(VERSION)" "$(SMART_AGENT_RELEASE)"

.PHONY: update-examples
update-examples:
	cd examples && $(MAKE) update-examples
