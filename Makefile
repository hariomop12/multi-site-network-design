# Multi-site corporate network lab.
#
# containerlab needs root for netns/veth plumbing, so every containerlab target
# goes through $(SUDO). Run as root with:  make deploy SUDO=
SUDO ?= sudo
CLAB ?= containerlab
CLAB_VERSION ?= 0.81.1
LAB ?= corpnet
TOPO ?= topology.clab.yml

# Prefer the project virtualenv when it exists, so `make test` just works after
# the quickstart's `python3 -m venv .venv` step.
PYTHON ?= $(shell if [ -x .venv/bin/python ]; then echo .venv/bin/python; else echo python3; fi)
PYTEST ?= $(PYTHON) -m pytest

.DEFAULT_GOAL := help

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //' | awk -F': ' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

## install-clab: install containerlab if it is missing (version-pinned)
install-clab:
	@command -v $(CLAB) >/dev/null 2>&1 && { echo "$(CLAB) already installed: $$($(CLAB) version | head -1)"; exit 0; } || true
	@case "$$(uname -m)" in \
		x86_64|amd64) arch=amd64 ;; \
		aarch64|arm64) arch=arm64 ;; \
		*) echo "unsupported architecture: $$(uname -m)" >&2; exit 1 ;; \
	esac; \
	url="https://github.com/srl-labs/containerlab/releases/download/v$(CLAB_VERSION)/containerlab_$(CLAB_VERSION)_linux_$${arch}.tar.gz"; \
	echo "downloading $$url"; \
	curl -fsSL "$$url" | tar xz -C /tmp containerlab; \
	$(SUDO) install -m 0755 /tmp/containerlab /usr/local/bin/containerlab; \
	$(CLAB) version | head -1

## images: build the two node images (labnode, frrnode)
images:
	docker build -t labnode:latest -f images/labnode/Dockerfile images/labnode
	docker build -t frrnode:latest -f images/frrnode/Dockerfile images/frrnode

## deploy: start the lab (rebuilds containers, keeps the topology authoritative)
deploy:
	$(SUDO) $(CLAB) deploy -t $(TOPO) --reconfigure

## destroy: tear the lab down and clean the runtime directory
destroy:
	$(SUDO) $(CLAB) destroy -t $(TOPO) --cleanup

## redeploy: destroy then deploy (the reliable way to pick up config changes)
redeploy: destroy deploy

## inspect: show the running topology
inspect:
	$(SUDO) $(CLAB) inspect -t $(TOPO)

## graph: render the topology to a mermaid/dot diagram
graph:
	$(SUDO) $(CLAB) graph -t $(TOPO)

## wait: block until OSPF has fully converged (polls, timeout 300s)
wait:
	@echo "waiting for OSPF to converge..."
	@for attempt in $$(seq 1 60); do \
		converged=1; \
		for router in hq-core b1-core b2-core; do \
			neighbours=$$($(SUDO) docker exec clab-$(LAB)-$$router vtysh -c "show ip ospf neighbor" 2>/dev/null | grep -c "Full" || true); \
			if [ "$$neighbours" -lt 2 ]; then converged=0; break; fi; \
		done; \
		if [ "$$converged" -eq 1 ]; then \
			echo "OSPF converged after ~$$(((attempt - 1) * 5))s (every router has 2 FULL neighbours)"; \
			exit 0; \
		fi; \
		sleep 5; \
	done; \
	echo "error: OSPF did not converge within 300s" >&2; exit 1

## baseline: 30-point health check of the healthy network
baseline:
	bash scripts/baseline.sh

## test: run the whole suite - baseline health checks then all four faults
test:
	$(PYTEST) tests -v

## test-baseline: only the health checks
test-baseline:
	$(PYTEST) tests/test_baseline.py -v

## test-faults: only the fault/RCA scenarios (needs a healthy lab)
test-faults:
	$(PYTEST) tests/test_faults.py -v

## fault: inject a fault, e.g. make fault NAME=wan_link_failure
fault:
	@test -n "$(NAME)" || (echo "usage: make fault NAME=<wan_link_failure|routing_loop|dhcp_exhaustion|stp_loop>" && exit 1)
	bash faults/inject/$(NAME).sh

## fix: remediate a fault, e.g. make fix NAME=wan_link_failure
fix:
	@test -n "$(NAME)" || (echo "usage: make fix NAME=<wan_link_failure|routing_loop|dhcp_exhaustion|stp_loop>" && exit 1)
	bash faults/fix/$(NAME).sh

## clean: remove generated evidence and pytest caches
clean:
	rm -rf artifacts .pytest_cache
	find . -name __pycache__ -type d -prune -exec rm -rf {} +

## lint: shellcheck the scripts and validate the topology YAML
lint:
	shellcheck scripts/*.sh faults/lib.sh faults/inject/*.sh faults/fix/*.sh || true
	$(PYTHON) -c "import yaml,sys; yaml.safe_load(open('$(TOPO)')); print('topology YAML ok')"

.PHONY: help install-clab images deploy destroy redeploy inspect graph wait \
        baseline test test-baseline test-faults fault fix clean lint
